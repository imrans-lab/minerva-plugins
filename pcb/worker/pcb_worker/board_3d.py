"""THE TWO VERBS OVER THE 3D EXPORT: warm the vendor cache, then write the file.

WHY THIS IS TWO CALLS AND NOT ONE
---------------------------------
Every exporter this plugin has runs SYNCHRONOUSLY and there is no progress
channel: a caller — the panel's Export menu included — blocks until the reply
comes back. A cold run over a real board is ~86 vendor requests
(:data:`part_models.TIMEOUT_S` names the same number), which is minutes of a
frozen window with nothing on screen to say why.

So the network work is its OWN verb:

    :func:`warm_cache`   fetches, may take a while, and reports what it got and
                         what it could not. Nothing is written but the cache.
    :func:`export`       is synchronous, reads ONLY what is already cached
                         (``VendorPartClient(offline=True)``), and never opens
                         a socket. A cold cache costs placeholder prisms and a
                         report that names the warming verb.

Three things follow that are worth more than the frozen window they cost to
avoid. A fetch failure and a geometry failure stop being the same red. The
cache-warm export is fast and deterministic, so the slow step is the one you
can retry alone. And warming is independently useful — the orientation work
needs the same vendor documents to measure against.

A progress channel may arrive later and would let these merge again. Nothing
here forecloses it: they are two entry points over one placement chain, not two
implementations of it.

WHAT NEITHER OF THESE DOES
--------------------------
Compile the board. Both are handed the compiled board by the dispatcher, so an
uncompilable board refuses once, under ``assembly_not_compilable``, before
either of them is reached.
"""

from __future__ import annotations

import hashlib
import os
from dataclasses import replace
from typing import Union

from . import assembly_outputs as ao
from . import cache_dir
from . import gltf_export
from . import order_package
from . import order_write
from . import part_models as pm
from . import part_placement as pp
from .texture_frame import DEFAULT_SCALE_PX_PER_MM, MAX_TEXTURE_PX

#: The verb an export names when it finds the cache cold. Stated once, here,
#: because it travels into a reply an agent reads AND into a sentence the panel
#: prints, and a name that differs between them sends the two audiences to
#: different places.
WARM_VERB = "minerva_pcb_fetch_part_models"

#: The extension the file gets, and the only one. ``.glb`` is the self-contained
#: binary form — textures inside the file — so the deliverable is ONE file a
#: person can forward. It is also on the host's os-open allowlist, which is what
#: makes the panel's "open it" offer possible.
GLB_SUFFIX = ".glb"

DEFAULT_PROFILE = "jlc"


# ---------------------------------------------------------------------------
# What the board asks the vendor for
# ---------------------------------------------------------------------------


def drawing_profile(params: dict) -> ao.HouseProfile:
    """The selected profile, with the PURCHASING identity requirement lifted.

    THIS IS THE ONE PLACE THAT DOES IT, AND ONLY FOR A LOCAL DRAW.
    ``assembly_outputs`` refuses a populated component with no ``mpn`` under
    ``assembly_missing_identity``, and its own message says why: "refusing to
    emit a BOM/CPL row with a blank identity cell (part-identity contract)".
    That contract is about a document a house reads. Nothing here emits one —
    this module draws a picture on this machine — and the plan of record
    (docket 01a06532faa0) states the opposite behaviour for exactly this case:
    "missing model, missing LCSC number ... degrades to a courtyard prism and a
    report. Never fatal."

    Refusing would also deny the render to the boards that most need it: a
    mid-layout board where nobody has filled in catalogue numbers yet is
    precisely when somebody wants to look at the thing.

    NOTHING IS HIDDEN BY LIFTING IT. A part with no catalogue number cannot be
    asked for, is drawn as a placeholder prism, and is named in the export's
    ``missing_models`` (reason ``no_part_number``) and in the warm's
    ``refs_without_part``. The requirement is lifted, not the reporting.

    NOTHING ELSE IS LIFTED. Every other gate in ``emit`` still runs over this
    profile — the dialect check, the designator gates, the anchor and
    child-land checks, the row and spacing limits — and every ARTIFACT path
    still selects its profile by id and keeps the identity contract intact.
    """
    profile = ao._resolve_profile(str(params.get("profile") or DEFAULT_PROFILE))
    return replace(profile, identity_required=())


def emission_for(board, params: dict) -> ao.AssemblyEmission:
    """The position-file emission the EXPORT places parts from.

    :func:`assembly_outputs.emit` and NOT ``build_package``: an emission with
    unspent orientation refusals may not be written into an artifact a
    manufacturer reads, and is explicitly allowed for "a reader that only draws
    the board locally" (see :class:`assembly_outputs.AssemblyEmission`). This
    draws locally. The refusals are not swallowed — they arrive as UNVERIFIED
    orientations, each with an orange post over the part.

    The export needs the emission because it seats every part at the POSITION
    FILE's own transform: the render must never be able to disagree with the
    file a machine would read. The warm needs no such thing and does not use
    it — see :func:`board_parts`.
    """
    return ao.emit(board, drawing_profile(params))


def board_parts(board, params: dict) -> tuple[dict[str, list[str]], list[str]]:
    """``({catalogue number: [refs]}, [refs with no number])``, off the BOARD.

    THE WARM DOES NOT WALK THE POSITION FILE, deliberately. Everything
    ``emit`` does beyond naming catalogue numbers is a contract about an
    artifact a manufacturer reads — designator uniqueness, row limits,
    placement spacing, anchors on lands — and NONE of it has any bearing on
    whether a model can be downloaded. A board with two parts sharing a
    designator can have its cache warmed perfectly well, and a verb whose whole
    job is "fetch what you can, report what you cannot" must not refuse the
    other forty-six parts because of the forty-seventh.

    The catalogue number is read by the SAME expression the position file uses
    (``assembly.house_parts`` keyed by the profile's ``house_part_id``), so the
    warm and the export cannot disagree about what a part is called.

    Refs are collected per PHYSICAL placement, like the position file's rows,
    so a component that expands into several parts reports each designator.
    Non-populated parts are left out: nobody buys them and nothing draws them.
    """
    house = ao._resolve_profile(
        str(params.get("profile") or DEFAULT_PROFILE)).house_part_id
    wanted: dict[str, list[str]] = {}
    without: list[str] = []
    for component in board.components:
        assembly = getattr(component, "assembly", None)
        if assembly is None or not assembly.populate:
            continue
        part = (dict(assembly.house_parts).get(house) or "").strip()
        for physical in component.physical_placements:
            if part:
                wanted.setdefault(part, []).append(physical.ref)
            else:
                without.append(physical.ref)
    return wanted, without


# ---------------------------------------------------------------------------
# Verb one: warm the cache
# ---------------------------------------------------------------------------


def warm_cache(board, params: dict, *, client=None) -> dict:
    """Fetch every vendor document this board's parts need, and say what came.

    Both documents per part — the component payload AND the mesh it points at —
    because either one missing is a placeholder prism at export time, and a verb
    that warmed half the cache would leave the export reporting a gap the warm
    claimed to have closed.

    ``client`` is injectable for tests; the default is an ONLINE client, which
    is the entire point of this verb.

    IT REFUSES ALMOST NOTHING. Only a board that will not compile, and a
    profile nobody publishes, stop this verb; every per-part problem is data on
    the reply. See :func:`board_parts` for why it does not walk the emission.
    """
    fetcher = pm.VendorPartClient() if client is None else client
    wanted, without = board_parts(board, params)

    ready: list[dict] = []
    missing: list[dict] = []
    # facts_for deduplicates and runs the requests concurrently, at most once
    # each; the model call after it hits the same memo, so a part whose facts
    # just arrived costs one further request and never a second lookup.
    facts = fetcher.facts_for(wanted)
    for part in sorted(wanted):
        refs = wanted[part]
        answer = facts.get(part)
        model = fetcher.model(answer) if answer is not None else None
        if model is None or model.absent:
            absent = model if model is not None else answer
            missing.append({
                "part": part, "refs": refs,
                "reason": getattr(absent, "reason", pm.REASON_NOT_FOUND),
                "detail": getattr(absent, "detail", "no answer for this part"),
            })
            continue
        provenance = model.provenance
        ready.append({
            "part": part, "refs": refs, "model_uuid": model.uuid,
            "from_cache": bool(provenance.from_cache),
            "bytes": int(provenance.size_bytes),
            "sha256": provenance.sha256,
        })

    from_cache = sum(1 for row in ready if row["from_cache"])
    result = {
        "profile": str(params.get("profile") or DEFAULT_PROFILE),
        "cache_dir": _cache_dir(),
        "requested": sorted(wanted),
        "ready": ready,
        "missing": missing,
        "refs_without_part": without,
        "counts": {
            "requested": len(wanted),
            "ready": len(ready),
            "fetched": len(ready) - from_cache,
            "already_cached": from_cache,
            "missing": len(missing),
        },
    }
    result["summary"] = _warm_summary(result)
    return {"ok": True, "result": result}


def _cache_dir() -> str:
    """Where the warmed documents landed, or "" when this host has no cache.

    Reported rather than assumed: an unwritable or unstated cache degrades to no
    caching at all (see :mod:`cache_dir`), and on such a host a warm followed by
    an offline export is a gap NOBODY could otherwise explain — the fetch says
    it succeeded and the export still finds nothing.
    """
    root = cache_dir.tenant_dir(pm.CACHE_TENANT)
    return "" if root is None else str(root)


def _warm_summary(result: dict) -> str:
    counts = result["counts"]
    parts = [
        "%d part(s) ready (%d fetched, %d already cached)"
        % (counts["ready"], counts["fetched"], counts["already_cached"]),
    ]
    if counts["missing"]:
        parts.append("%d without a usable model" % counts["missing"])
    if not result["cache_dir"]:
        parts.append("NO CACHE DIRECTORY on this host — nothing was kept, so an "
                     "export will still find the cache cold")
    return "; ".join(parts) + "."


# ---------------------------------------------------------------------------
# Verb two: write the file
# ---------------------------------------------------------------------------


class Board3DError(ValueError):
    """A named refusal from this module. ``code`` is what a surface matches on."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def output_name(board, params: dict) -> str:
    """The file's name: the caller's, or the board's own, always ``.glb``."""
    stated = str(params.get("name") or "").strip()
    base = stated or getattr(board, "name", "") or "board"
    # The same safe rendering the order package gives a directory, so a board
    # called "Smart Remote v2" does not produce two differently-mangled names
    # depending on which exporter wrote it.
    safe = order_package.safe_name(base)
    if safe.lower().endswith(GLB_SUFFIX):
        safe = safe[: -len(GLB_SUFFIX)]
    return safe + GLB_SUFFIX


def export(board, params: dict, *, client=None) -> dict:
    """Build the board as ONE ``.glb`` from the cache alone, and write it when
    told where.

    ``out_dir`` IS OPTIONAL, and the same way it is optional on the order
    package: WITHOUT it nothing is written and the reply is the size, the
    digest and the whole report; WITH it the file is published there. The bytes
    are never returned either way — a base64 mesh is neither a file a person
    can open nor anything an agent wants in its context, and the digest is what
    a caller can actually check.

    That is not a convenience. THE REPORT IS THE POINT OF THIS VERB, and "which
    parts have no model, how tall is the board, is the cache cold" is a
    question worth answering without picking a directory and cleaning up a file
    afterwards. The PANEL still always names a destination — a person needs the
    file — and its own rule refuses by name when the board was never adopted
    from a canonical file, so the GUI contract is unchanged.

    ``client`` is injectable for tests; the default is OFFLINE, and that is the
    contract — see the module docstring.
    """
    out_dir = str(params.get("out_dir") or "").strip()
    scale, max_px = _scale(params), _max_px(params)
    emission = emission_for(board, params)
    reader = pm.VendorPartClient(offline=True) if client is None else client
    try:
        built = gltf_export.export_board(board, emission, client=reader,
                                         scale_px_per_mm=scale, max_px=max_px)
    except pp.PartPlacementError as exc:
        raise Board3DError("board_3d_placement_mismatch", str(exc)) from exc

    name = output_name(board, params)
    written_path, written_bytes = "", len(built.glb)
    if out_dir:
        path = os.path.join(out_dir, name)
        if os.path.exists(path) and not bool(params.get("overwrite")):
            raise Board3DError(
                "board_3d_exists",
                "%s already exists — pass overwrite to replace it" % path)
        try:
            written = order_write.write_files(out_dir, {name: built.glb})
        except OSError as exc:
            raise Board3DError("board_3d_write_failed", str(exc)) from exc
        written_path = str(written[0]["path"])
        written_bytes = int(written[0]["bytes_written"])

    placement = built.report["placement"]
    cold = [row for row in placement["fallbacks"]
            if row.get("reason") == pm.REASON_NOT_CACHED]
    result = {
        # EMPTY WHEN NOTHING WAS WRITTEN, never a path that does not exist: the
        # panel's "open it" offer reads this key, and a plausible-looking path
        # to a file nobody created is the one answer worse than no answer.
        "path": written_path,
        "out_dir": out_dir,
        "written": bool(written_path),
        "filename": name,
        "bytes": written_bytes,
        "sha256": hashlib.sha256(built.glb).hexdigest(),
        "profile": emission.profile.id,
        # THE SCALE THAT WAS USED, not the one that was asked for. The bake
        # reduces the scale rather than cropping the board when the long side
        # would exceed max_px, so reporting the request would describe a
        # texture nobody baked. The frame is the only thing that knows.
        "scale_px_per_mm": _baked_scale(built, scale),
        "requested_scale_px_per_mm": scale,
        # THE REPORTS, HOISTED. They are all inside `report` too (and inside the
        # file's own asset.extras), but a surface that has to reach three levels
        # down to find out six parts are missing is a surface that will not
        # bother. These are the ones a person acts on.
        "missing_models": placement["fallbacks"],
        "unverified": placement["unverified"],
        "tallest": placement["tallest"],
        "unknown_height_refs": placement["unknown_height_refs"],
        "advisories": placement["advisories"],
        "excluded": placement["excluded"],
        "cache_cold": cold,
        "notes": list(built.notes),
        "report": built.report,
        "viewer_note": VIEWER_NOTE,
    }
    if cold:
        # NAMED, not hinted. The one refusal-shaped outcome this verb has that
        # is not a refusal: the file is real and complete, and some of it is
        # prisms because nobody warmed the cache.
        result["cache_cold_hint"] = (
            "%d part(s) had no cached model and this export does not fetch — "
            "run %s, then export again." % (len(cold), WARM_VERB))
    result["summary"] = _export_summary(result)
    return {"ok": True, "result": result}


#: Said on every reply, because it is the thing a reader gets wrong. The
#: application's own CAD surface has no file loader; this opens in Blender and
#: any other glTF viewer.
VIEWER_NOTE = ("opens in Blender or any glTF 2.0 viewer — Minerva's own CAD "
               "panel cannot load a mesh file")


def _baked_scale(built, requested: float) -> float:
    """The scale the textures were actually baked at.

    Read off the FRAMES rather than recomputed: the clamp lives in
    :mod:`texture_frame` and a second derivation here would be a number that
    agrees with the picture only until one of them changes. The two sides bake
    from one board at one request, so the smaller is the honest answer for both
    and equals either when they agree.
    """
    frames = (built.report.get("textures") or {}).values()
    scales = [float(f["scale_px_per_mm"]) for f in frames
              if isinstance(f, dict) and "scale_px_per_mm" in f]
    return min(scales) if scales else requested


def _export_summary(result: dict) -> str:
    bits = ["3D model written → %s (%d bytes)" % (result["path"], result["bytes"])
            if result["written"] else
            "3D model built, NOT written (%d bytes; name out_dir to publish it)"
            % result["bytes"]]
    missing = len(result["missing_models"])
    if missing:
        bits.append("%d part(s) drawn as placeholder prisms" % missing)
    unverified = len(result["unverified"])
    if unverified:
        bits.append("%d part(s) with an UNVERIFIED orientation" % unverified)
    if result["cache_cold"]:
        bits.append("cache cold for %d of them — run %s"
                    % (len(result["cache_cold"]), WARM_VERB))
    return "; ".join(bits) + "."


def _scale(params: dict) -> float:
    return _positive(params.get("scale_px_per_mm"), DEFAULT_SCALE_PX_PER_MM,
                     "scale_px_per_mm")


def _max_px(params: dict) -> int:
    return int(_positive(params.get("max_px"), MAX_TEXTURE_PX, "max_px"))


def _positive(value, default: Union[int, float], field: str):
    """A caller's number, or the default. Zero and negatives refuse by name
    rather than reaching the bake, where they become a division or an image of
    no pixels."""
    if value is None or value == "":
        return default
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise Board3DError("board_3d_bad_parameter",
                           "%s must be a number, got %r" % (field, value)) from None
    if number <= 0:
        raise Board3DError("board_3d_bad_parameter",
                           "%s must be greater than zero, got %r" % (field, value))
    return number

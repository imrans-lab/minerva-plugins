"""Request handlers for the Go-Python bridge worker.

Pure (no I/O apart from the explicit file writes in `generate` when an out_dir
is supplied, and the read-only library scan in `check_libraries`) so handlers
can be unit-tested by calling handle_request(dict) -> dict directly, bypassing
stdio — the same pattern the CAD worker's tests use.

Methods are stateless pure functions over the canonical board-source YAML
contract (pcb/internal/board/board.go, pcb/docs/board-yaml.md):

  init            — version/health handshake (mirrors CAD's init).
  ping            — cheap liveness probe; reports cold-start ms.
  validate        — structural validation → {ok, errors[], warnings[]}.
  generate        — YAML → KiCad file text (.kicad_pcb/.kicad_sch/.kicad_pro).
  gerbers         — YAML → Gerber (RS-274X/X2) layers + Excellon drill files.
  check_libraries — footprint existence check against a lib_dir data contract.
  check_bom       — BOM extraction + validation.
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import traceback
from pathlib import Path
from typing import Any

from . import (assembly_advisory, assembly_outputs, bless, board_model,
               compile_board, drc, footprints, gerber, ir_candidates,
               ir_connectivity, kicad, libcheck, net_class_policy, resolve)
from .drc_geometric import geometric_drc_from_resolution, geometric_indeterminate

WORKER_VERSION = "0.2.0"  # tracks plugin manifest version

# Populated by dispatcher.run() after the (timed) cold start. Kept as a module
# global so init/ping can report it without re-measuring.
COLD_START_MS: float | None = None


def _pyyaml_version() -> str:
    try:
        import yaml
        return getattr(yaml, "__version__", "unknown")
    except Exception:
        return "unknown"


def _circuit_synth_version() -> str | None:
    """Version via metadata only — never imports the (KiCad-coupled) package."""
    try:
        from importlib import metadata
        return metadata.version("circuit-synth")
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Method implementations
# ---------------------------------------------------------------------------


def _load(params: dict) -> dict:
    """Resolve a board dict or raise board_model.BoardParseError."""
    return board_model.load_board(params or {})


# --- Resolve-into-fab gate (bug 019f7736b236) -----------------------------
# The fab compilers (gerber/kicad/drc via pad_source) prefer real footprint pad
# geometry attached by resolve to comp["pads"]. Stage 2 step 4a-ii FLIPPED this
# ON (design 2): the fab path resolves by default so pads come from the library,
# not a placeholder. The resolve is BEST-EFFORT (see _maybe_resolve) — a
# component with an unresolvable footprint is left inline rather than failing the
# board; the emitter then fail-closes only on a genuinely sizeless SMD pad.
# Grep this name to find the switch. Per-call override: params["resolve_geometry"].
RESOLVE_FAB_GEOMETRY_DEFAULT = True


def _is_error_reply(x: Any) -> bool:
    """True for a structured error reply {ok: False, error: {...}} (a real board
    dict never carries an "ok" key, so this cleanly discriminates the two)."""
    return isinstance(x, dict) and x.get("ok") is False and "error" in x


def _maybe_resolve(board: dict, params: dict) -> dict:
    """Return the board to compile for the FAB path: unchanged when the resolve
    gate is OFF, or a BEST-EFFORT resolve when ON — attaching comp["pads"] real
    geometry that pad_source prefers, while leaving any component with an
    unresolvable footprint inline (its pins win) rather than failing the board.

    Gate = RESOLVE_FAB_GEOMETRY_DEFAULT (default ON since step 4a-ii), overridable
    per-call via params["resolve_geometry"]. A coincidence failure (footprint
    resolves but disagrees with the routed pins) is NOT tolerated — it returns a
    structured error reply so callers pass it through (detect with
    _is_error_reply()). The standalone `resolve` action uses the STRICT variant
    below instead (an unresolvable footprint there IS an error to surface).
    """
    want = params.get("resolve_geometry")
    if want is None:
        want = RESOLVE_FAB_GEOMETRY_DEFAULT
    if not want:
        return board
    return _resolve_mapped(board, tolerant=True, layers=_layer_params(params))


def _layer_params(params: dict) -> dict:
    """The HOST-INJECTED library-chain configuration of this call (B7).

    The Go broker's withLibraryChain forces ``wip_root`` (the staging root
    whose BLESSED entries may resolve) and ``library_layers`` (the durable
    layers it found on this host — today the user layer, when its lock
    exists) onto every compile-bearing call, exactly as withWIPRoot forces
    the bless surface's write root: the HOST chooses library paths, the
    caller never does. This helper is the single reader of those keys; its
    return value is splatted into compile_board / normalize_board /
    resolve_board, so an absent key falls back to each function's None
    default (the seed-only chain) rather than being re-defaulted here.

    Tests drive the worker methods directly (no broker), so they pass the
    same keys in params — which is also why this tolerates their absence
    instead of requiring them."""
    p = params or {}
    out: dict = {}
    layers = p.get("library_layers")
    if layers:
        out["library_layers"] = layers
    wip_root = p.get("wip_root")
    if isinstance(wip_root, str) and wip_root.strip():
        out["wip_root"] = wip_root
    return out


def _resolve_mapped(board: dict, *, tolerant: bool, layers: dict | None = None) -> dict:
    """Run resolve (tolerant=best-effort for fab, strict for the resolve action)
    and map its faults to structured error replies (never raise). Single owner of
    the coincidence/resolve error shape shared by _maybe_resolve and _resolve.
    ``layers`` is a :func:`_layer_params` dict selecting the live chain."""
    try:
        if tolerant:
            return resolve.resolve_board_best_effort(board, **(layers or {}))
        return resolve.resolve_board(board, **(layers or {}))
    except resolve.ResolveCoincidenceError as exc:
        return {"ok": False, "error": {
            "kind": "coincidence", "message": str(exc),
            "ref": exc.ref, "pin": exc.pin, "delta_mm": exc.delta_mm}}
    except (resolve.ResolveError, footprints.FootprintLookupError) as exc:
        return {"ok": False, "error": {"kind": "resolve", "message": str(exc)}}


def _validate(params: dict) -> dict:
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        # A parse failure is reported as a validation error (data), not a
        # protocol error — the LLM inner loop wants it as {ok, errors}.
        return {"ok": True, "result": {
            "ok": False,
            "errors": [{"path": "", "message": str(exc)}],
            "warnings": [],
        }}
    result = board_model.validate_board(board)
    return {"ok": True, "result": result}


def _compile_or_fail(board: dict, layers: dict | None = None, *,
                     requested_outputs: tuple[str, ...] = compile_board.V1_FAB_OUTPUTS):
    """The SHARED strict-compile prologue: COMPILE → ResolvedBoard IR, or a
    structured fail-closed error reply.

    Used by ``_gerbers`` + ``_generate`` with the FAB capability profile (the
    default) and by ``_route`` with the narrower ROUTING profile
    (``V1_ROUTING_OUTPUTS``, Round E 019f783860c8) — so a solder-mask capability
    loss cannot disable routing while any dropped copper/drill/rule stays fatal
    everywhere. ``requested_outputs`` is the ONLY thing that varies; the failure
    reply shape is identical for every caller.

    Returns the ``ResolutionSuccess`` (carrying ``.board`` + ``.diagnostics`` the
    caller forwards as warnings) on success, or a ``{kind:"compile"}`` error reply
    (detect with :func:`_is_error_reply`) on failure — NO fallback to the legacy
    best-effort emitter (W9 deletes the dead best-effort fab path). ``layers``
    (a :func:`_layer_params` dict, B7) selects the LIVE library chain — blessed
    WIP + the host's durable layers over the seed; absent, the seed alone, the
    pre-B7 behaviour. ``params["resolve_geometry"]`` is
    moot on the fab path now (compile ALWAYS resolves): accepted-and-ignored by the
    callers, not consulted here."""
    compiled = compile_board.compile_board(board, requested_outputs=requested_outputs,
                                           **(layers or {}))
    if isinstance(compiled, compile_board.ResolutionFailure):
        return _compile_failure_reply(compiled)
    return compiled


def _generate(params: dict) -> dict:
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    # W8.2 CUTOVER: same shape as _gerbers — COMPILE (strict) → ResolvedBoard IR →
    # kicad.generate, replacing the legacy best-effort _maybe_resolve (shared
    # prologue in _compile_or_fail).
    compiled = _compile_or_fail(board, _layer_params(params))
    if _is_error_reply(compiled):
        return compiled

    base_name = params.get("name") if isinstance(params.get("name"), str) else None
    try:
        # C5b: emit straight from the ResolvedBoard IR — no IR->loose-dict adapter
        # (mirrors _gerbers' build_gerbers_ir at the gerber cutover).
        files = kicad.generate_ir(compiled.board, base_name=base_name)
    except Exception as exc:  # geometry/library faults (incl. fail-closed) as data
        return {"ok": False, "error": {"kind": "generate", "message": str(exc)}}

    # Surface WARNING-channel diagnostics so nothing vanishes silently: the KiCad
    # emitter's own (a captured footprint graphic dropped/unsupported) PLUS the
    # compile diagnostics (INFO/WARNING). Both via the SAME _diagnostic_to_payload
    # shape the gerbers handler uses. Non-breaking: only the "warnings" key changes.
    out_dir = params.get("out_dir")
    warnings = [_diagnostic_to_payload(d) for d in getattr(files, "diagnostics", [])]
    warnings += [_diagnostic_to_payload(d) for d in compiled.diagnostics]
    result: dict = {"files": files, "written": [], "warnings": warnings}
    if isinstance(out_dir, str) and out_dir.strip():
        # Optional: also write to disk and report paths + byte counts (mirrors
        # CAD's export, which returns {path, bytes_written}). Contents still
        # travel inline — worker↔Go is stdio, not the 64KiB panel IPC broker.
        try:
            os.makedirs(out_dir, exist_ok=True)
            written = []
            for fname, text in files.items():
                p = Path(out_dir) / fname
                data = text.encode("utf-8")
                p.write_bytes(data)
                written.append({"path": str(p), "bytes_written": len(data)})
            result["written"] = written
        except OSError as exc:
            return {"ok": False, "error": {
                "kind": "io", "message": f"failed to write to out_dir: {exc}"}}
    return {"ok": True, "result": result}


def _diagnostic_to_payload(d) -> dict:
    """Serialise a resolved_board.Diagnostic to a reply dict. The source_ref shape
    mirrors footprint_def._unsupported_to_payload (the one place that already turns
    a SourceRef into JSON) so callers see one uniform diagnostic shape."""
    return {
        "severity": d.severity.value,
        "code": d.code,
        "message": d.message,
        "source_ref": {
            "entity_kind": d.source_ref.entity_kind.value,
            "entity_id": d.source_ref.entity_id,
            "detail": d.source_ref.detail,
        },
    }


def _compile_failure_reply(failure) -> dict:
    """Map a compile_board.ResolutionFailure to the STRICT fail-closed fab reply
    (W8.2). No fallback to the legacy best-effort emitter — an uncompilable board
    never yields fabrication. `message` summarises the FIRST ERROR diagnostic;
    every diagnostic is serialized (same _diagnostic_to_payload shape as warnings)
    so the caller sees exactly what blocked the compile."""
    payloads = [_diagnostic_to_payload(d) for d in failure.diagnostics]
    first_error = next((p for p in payloads if p.get("severity") == "error"), None)
    message = first_error["message"] if first_error else "board could not be compiled"
    return {"ok": False, "error": {
        "kind": "compile", "message": message, "diagnostics": payloads}}


def _gerbers(params: dict) -> dict:
    """Generate Gerber (RS-274X/X2) + Excellon fabrication files from a board.

    Return convention mirrors `generate` exactly: {files:{name:content},
    written:[{path,bytes_written}]}, with the files also written to disk when
    out_dir is supplied. Nine baseline Gerber layers (F_Cu/B_Cu/F_Paste/
    B_Paste/F_SilkS/B_SilkS/F_Mask/B_Mask/Edge_Cuts) plus one In{k}_Cu per
    declared inner copper layer (epoch GA-3), plus PTH.drl/NPTH.drl (each
    drill file only when the board has holes of that class) and the -job
    .gbrjob manifest.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    # W8.2 CUTOVER: the LIVE fab path now COMPILES (strict) → ResolvedBoard IR →
    # emit, replacing the legacy best-effort _maybe_resolve (shared prologue in
    # _compile_or_fail — fail-closed, NO fallback to the legacy emitter).
    compiled = _compile_or_fail(board, _layer_params(params))
    if _is_error_reply(compiled):
        return compiled

    base_name = params.get("name") if isinstance(params.get("name"), str) else None
    try:
        # C5: emit straight from the ResolvedBoard IR — no IR->loose-dict adapter.
        files = gerber.build_gerbers_ir(compiled.board, name=base_name)
    except Exception as exc:  # geometry/library faults reported as data, not crash
        return {"ok": False, "error": {"kind": "gerber", "message": str(exc)}}

    # Surface WARNING-channel diagnostics so nothing vanishes silently: the
    # emitter's own (a captured fab feature dropped/approximated) PLUS the compile
    # diagnostics (INFO/WARNING — inline_pin_geometry_migrated,
    # captured_geometry_not_emitted, ordinal_ids). Both via the same
    # _diagnostic_to_payload shape. Non-breaking: only the "warnings" key changes.
    out_dir = params.get("out_dir")
    warnings = [_diagnostic_to_payload(d) for d in getattr(files, "diagnostics", [])]
    warnings += [_diagnostic_to_payload(d) for d in compiled.diagnostics]
    result: dict = {"files": files, "written": [], "warnings": warnings}
    if isinstance(out_dir, str) and out_dir.strip():
        try:
            os.makedirs(out_dir, exist_ok=True)
            written = []
            for fname, text in files.items():
                p = Path(out_dir) / fname
                data = text.encode("utf-8")
                p.write_bytes(data)
                written.append({"path": str(p), "bytes_written": len(data)})
            result["written"] = written
        except OSError as exc:
            return {"ok": False, "error": {
                "kind": "io", "message": f"failed to write to out_dir: {exc}"}}
    return {"ok": True, "result": result}


def _drc(params: dict) -> dict:
    """CONNECTIVITY / topology design-rule check over a canonical board.

    Runs the legacy CENTERLINE checker (`drc.run_drc`, via `_maybe_resolve`): it
    reasons about pad CENTERS and trace CENTERLINES only. It is NOT geometric and
    canNOT verify a clearance, trace width, or annular ring — a zero-finding result
    here is a connectivity/topology pass, NOT a proof that the copper is
    geometrically clean. For real geometric copper DRC (GC1-GC6 over the
    ResolvedBoard IR, fail-closed, never a false clean) use the `drc_geometric`
    method (`_drc_geometric`).

    Returns {ok, findings:[{type,...}], counts:{type:n}}. A parse failure is a
    structured error (never a crash), mirroring `generate`/`gerbers`.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    board = _maybe_resolve(board, params)
    if _is_error_reply(board):
        return board
    try:
        result = drc.run_drc(board)
    except Exception as exc:  # geometry faults reported as data, not a crash
        return {"ok": False, "error": {"kind": "drc", "message": str(exc)}}
    return {"ok": True, "result": result}


# How many entity references a grouped warning row carries before it stops
# naming them individually. Enough to see the pattern, few enough that a
# board-wide omission does not cost more than the finding it sits beside.
_WARNING_REFS_SHOWN = 8


def _group_static_warnings(warnings: list, *, verbose: bool = False) -> dict:
    """Collapse repeated compile diagnostics into one row per code.

    THE PROBLEM THIS SOLVES is a coworking cost, not a correctness one. Compile
    emits one WARNING per marker and per component — feature_omitted,
    captured_geometry_not_emitted, ordinal_ids — so a real board produces
    dozens of rows saying the same thing about different entities, and every
    board_check carries all of them. The DRC-clean push runs board_check dozens
    of times, which makes this the single largest context cost of working the
    manufacture loop, for information that does not change between runs.

    Returns {rows, digest, total}. The DIGEST is what makes the collapse safe
    to skim: it is stable across identical calls, so a caller who saw the rows
    once can tell at a glance that nothing new appeared, and it MOVES the
    moment any warning does — INCLUDING one hidden behind the row truncation.
    It is taken over a canonicalization of the full warning set rather than
    over the display rows, because the rows keep only the first few refs and
    one representative message: hashing those would let two different sets
    collide precisely where a reader cannot see the difference.

    ``verbose`` returns the flat list untouched beside the rows, for the caller
    who genuinely needs every entity.
    """
    grouped: dict[str, dict] = {}
    for entry in warnings:
        if not isinstance(entry, dict):
            continue
        code = str(entry.get("code", "") or "uncoded")
        row = grouped.setdefault(code, {
            "code": code, "count": 0, "refs": [], "severities": set(),
            "messages": set(),
        })
        row["count"] += 1
        # COLLECTED, not first-wins. Real compile messages embed the entity they
        # name (compile_board's "footprint 'U2': ..."), so a first-encountered
        # representative changes when the warning list is reordered — which
        # would move the digest and report a compiler-internal reorder as new
        # information, the exact thing sorting before hashing exists to prevent.
        row["messages"].add(str(entry.get("message", "")))
        severity = entry.get("severity")
        if severity is not None:
            row["severities"].add(str(severity))
        ref = ((entry.get("source_ref") or {}).get("entity_id")
               if isinstance(entry.get("source_ref"), dict) else None)
        if isinstance(ref, str) and ref and ref not in row["refs"]:
            row["refs"].append(ref)
    rows = []
    for code in sorted(grouped):
        row = grouped[code]
        shown = sorted(row["refs"])
        # ONE representative message, chosen DETERMINISTICALLY, because the
        # rows for a code differ only by the entity they name and that is what
        # `refs` is for. Lexicographic min is order-independent, so the digest
        # depends on the warning SET rather than on the order it arrived in.
        messages = sorted(row["messages"])
        severities = sorted(row["severities"])
        out_row = {
            "code": row["code"],
            "count": row["count"],
            "severity": severities[0] if severities else None,
            "message": messages[0] if messages else "",
            "refs": shown[:_WARNING_REFS_SHOWN],
        }
        if len(messages) > 1:
            # Distinct wordings under one code are worth admitting to: it means
            # the row's `message` is a sample, not the whole story.
            out_row["distinct_messages"] = len(messages)
        if len(severities) > 1:
            out_row["severities"] = severities
        if len(shown) > _WARNING_REFS_SHOWN:
            out_row["refs_omitted"] = len(shown) - _WARNING_REFS_SHOWN
        rows.append(out_row)
    # DIGEST OVER THE WHOLE WARNING, not over the display rows and not over a
    # chosen subset of fields.
    #
    # The rows truncate refs and keep one representative message, so hashing
    # THEM lets two different warning sets collide wherever they differ past the
    # display cut. Hashing a hand-picked tuple of fields has the same failure
    # one level in: it is a second schema shadowing _diagnostic_to_payload's,
    # and it drifts. The first version of this listed code/severity/message/
    # entity_id and silently ignored source_ref.entity_kind and .detail, so a
    # diagnostic that moved from one entity_kind to another produced an
    # identical digest.
    #
    # So: serialize each warning WHOLE with sorted keys, sort the serialized
    # strings, and hash that. Any field the payload grows is covered the day it
    # appears, and the sort makes the result a function of the warning multiset
    # rather than of the order it arrived in.
    canonical = sorted(
        json.dumps(entry, sort_keys=True, separators=(",", ":"), default=str)
        for entry in warnings if isinstance(entry, dict))
    digest = hashlib.sha256(
        json.dumps(canonical, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    out = {"rows": rows, "digest": digest, "total": len(warnings)}
    if verbose:
        out["warnings"] = list(warnings)
    return out


def _drc_geometric(params: dict) -> dict:
    """Geometric copper DRC over the ResolvedBoard IR (GC1-GC7): reads REAL copper
    and hole geometry, fail-closed, and NEVER emits a false ``clean``. This is the
    geometric counterpart to :func:`_drc` (the connectivity/centerline checker,
    which cannot verify a clearance).

    Parse (via ``_load``) → compile (``compile_board.compile_board``) → hand the
    ``ResolutionResult`` straight to
    :func:`drc_geometric.geometric_drc_from_resolution`. That union dict is this
    method's PAYLOAD — returned as the ``result`` of the standard worker envelope
    (``{ok:True, result:<union>}``). The geometric result union:

      * DETERMINATE (compile succeeded): ``{ok:True, scope:"geometric",
        verifies_geometry:True, verdict:"clean"|"violations", findings, counts,
        warnings, ...}``.
      * INDETERMINATE (compile failed, or the kernel met un-modelable geometry):
        ``{ok:False, scope:"geometric", verifies_geometry:False,
        verdict:"indeterminate", error:{...}}`` — deliberately carries NO
        ``clean``/``findings`` a caller could read as a pass.

    The union is the ``result`` payload of the standard worker envelope (every
    worker method returns ``{ok:True, result:<payload>}``; the dispatcher and Go
    bridge unwrap ``result`` — a bare top-level union surfaces as ``result:null``).
    EVERY failure at
    this boundary — parse, compile exception, or unmodeled geometry — returns the
    SAME geometric indeterminate union (019f9589b232): a source that will not parse
    is ``kind="parse"``, an unexpected ``compile_board`` exception is
    ``kind="internal"``, and a compile ``ResolutionFailure`` /
    kernel-unmodeled-geometry flows through
    :func:`drc_geometric.geometric_drc_from_resolution`. No consumer maintains a
    bespoke branch for parse anymore, and the union never carries a ``clean`` a
    caller could mistake for a pass.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        union = geometric_indeterminate("parse", str(exc))
    else:
        try:
            result = compile_board.compile_board(board, **_layer_params(params))
        except Exception as exc:  # noqa: BLE001 - fail-closed: a compile crash is NOT a clean.
            union = geometric_indeterminate("internal", f"compile_board raised {exc!r}")
        else:
            union = geometric_drc_from_resolution(result)
    # WORKER ENVELOPE: the geometric UNION is the payload, wrapped under ``result``
    # exactly like every other worker method — the dispatcher and the Go bridge
    # unwrap ``result``, so a BARE top-level union (no ``result`` key) surfaces as
    # ``result: null`` over the bridge (the live regression this fixes). The envelope
    # ``ok`` is always True: the method RAN and produced a structured discriminated
    # union; clean / violations / indeterminate are conveyed INSIDE the union
    # (``result.ok`` / ``result.verdict``), so every failure still returns the SAME
    # union (019f9589b232) and no consumer needs a bespoke branch.
    # STATIC-WARNING AGGREGATION (SR2FAB S12). The union's flat `warnings` list
    # is one row per marker per entity, unchanged between runs and re-sent on
    # every call. It is replaced by `static_warnings` — one row per code with a
    # count, a sample of the entities and a digest — and the flat list returns
    # only for a caller that asks. The digest is what makes the collapse safe:
    # it moves the moment any warning does.
    if isinstance(union, dict) and isinstance(union.get("warnings"), list):
        union = dict(union)
        union["static_warnings"] = _group_static_warnings(
            union["warnings"], verbose=bool((params or {}).get("verbose_warnings")))
        if not bool((params or {}).get("verbose_warnings")):
            union.pop("warnings", None)
    return {"ok": True, "result": union}


def _resolve(params: dict) -> dict:
    """Enrich a canonical board with footprint silk/courtyard graphics.

    For each component, resolve its footprint from the sha-verified seed library
    and attach its F.SilkS + F.CrtYd graphics (component-LOCAL coords), after a
    fail-closed coincidence guard that proves the footprint's pads match the
    declared pins. Returns {ok, board:<resolved>, stats:{components,
    silk_graphics, courtyard_graphics}}. A parse failure, an unresolvable
    footprint, or a coincidence mismatch is reported as a structured error
    (never a crash), mirroring generate/gerbers/drc.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    # This method IS resolve, and it is STRICT: an unresolvable footprint is an
    # error the caller asked to surface (unlike the fab path, which tolerates it
    # and falls back to inline pins). Reuse _resolve_mapped's shared structured
    # error handling — one place owns the coincidence/lookup error shape.
    resolved = _resolve_mapped(board, tolerant=False, layers=_layer_params(params))
    if _is_error_reply(resolved):
        return resolved

    stats = resolve.board_graphic_stats(resolved)
    return {"ok": True, "result": {"ok": True, "board": resolved, "stats": stats}}


def _resolve_best_effort(params: dict) -> dict:
    """TOLERANT sibling of :func:`_resolve`, for the board-LOAD path.

    Identical enrichment and identical reply shape, with ONE difference: a
    component whose footprint is unresolvable (not in the seed library) or that
    declares no footprint ref is LEFT INLINE instead of failing the whole board.
    A board must always load — a component the library cannot explain simply
    renders as it does today (pads, no body outline), it does not sink the load
    (docket 019fb430750a, unit 1).

    Deliberately a SIBLING METHOD rather than a `tolerant` flag on ``resolve``:
    the agent-facing ``minerva_pcb_resolve`` tool is STRICT by contract, and a
    shared flag is one mis-set params key away from silently de-stricting it.
    ``_resolve`` and the ``resolve`` method stay untouched.

    A coincidence fault (the footprint RESOLVES but its pads DISAGREE with the
    routed pins) is still NOT tolerated — silk desynced from copper is an
    integrity fault, not a cosmetic gap — so it comes back as a structured error
    reply and the caller degrades to the unenriched board.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    resolved = _resolve_mapped(board, tolerant=True, layers=_layer_params(params))
    if _is_error_reply(resolved):
        return resolved

    stats = resolve.board_graphic_stats(resolved)
    result: dict = {"ok": True, "board": resolved, "stats": stats}
    # ASSEMBLY (HITL-4 F3, tri-state since work item 019fd5fddc09): load time
    # is where the owner most wants "these parts collide" — the D1/BAT1 body
    # overlap PRE-EXISTED its routing session and nothing named it. Computed
    # over the RESOLVED board directly (footprint courtyards were just
    # attached above, so the honest "courtyard" basis is available for every
    # library part — no second resolve; unresolved components fall back to
    # pad extents). ALWAYS attached, replacing the old absent-when-empty
    # `assembly_advisories` list: {status: "pass"} is a measured all-clear a
    # missing key never was. Never allowed to sink a board load (same
    # boundary as _assembly_tri_state).
    try:
        assembly = assembly_advisory.assembly_check(resolved)
    except Exception as exc:  # noqa: BLE001 - an advisory must never sink the load
        assembly = {"status": "indeterminate", "findings": [],
                    "error": str(exc)}
    result["assembly"] = assembly
    return {"ok": True, "result": result}


def _assembly_check(params: dict) -> dict:
    """Standalone tri-state assembly check (DCR 019fd5fd9084, work item
    019fd5fddc09) — the method surface for `board_health.assembly` computed
    on demand, so the panel can ask "can these parts be assembled?" without
    proposing copper.

    params: {board: <canonical board dict>} (or yaml source — anything
    `_load` accepts, mirroring the sibling methods). Reply::

        {ok: True, result: {status: "pass"|"findings"|"indeterminate",
                            findings: [<advisory dict>, ...],
                            indeterminate: [{component, reason}],  # absent
                                                                   # when empty
                            error?: str}}

    Same computation as every other assembly surface (_assembly_tri_state:
    tolerant resolve first for courtyard bases, fault -> status
    "indeterminate" + error — NEVER a silent pass, NEVER an unstructured
    exception). Only an unparseable board param is a structured {ok: False}
    parse error, the same envelope every sibling method uses."""
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}
    return {"ok": True, "result": _assembly_tri_state(board, layers=_layer_params(params))}


def _mask_view(params: dict) -> dict:
    """SOLDER-MASK VIEW for the panel (WYSIWYG goal 019ff4a5a75a, gap G4).

    Returns every mask opening on the board — the collection the panel renders
    as its mask overlay. The openings are ``project_board(rb).mask``, i.e. the
    EXACT collection GC8 measures slivers on and the same shared-owner
    enumeration (mask_source) the Gerber emitter adopts. Nothing here decides a
    dimension, a side, or whether an entity opens mask at all; a panel that
    re-derived any of that would drift from the fab, which is the defect class
    the WYSIWYG goal exists to remove.

    params: {board|yaml} (anything ``_load`` accepts).
    Reply: {ok: True, result: {openings: [{side:"top"|"bottom", shape, x_mm,
    y_mm, width_mm, height_mm, corner_rratio, angle_deg, origin, ref,
    pad_number}], indeterminate: [{entity, reason}]}}.

    ``indeterminate`` is carried, never dropped: it names entities whose mask
    coverage could not be determined, and a viewer that hid them would show a
    KNOWN-INCOMPLETE aperture set as complete — the same false-clean direction
    GC8 refuses a verdict over (drc_geometric's wholesale refusal). The panel
    must mark the overlay, not silently draw the subset.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}
    compiled = _compile_or_fail(board, _layer_params(params))
    if _is_error_reply(compiled):
        return compiled
    from .drc_geometric import UnsupportedGeometry, project_board
    from .resolved_board import Side
    try:
        proj = project_board(compiled.board)
    except UnsupportedGeometry as exc:
        return {"ok": False, "error": {"kind": "unsupported_geometry",
                                       "message": str(exc)}}
    return {"ok": True, "result": {
        "openings": [{
            "side": "top" if o.side is Side.TOP else "bottom",
            "shape": o.shape,
            "x_mm": o.x, "y_mm": o.y,
            "width_mm": o.width, "height_mm": o.height,
            "corner_rratio": o.corner_rratio,
            "angle_deg": o.angle_deg,
            "origin": o.origin,
            "ref": o.ref,
            "pad_number": o.pad_number,
        } for o in proj.mask],
        "indeterminate": [{"entity": e, "reason": r}
                          for (e, r) in proj.mask_indeterminate],
    }}


def _zone_fill(params: dict) -> dict:
    """THE COMPILED COPPER of every pour on the board.

    A pour conducts as the copper it is FILLED with, never as the outline it is
    authored from: clearance carving, keepouts and the board-edge inset can cut
    one outline into several regions that do not conduct to each other. This is
    the surface that hands those regions to a caller that has to answer what is
    already joined.

    params: {board|yaml} (anything ``_load`` accepts). Reply::

        {ok: True, result: {zones: [{id: str,
                                     fill: [[{x_mm, y_mm}, ...], ...]}, ...]}}

    ``id`` is the zone's id AS THE CALLER SENT IT, not the compiled one. They
    differ whenever the source is not schema v2 — a sub-v2 board has its entity
    ids minted during the compile — and a caller matching the reply against its
    own zones has only the id it sent. See :func:`_authored_zone_id`.

    One entry per COPPER POUR whose fill was computed, one ring per separately
    filled region, points in the ring's own order. ``fill: []`` is a computed
    empty pour (its outline entirely consumed by keepouts, clearance or the
    edge inset) — a real answer, distinct from the absence below.

    A zone is OMITTED when no fill was computed for it: keepouts, which are not
    copper. An omitted zone tells the caller nothing about that zone's copper,
    which is the only honest thing to say about copper that was never computed.

    The fill comes off the compiled IR — the same ``ResolvedZone.fill`` the
    Gerber emitter flashes — so the regions here are the regions that ship.
    Compiling is what fills, so a board that will not compile has no fill to
    report and comes back as the compile error itself: no partial answer, and
    nothing derived from the authored outline as a stand-in.

    Compiled against the ROUTING output profile, not the fab one: this answers a
    connectivity question, so a lost solder-mask or paste capability must not
    take the pour's copper away with it, while dropped copper, drill or design
    rules stay fatal here as everywhere.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}
    compiled = _compile_or_fail(board, _layer_params(params),
                                requested_outputs=compile_board.V1_ROUTING_OUTPUTS)
    if _is_error_reply(compiled):
        return compiled
    from .resolved_board import ZoneKind  # noqa: PLC0415
    authored = board.get("zones")
    if not isinstance(authored, list):
        authored = []
    return {"ok": True, "result": {"zones": [
        {
            "id": _authored_zone_id(authored, index, zone),
            "fill": [[{"x_mm": x, "y_mm": y} for (x, y) in polygon.points]
                     for polygon in zone.fill],
        }
        for index, zone in enumerate(compiled.board.zones)
        if zone.kind is ZoneKind.COPPER_POUR and zone.fill is not None
    ]}}


def _authored_zone_id(authored: list, index: int, zone) -> str:
    """The id the CALLER gave this zone, or the compiled one when there is none.

    A successful compile builds one ResolvedZone per authored zone, in order —
    a zone the compiler rejects makes the whole compile fail rather than
    dropping out of the list — so position identifies the source zone. The
    position is nonetheless CHECKED against the layer and kind that came back,
    and a disagreement falls through to the compiled id: an id echoed onto the
    wrong zone would attach one plane's copper to another.

    A compiled id is returned unchanged for a caller whose zone carried none.
    Such a caller has nothing to match it against, which is the honest outcome
    — better than an id that looks matchable and is not.
    """
    from .resolved_board import ZoneKind  # noqa: PLC0415
    if index >= len(authored):
        return zone.id
    source = authored[index]
    if not isinstance(source, dict):
        return zone.id
    authored_id = source.get("id")
    if not (isinstance(authored_id, str) and authored_id):
        return zone.id
    if str(source.get("layer") or "") != zone.layer.id:
        return zone.id
    if str(source.get("kind") or ZoneKind.COPPER_POUR.value) != zone.kind.value:
        return zone.id
    return authored_id


def _fab_preview(params: dict) -> dict:
    """EXACT FABRICATION PREVIEW (WYSIWYG goal 019ff4a5a75a, gap G5; approved
    DCR 019ffc52b455; acceptance check K27).

    Renders THE BYTES THE FAB RECEIVES. This does not re-derive, re-simulate or
    approximate anything: it runs the production emission path (the same
    ``build_gerbers_ir`` call ``gerbers`` uses), then reads the resulting
    artifacts back with **gerbonara** — a DIFFERENT library from the
    ``gerber_writer`` that produced them, so the preview is an independent read
    of the output rather than the emitter agreeing with itself. That is the same
    independence principle K18's oracle rests on, and it is the whole reason
    this is allowed to be called "exact" while a canvas re-render never could.

    params: {board|yaml} (anything ``_load`` accepts), plus optional ``name``.
    Reply: {ok: True, result: {
        layers: [{name, kind, sha256, byte_length, svg}],
        unrendered: [{name, reason, kind: "job" | "artwork"}],
        bounds_mm: {min_x, min_y, max_x, max_y} | None,
        bounds_board_mm: {min_x, min_y, max_x, max_y} | None,
        warnings: [...]}}

    EVERY EMITTED FILE IS ACCOUNTED FOR, in exactly one of ``layers`` or
    ``unrendered`` with a named reason. A preview that quietly dropped a layer
    it could not parse would present an INCOMPLETE artifact set as complete —
    the same false-clean direction the mask view refuses, and the precise
    failure this goal exists to remove. The caller must surface ``unrendered``;
    it is never empty-by-omission.

    ``unrendered`` ENTRIES ARE NOT ALL THE SAME NEWS, and the ``kind`` field is
    what lets a viewer tell them apart. ``"job"`` is a file that carries no
    artwork by definition (the ``.gbrjob`` manifest every emission includes) —
    accounted for, but nothing is missing from the picture. ``"artwork"`` is a
    layer that SHOULD have been drawable and was not, which is the only case a
    viewer may raise an incomplete alarm on. Without the split every board
    alarms on its own job manifest, and an alarm that is always on hides the
    one that matters.

    ``bounds_board_mm`` IS THE SAME EXTENT IN THE CALLER'S COORDINATES. The
    emitter negates y on the way into Gerber (see ``gerber._harvest_ir``), so
    ``bounds_mm`` — which is read back off the artifacts — is in Gerber space
    and cannot be handed to a board-space camera. The conversion is done HERE,
    where the negation is owned, rather than re-derived by every viewer that
    wants to place the artwork over the board it describes.

    ONE SHARED COORDINATE FRAME: every layer is rendered with ``force_bounds``
    set to the UNION of all layer bounds, so the SVGs overlay exactly. Rendering
    each file to its own extent would produce images that look right alone and
    misregister when stacked — a preview whose layers disagree about where the
    board is would be worse than no preview.

    sha256 + byte_length give the file IDENTITY the DCR requires, so a reviewer
    can tie what they are looking at to the artifact that would ship.
    """
    import hashlib

    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    compiled = _compile_or_fail(board, _layer_params(params))
    if _is_error_reply(compiled):
        return compiled

    base_name = params.get("name") if isinstance(params.get("name"), str) else None
    try:
        files = gerber.build_gerbers_ir(compiled.board, name=base_name)
    except Exception as exc:  # geometry/library faults reported as data, not crash
        return {"ok": False, "error": {"kind": "gerber", "message": str(exc)}}

    from gerbonara import ExcellonFile, GerberFile
    from gerbonara.utils import MM

    warnings = [_diagnostic_to_payload(d) for d in getattr(files, "diagnostics", [])]
    warnings += [_diagnostic_to_payload(d) for d in compiled.diagnostics]

    # PASS 1 — parse every emitted artifact and collect bounds. A .gbrjob is a
    # JSON manifest, not artwork; it is recorded as unrendered with that reason
    # rather than treated as a failure.
    parsed: list[tuple[str, str, Any]] = []
    unrendered: list[dict] = []
    for fname, text in files.items():
        lower = fname.lower()
        if lower.endswith(".gbrjob"):
            unrendered.append({"name": fname, "kind": "job", "reason":
                               "job manifest (.gbrjob) — metadata, not artwork; nothing to draw"})
            continue
        try:
            if lower.endswith(".drl"):
                obj = ExcellonFile.from_string(text, filename=fname)
                kind = "drill"
            else:
                obj = GerberFile.from_string(text, filename=fname)
                kind = "gerber"
        except Exception as exc:
            # NEVER a silent drop: an artifact we emitted but cannot read back
            # is a finding about our own output, and the caller must see it.
            unrendered.append({"name": fname, "kind": "artwork",
                               "reason": f"gerbonara could not parse the emitted file: {exc}"})
            continue
        parsed.append((fname, kind, obj))

    bounds = None
    for _fname, _kind, obj in parsed:
        try:
            bb = obj.bounding_box(MM)
        except Exception:
            bb = None
        if bb is None:
            continue
        (min_x, min_y), (max_x, max_y) = bb
        if bounds is None:
            bounds = [min_x, min_y, max_x, max_y]
        else:
            bounds = [min(bounds[0], min_x), min(bounds[1], min_y),
                      max(bounds[2], max_x), max(bounds[3], max_y)]

    force_bounds = None
    if bounds is not None:
        force_bounds = ((bounds[0], bounds[1]), (bounds[2], bounds[3]))

    # PASS 2 — render each parsed artifact in the shared frame.
    layers: list[dict] = []
    for fname, kind, obj in parsed:
        raw = files[fname].encode("utf-8")
        try:
            svg = str(obj.to_svg(force_bounds=force_bounds, arg_unit=MM, svg_unit=MM))
        except Exception as exc:
            unrendered.append({"name": fname, "kind": "artwork",
                               "reason": f"parsed but could not be rendered: {exc}"})
            continue
        layers.append({
            "name": fname,
            "kind": kind,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "byte_length": len(raw),
            "svg": svg,
        })

    return {"ok": True, "result": {
        "layers": layers,
        "unrendered": unrendered,
        "bounds_mm": None if bounds is None else {
            "min_x": bounds[0], "min_y": bounds[1],
            "max_x": bounds[2], "max_y": bounds[3]},
        # THE SAME RECTANGLE, un-negated: board y grows downward, Gerber y
        # upward, so the two y bounds swap as well as flip sign.
        "bounds_board_mm": None if bounds is None else {
            "min_x": bounds[0], "min_y": -bounds[3],
            "max_x": bounds[2], "max_y": -bounds[1]},
        "warnings": warnings,
    }}


def _lock_libraries(params: dict) -> dict:
    """PIN this board to the library content it currently resolves (K20, DCR
    019ffc52c358). The verb that makes ``Board.library_lock`` acquirable.

    PURE, exactly like ``normalize``: returns the board with its lock block
    populated for the host to persist, and never writes to disk. Locking is a
    deliberate act with a durable consequence — future rebuilds will REFUSE on
    a mismatch — so it is something a person asks for, never a side effect of
    opening or compiling a board.

    RESOLVES THROUGH THE SAME LIVE CHAIN A COMPILE USES
    (``bless.live_library_chain``), not a raw one. A lock built from the raw
    chain could pin an unblessed WIP part that the compiler would then refuse,
    producing a board that is locked to content it cannot build with — a
    self-inflicted deadlock, and precisely the kind of two-authority drift the
    single-chain rule exists to prevent.

    RELOCKING IS FULL REPLACEMENT, not a merge. A stale pin for a part the
    board no longer uses would otherwise survive forever, and the block is
    meant to describe THIS board's current consumption.

    params: {board|yaml} plus the usual library/layer params.
    Reply: {ok: True, result: {board, locked: [refs], unresolved: [{ref, reason}]}}

    ``unresolved`` is carried, never dropped: a ref no layer supplies cannot be
    pinned, and a caller that saw only the lock would believe the board fully
    pinned when part of it is not. The board is still returned with whatever
    could be pinned — a partial lock is strictly better than none, as long as
    the gap is stated.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    layer_params = _layer_params(params)
    try:
        chain = bless.live_library_chain(
            wip_root=layer_params.get("wip_root"),
            layers=layer_params.get("library_layers"),
            library_root=layer_params.get("library_root"),
            lockfile=layer_params.get("lockfile"))
    except Exception as exc:  # noqa: BLE001 — structured error, not a crash
        return {"ok": False, "error": {
            "kind": "lock_unreadable",
            "message": f"footprint lock could not be loaded: {exc}"}}

    lock: dict = {}
    unresolved: list = []
    seen: set = set()
    components = board.get("components")
    for comp in (components if isinstance(components, list) else []):
        if not isinstance(comp, dict):
            continue
        fp_ref = comp.get("footprint")
        if not isinstance(fp_ref, str) or not fp_ref or fp_ref in seen:
            continue
        seen.add(fp_ref)
        supplier = footprints.lookup_footprint_layer(fp_ref, chain)
        entry = supplier.lock.get(fp_ref) if supplier is not None else None
        if not isinstance(entry, dict) or not isinstance(entry.get("sha256"), str):
            unresolved.append({
                "ref": fp_ref,
                "reason": ("no library layer supplies this footprint"
                           if supplier is None
                           else "the supplying layer's lock entry has no sha256"),
            })
            continue
        pin = {"sha256": entry["sha256"], "layer": supplier.layer.name}
        source = entry.get("source") or entry.get("origin")
        if isinstance(source, str) and source:
            pin["source"] = source
        lock[fp_ref] = pin

    board = copy.deepcopy(board)
    if lock:
        board["library_lock"] = lock
    else:
        board.pop("library_lock", None)
    return {"ok": True, "result": {
        "board": board,
        "locked": sorted(lock.keys()),
        "unresolved": unresolved,
    }}


def _board_health_method(params: dict) -> dict:
    """Standalone whole-board health ledger (Epoch UX2 station 9, docket
    019fde571300) — the SAME `board_health` object every ok route reply
    carries (_board_health: completeness census + tri-state assembly), but
    computable WITHOUT a routing run, so the load path can announce "8 nets
    unrouted, GND in 9 islands" at open, before any routing verb.

    params: {board: <canonical board dict>} (anything `_load` accepts).
    Reply: {ok: True, result: {complete, missing_copper, partial?,
    indeterminate?, assembly:{...}, approximate: True}} — one kernel, same
    keys, same tri-state semantics as the propose-time ledger; a census
    fault degrades inside _completeness_keys ({complete: None,
    completeness_error}), never a raise.

    RESOLVE-FIRST (bug 01a01b6bc649): the completeness census locates pin
    copper from resolve-attached pad geometry, so a CANONICAL board — whose
    library components carry no inline pins — used to census as pin-free and
    return a false `complete: true` on a board with a split net. The
    assembly half already resolved tolerantly for itself
    (_assembly_tri_state's own contract); the census now gets the same
    treatment, so canonical and enriched input yield the identical ledger —
    the property the panel's canonical-wire payload (01a007f1dd02) rests on.
    Any resolution failure falls back to the raw board, the same
    degrade-not-refuse rule _assembly_tri_state uses."""
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}
    layers = _layer_params(params)
    census_board = board
    resolved = _resolve_mapped(board, tolerant=True, layers=layers)
    if isinstance(resolved, dict) and not _is_error_reply(resolved):
        census_board = resolved
    return {"ok": True, "result": _board_health(census_board, [], census_board,
                                                layers=layers)}


def _promote_check(params: dict) -> dict:
    """THE PROMOTION GATE (Epoch UX3 station 11, K13): the full authoritative
    verdict in ONE call — connectivity DRC (:func:`_drc`), geometric DRC
    (:func:`_drc_geometric`, GC1-GC7 over real copper) and the assembly
    advisory — composed fail-closed: ``promotable`` is True ONLY when
    connectivity ran with zero findings AND the geometric union is a
    determinate ``clean`` AND assembly reported no findings. ANY error,
    indeterminate, or finding anywhere makes ``promotable`` False with the
    reason NAMED in ``refusals`` — "could not check" is a refusal here, never
    a pass (K13's own words: impossible, not merely discouraged; there is no
    acknowledge-through on promotion).

    params: {board: <canonical board dict>}.
    Reply: {ok: True, result: {promotable, refusals: [str], advisory?,
    connectivity, geometric, assembly}} — the three sub-reports ride whole so
    a refusing caller can show the actual findings, not just the verdict.

    GRANULAR PROMOTION (Epoch UX4 station 9, DCR 019fe07523ca S6 — OWNER
    RULING, epoch record 019fe06d282d comment 1059: "promotion should be
    granular. For example, I might promote a GND trace, but not another trace
    because I want to move a component"): COMPLETENESS is ADVISORY, not a
    refusal. A clean-but-partially-routed board promotes, with the unrouted
    nets named in result.advisory.completeness (absent when complete).
    CORRECTNESS stays absolute — findings and every indeterminate (census
    included) still refuse; K13's fail-closed reading is intact for
    everything that can be WRONG, it just no longer conflates "wrong" with
    "not finished"."""
    refusals: list = []
    advisory: dict = {}

    # Board-by-reference resolve (work item 01a0223ec9e271269fd664fcf90dd20b,
    # fix cold review F1): the gate's own request rides the capped broker
    # pipe, so an oversized board arrives as {board_path, board_digest}.
    # Resolve it HERE into the inline dict the contract below demands — the
    # F7 uniform-contract rule is about the sub-legs not diverging, not about
    # how the dict reached us. An unreadable/mismatched snapshot is a gate
    # refusal (fail closed), never a crash.
    params = dict(params or {})
    if not isinstance(params.get("board"), dict) \
            and isinstance(params.get("board_path"), str):
        try:
            params["board"] = board_model.load_board({
                "board_path": params["board_path"],
                "board_digest": params.get("board_digest"),
            })
        except board_model.BoardParseError as exc:
            return {"ok": True, "result": {
                "promotable": False,
                "refusals": ["promote_check board_path unreadable: %s" % exc],
                "connectivity": {}, "geometric": {}, "assembly": {},
            }}
    # Input contract, uniform across all three legs (cold review F7): the gate
    # takes exactly {board: <canonical dict>} — the two DRC legs' tolerant
    # _load fallbacks (yaml source etc.) must not make the gate's own contract
    # leg-dependent.
    if not isinstance(params.get("board"), dict):
        return {"ok": True, "result": {
            "promotable": False,
            "refusals": ["promote_check requires a canonical board dict under 'board'"],
            "connectivity": {}, "geometric": {}, "assembly": {},
        }}
    # The sub-checks get a FRESH params dict (cold review F5): forwarding the
    # caller's params verbatim would let knobs like resolve_geometry:false
    # weaken a leg of a gate whose whole point is that it cannot be weakened.
    # The HOST-injected library chain (B7) is the one thing carried across —
    # it is not a caller knob (withLibraryChain overrides it unconditionally),
    # and a gate that resolved seed-only while the fab path resolved the live
    # chain could pass a board whose gerbers use different footprints.
    gate_params = {"board": params["board"], **_layer_params(params)}

    conn_reply = _drc(gate_params)
    connectivity: dict = {}
    if not conn_reply.get("ok"):
        refusals.append("connectivity DRC could not run: %s"
                        % (conn_reply.get("error", {}) or {}).get("message", "unknown"))
        connectivity = {"error": conn_reply.get("error")}
    else:
        connectivity = conn_reply.get("result") or {}
        findings = connectivity.get("findings") or []
        if findings:
            refusals.append("connectivity DRC reports %d finding(s)" % len(findings))
        # COMPLETENESS is part of the connectivity verdict (UX3 cold review F1:
        # every run_drc finding check walks EXISTING segments, so a board with
        # NO copper produces zero findings; the census keys
        # `complete`/`missing_copper` are the half that sees absence).
        # TRI-STATE, split by the UX4 owner ruling (see docstring):
        #   True  -> nothing to say;
        #   None  -> REFUSES (indeterminate is "cannot verify", which is a
        #            correctness problem, not a completeness one);
        #   False -> ADVISORY — the unrouted nets ride result.advisory so the
        #            panel can list them, and promotion proceeds.
        complete = connectivity.get("complete")
        if complete is None:
            refusals.append(
                "connectivity census is indeterminate — an unverifiable "
                "board does not promote")
        elif complete is not True:
            advisory["completeness"] = {
                "complete": False,
                "missing_copper": connectivity.get("missing_copper") or [],
                "partial": connectivity.get("partial") or [],
            }
        elif connectivity.get("routing_deferred"):
            # DECLARED-INTENT ADVISORY (DCR 01a0033a12a9 change 3). This board
            # promotes with unrouted nets because it SAYS it is meant to have
            # them — a via-only board's whole deliverable is the drill file.
            # The advisory exists so the promotion record still NAMES the
            # unrouted nets and the stage that excused them: a `complete: True`
            # reached by declaration must never be indistinguishable from one
            # reached by routing every net.
            advisory["completeness"] = {
                "complete": True,
                "fabrication_stage": connectivity.get("fabrication_stage"),
                "routing_deferred": True,
                "expected_incomplete": bool(
                    connectivity.get("expected_incomplete")),
                "missing_copper": connectivity.get("missing_copper") or [],
                "partial": connectivity.get("partial") or [],
            }

    geo_reply = _drc_geometric(gate_params)
    geometric: dict = (geo_reply.get("result") or {}) if isinstance(geo_reply, dict) else {}
    if not geometric:
        refusals.append("geometric DRC returned no verdict")
    elif geometric.get("verdict") == "violations":
        refusals.append("geometric DRC reports %d finding(s)"
                        % len(geometric.get("findings") or []))
    elif geometric.get("verdict") != "clean":
        refusals.append("geometric DRC is indeterminate (%s) — an unverifiable "
                        "board does not promote"
                        % ((geometric.get("error") or {}).get("kind", "unknown")))

    raw_board = (params or {}).get("board")

    # STAGE INCONGRUENCE — M3's residual foot-gun, advisory only.
    #
    # `routing_deferred` excuses unrouted nets because the board DECLARES that
    # routing is not its deliverable. A declaration is authored once and then
    # forgotten, so a board that has since had copper laid on it still promotes
    # on that excuse, and its census still reports complete:true — reached by
    # declaration, on a board whose copper could have earned the verdict
    # honestly. The two are indistinguishable in the reply, which is how a
    # half-routed board gets promoted as finished.
    #
    # NO GATE CHANGE: the granular-promotion and declared-intent rulings stand,
    # so this names the incongruence and nothing else.
    if isinstance(raw_board, dict) and connectivity.get("routing_deferred"):
        raw_traces = raw_board.get("traces")
        trace_count = len(raw_traces) if isinstance(raw_traces, list) else 0
        if trace_count:
            advisory["stage_incongruence"] = {
                "fabrication_stage": connectivity.get("fabrication_stage"),
                "trace_count": trace_count,
                "note": (
                    "this board's declared fabrication stage defers routing, "
                    "and it carries %d trace(s) — the declaration is what "
                    "excused its unrouted nets from the completeness census, "
                    "so a board that has since been routed is being judged by "
                    "an intent it has outgrown. Re-declare the stage "
                    "(minerva_pcb_fabrication_stage) to have the census judge "
                    "the copper instead." % trace_count
                ),
            }

    if isinstance(raw_board, dict):
        # The ONE computation behind every assembly verdict (_assembly_tri_state
        # owns its own fault→indeterminate boundary — a crash inside reads as
        # indeterminate, which refuses below, never a pass).
        assembly = _assembly_tri_state(raw_board, layers=_layer_params(params))
    else:
        assembly = {"status": "indeterminate", "error": "no board payload"}
    status = str(assembly.get("status", "indeterminate"))
    if status == "findings":
        refusals.append("assembly check reports %d finding(s)"
                        % len(assembly.get("findings") or []))
    elif status != "pass":
        refusals.append("assembly check is indeterminate — an unverifiable "
                        "placement does not promote")

    result = {
        "promotable": not refusals,
        "refusals": refusals,
        "connectivity": connectivity,
        "geometric": geometric,
        "assembly": assembly,
    }
    # Absent-when-empty, the standing additive-key convention: a complete
    # board's reply is byte-identical to the pre-UX4 shape.
    if advisory:
        result["advisory"] = advisory
    return {"ok": True, "result": result}


def _normalize(params: dict) -> dict:
    """Rewrite a canonical SOURCE board to its normalized v2 shape (the sync-back
    the compile fold never persists): legacy inline per-pin fabrication geometry is
    dropped when redundant, migrated to a typed `override` when it diverges, and
    fail-closes the WHOLE normalize when ambiguous.

    PURE — returns the normalized board for the host to persist; NEVER writes to
    disk. Mirrors _resolve/_gerbers: a parse failure or a fail-closed (ambiguous)
    normalize is a structured {ok:False, error} reply, never a crash. On success the
    reply carries the normalized board plus the diagnostics as `warnings` (same
    _diagnostic_to_payload shape the gerbers/kicad handlers use)."""
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    normalized, diagnostics = compile_board.normalize_board(
        board, **_layer_params(params))
    payloads = [_diagnostic_to_payload(d) for d in diagnostics]
    if normalized is None:
        # Fail-closed: an ambiguous pin makes the WHOLE normalize a failure. Surface
        # it with the same {ok:False, error} shape _resolve uses, carrying the
        # serialized fail-closed diagnostics so the caller sees exactly what blocked.
        errors = [p for p in payloads if p.get("severity") == "error"]
        message = "; ".join(p["message"] for p in errors) or "board could not be normalized"
        return {"ok": False, "error": {
            "kind": "normalize", "message": message, "diagnostics": errors or payloads}}
    return {"ok": True, "result": {
        "ok": True, "board": normalized, "warnings": payloads}}


_NO_LIBRARY_DATA_HINT = (
    "No KiCAD library data found under lib_dir. Run minerva_pcb_fetch_libraries first, "
    "then retry (see minerva_pcb_library_status to check what's already fetched)."
)


def _check_libraries(params: dict) -> dict:
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    lib_dir = params.get("lib_dir")
    # lib_dir data is fetched by the Go-side minerva_pcb_fetch_libraries tool (see
    # pcb/internal/libraries/ + docs/libraries.md) into a directory this
    # method never writes to — it only reads whatever is already there. With
    # no lib_dir (or one that doesn't exist / isn't a directory yet) this is
    # an explicit "no data" answer — never a crash.
    if not isinstance(lib_dir, str) or lib_dir.strip() == "" or not os.path.isdir(lib_dir):
        return {"ok": True, "result": {
            "ok": True,
            "checked": 0,
            "missing": [],
            "missing_data": True,
            "hint": _NO_LIBRARY_DATA_HINT,
        }}

    checked = 0
    missing: list[dict] = []
    missing_symbols: list[dict] = []
    for i, comp in enumerate(board.get("components") or []):
        if not isinstance(comp, dict):
            continue
        fp = comp.get("footprint")
        if isinstance(fp, str) and fp != "":
            # Footprint match is REQUIRED per board-yaml's footprint field —
            # boards always reference a footprint, so this gates `ok`.
            checked += 1
            if not libcheck.resolve_footprint(lib_dir, fp):
                missing.append({"path": f"components[{i}].footprint",
                                "ref": comp.get("ref"), "footprint": fp,
                                "suggestions": libcheck.suggest_footprints(lib_dir, fp)})

        # Symbol match is OPTIONAL and informational only: the canonical
        # board-yaml schema has no first-class "symbol" field (components
        # reference footprints, not symbols — see docs/board-yaml.md), but a
        # component may carry one via the schema's Extra passthrough. When
        # present, report a resolve miss as a soft "missing_symbols" entry —
        # it never affects `ok` or `checked`.
        sym = comp.get("symbol")
        if isinstance(sym, str) and sym != "" and not libcheck.resolve_symbol(lib_dir, sym):
            missing_symbols.append({"path": f"components[{i}].symbol",
                                    "ref": comp.get("ref"), "symbol": sym})

    return {"ok": True, "result": {
        "ok": len(missing) == 0,
        "checked": checked,
        "missing": missing,
        "missing_symbols": missing_symbols,
        "missing_data": False,
        "lib_dir": lib_dir,
    }}


def _check_bom(params: dict) -> dict:
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    lib_dir = params.get("lib_dir")
    lib_present = isinstance(lib_dir, str) and lib_dir.strip() != "" and os.path.isdir(lib_dir)
    result = board_model.extract_bom(board, lib_present=lib_present)

    # Footprint presence + nearest-name suggestions only when library data is
    # present (per contract) — mirrors check_libraries's missing_data shape so
    # callers can treat the two tools uniformly.
    if lib_present:
        for it in result["items"]:
            fp = it.get("footprint") or ""
            found = bool(fp) and libcheck.resolve_footprint(lib_dir, fp)
            it["footprint_found"] = found
            if fp and not found:
                it["suggestions"] = libcheck.suggest_footprints(lib_dir, fp)
    result["lib_present"] = lib_present
    result["missing_data"] = not lib_present
    if not lib_present:
        result["hint"] = _NO_LIBRARY_DATA_HINT
    return {"ok": True, "result": result}


# ---------------------------------------------------------------------------
# assembly_bom / assembly_cpl — pre-assembled-order package outputs.
#
# Both COMPILE first, through the same `_compile_or_fail` prologue and the same
# FAB capability profile `_gerbers` uses, then emit from the resulting
# ResolvedBoard IR. One order, one board: the CSVs and the gerbers now derive
# from the same compilation instead of the CSVs being read off the raw board
# dict. The FAB profile is deliberate rather than a narrower assembly-only one
# — a board whose gerbers are refused must not still yield an order's CSVs.
#
# Return/write-to-disk convention deliberately mirrors `_gerbers`
# ({files, written, warnings}), so a caller that already knows how to consume a
# gerbers reply needs no new shape.
# ---------------------------------------------------------------------------


def _compile_for_assembly(params: dict):
    """The shared prologue for both assembly emitters: parse, then strict
    compile, or a NAMED refusal.

    An uncompilable board is the deliberate capability regression the cutover
    creates — BOM/CPL used to be emitted off the raw dict — so it refuses under
    its own `assembly_not_compilable` kind, naming every diagnostic that
    blocked the compile, rather than under the generic compile kind."""
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}
    compiled = _compile_or_fail(board, _layer_params(params))
    if _is_error_reply(compiled):
        return {"ok": False,
                "error": assembly_outputs.not_compilable_error(compiled["error"])}
    return compiled


def _assembly_refusal(exc: Exception) -> dict:
    """One assembly refusal, as the error payload every assembly surface uses.

    `code` is the STABLE refusal name (assembly_gates' gate codes, or the
    emitter exceptions' own class-level codes); the prose names the component
    and the field. Both ride so a surface can match on the code and SHOW the
    sentence without parsing it. An exception carrying no code is a backstop
    fault, not a gate, and keeps the bare `assembly` kind alone."""
    payload = {"kind": "assembly", "message": str(exc)}
    for field in ("code", "component", "field"):
        value = getattr(exc, field, None)
        if value:
            payload[field] = value
    refs = getattr(exc, "refs", ())
    if refs:
        payload["refs"] = list(refs)
    return payload


def _assembly_reply(files, compiled) -> dict:
    """The shared success payload both assembly emitters return.

    Compile WARNING/INFO diagnostics ride along, same shape and same reason as
    `_gerbers`: the board these CSVs describe is the compiled one, so what the
    compiler said about it must not vanish on the way to an order. The two
    absent-when-empty keys (the UX4 advisory idiom) are the honest-outcome half:
    a component the board marks non-populated is REPORTED rather than silently
    missing from the CSVs, and an ADVISORY — something the pipeline could not
    measure, such as a part whose body it could not find — is SHOWN without
    refusing. The caller fills in `written` afterwards."""
    result = {"files": files, "written": [],
              "warnings": [_diagnostic_to_payload(d) for d in compiled.diagnostics]}
    if files.excluded_refs:
        result["excluded_components"] = list(files.excluded_refs)
    if files.advisories:
        result["advisories"] = [dict(a) for a in files.advisories]
    return result


def _write_assembly_files(files: dict, out_dir) -> list | dict:
    """Shared out_dir writer for assembly outputs — same convention as
    `_gerbers`'s inline writer (utf-8 text, one file per dict entry)."""
    if not (isinstance(out_dir, str) and out_dir.strip()):
        return []
    try:
        os.makedirs(out_dir, exist_ok=True)
        written = []
        for fname, text in files.items():
            p = Path(out_dir) / fname
            data = text.encode("utf-8")
            p.write_bytes(data)
            written.append({"path": str(p), "bytes_written": len(data)})
        return written
    except OSError as exc:
        return {"ok": False, "error": {
            "kind": "io", "message": f"failed to write to out_dir: {exc}"}}


def _assembly_bom(params: dict) -> dict:
    """Generate a house-formatted BOM CSV. params: yaml|board, profile
    (house id, default "jlc" — the only assembly-capable profile shipped),
    name (base filename), out_dir (optional disk write)."""
    compiled = _compile_for_assembly(params)
    if _is_error_reply(compiled):
        return compiled

    profile_id = params.get("profile") or "jlc"
    base_name = params.get("name") if isinstance(params.get("name"), str) else None
    try:
        files = assembly_outputs.build_bom(compiled.board, profile_id, name=base_name)
    except Exception as exc:  # matches _gerbers' own comment: "geometry/library
        # faults reported as data, not crash" (methods.py _gerbers, above) —
        # a broad catch here is the dispatcher's established convention for an
        # emitter call over caller-supplied board data, not an exception to it.
        # A NAMED assembly_outputs error (AssemblyProfileError/IdentityError/
        # BoardError, all ValueError subclasses) is the common case; the broad
        # catch is the backstop so nothing escapes handle_request's own
        # try/except as a bare {"kind":"python", "traceback": ...} reply.
        return {"ok": False, "error": _assembly_refusal(exc)}

    written = _write_assembly_files(files, params.get("out_dir"))
    if _is_error_reply(written):
        return written
    result = _assembly_reply(files, compiled)
    result["written"] = written
    return {"ok": True, "result": result}


def _assembly_cpl(params: dict) -> dict:
    """Generate a house-formatted CPL/pick-and-place CSV. Same params/return
    convention as `_assembly_bom`."""
    compiled = _compile_for_assembly(params)
    if _is_error_reply(compiled):
        return compiled

    profile_id = params.get("profile") or "jlc"
    base_name = params.get("name") if isinstance(params.get("name"), str) else None
    try:
        files = assembly_outputs.build_cpl(compiled.board, profile_id, name=base_name)
    except Exception as exc:  # see _assembly_bom's comment: matches _gerbers'
        # broad-catch convention ("geometry/library faults reported as data,
        # not crash"), backstopping the named assembly_outputs errors.
        return {"ok": False, "error": _assembly_refusal(exc)}

    written = _write_assembly_files(files, params.get("out_dir"))
    if _is_error_reply(written):
        return written
    result = _assembly_reply(files, compiled)
    result["written"] = written
    return {"ok": True, "result": result}


# ---------------------------------------------------------------------------
# route — autoroute a board with the vendored agent_router engine.
#
# ONE input shape is accepted: the CANONICAL board (this round's bridge,
# 019eb481ae28), translated to the engine's native Board + RoutingHints by
# pcb_worker.route_bridge. Absolute pad positions are composed from component
# placement + rotated pin offsets using the SAME convention the panel model
# uses (get_pin_world_position), so panel and router agree.
#
#      params.yaml  = canonical board YAML source        (or)
#      params.board = canonical board dict (has "components")
#      params.route_hints = [pcb_route_hint envelope, …]  (optional)
#      params.selection   = which hints feed the run:
#                           {"mode":"open"|"all"|"ids"|"net", …} (default open)
#
# RUN SCOPE (019f80a80123, mechanism 019f6cf2b5f4) — WHICH NETS GET ROUTED:
#
#   route_hints ABSENT or EMPTY  -> the WHOLE board (every net with >= 2 pads).
#                                   "Autoroute this board" is what a bare
#                                   `route(board)` has always meant, it is the
#                                   CLI's and every unhinted caller's contract,
#                                   and there is no selection to narrow it with.
#   route_hints NON-EMPTY        -> ONLY the nets the SELECTED hints implicate.
#
# "Implicates" = the nets those hints actually resolved to, taken verbatim from
# the translation that is about to be handed to the engine
# (HintTranslation.nets_by_hint + the nets of any materialized as-drawn hint) —
# never re-derived, so scope and attribution cannot disagree. Before this, both
# `selection` and `hint_ids` scoped only which hint ANNOTATIONS were consumed;
# the engine still auto-routed everything, so two hints on the smart-remote
# board returned SIXTEEN proposals, one per net.
#
# The empty scope is HONOURED, not widened: non-empty route_hints of which none
# resolves to a net routes NOTHING and says so in `warnings`. Falling back to
# the whole board there would reinstate exactly the surprise above, at the worst
# possible moment — when the worker has just failed to understand the request.
#
# Nets OUT of scope are still fully present on the routing grid — their pads,
# holes and accepted copper are all marked before the scope filter is consulted
# (agent_router/router.py::_scoped_nets), so they remain obstacles. Excluding a
# net from routing never excludes its copper from the grid.
#
# ATTRIBUTION: each returned route carries `hint_ids` — the hints that asked for
# THAT net, not the run's whole selection. Absent-key contract, like "drc":
# omitted entirely on an unhinted whole-board run, where no hint asked for
# anything. `selected_hint_ids` (run-wide) stays what it always was.
#
# The NATIVE shape (grandchild-1's flat pad list, formerly fed through
# _board_from_native) was RETIRED this round: it had no compile, no IR, no
# connectivity DRC, no geometric DRC, and accepted a missing pad size as
# `0x0` — the same class of approximated copper Round E1 removed from the
# canonical path (see pcb/docs/routing.md, "Not yet done"). Zero in-repo
# callers construct it; anything still sending it now gets a structured
# {"kind": "parse"} rejection instead of a silent route over invented
# geometry (see _route, below).
#
# COMMON:
#   params.options = {single_layer?, allow_vias?, trace_width?, clearance?,
#                     order?, grid_resolution?}
#
# OUTPUT: the engine's RoutingResult, serialised to plain JSON
#   {success, via_count, routes:[{net, segments:[{start,end,layer}], vias:[[x,y]]}],
#    unrouted:[{net, from, to, reason?}], warnings?:[{id, message}],
#    selected_hint_ids?:[…],
#    span_outcomes?:[{net, status, pads, connected_via?, hint_ids?}]}
#
#   `span_outcomes` (HITL-4, docs/llm-ergonomics.md F1): the per-span outcome
#   channel for asks that produce neither a route nor an `unrouted` pair —
#   see _serialize_routing_result and RoutingResult.span_outcomes. Absent-key
#   when empty.
#
#   `reason` (docket 019f9d59a49b) is the engine's classification of WHY that
#   pair refused to route (see agent_router.pathfinder.unroutable_reason for the
#   codes) — without it a hard refusal (a pad under an NPTH keepout) and
#   ordinary congestion looked identical to the caller. ABSENT-KEY CONTRACT,
#   same shape as `hint_ids`/`drc` elsewhere on this reply: a pair with no
#   recorded reason OMITS the key entirely. Never `null`, never a placeholder —
#   a null would claim "the engine looked and found no reason", which is not
#   what an unaligned/empty `unrouted_reasons` means.
# ---------------------------------------------------------------------------


def _serialize_routing_result(result) -> dict:
    """Serialise an agent_router.RoutingResult to plain JSON-safe dict."""
    # PAIRING: index alignment (result.unrouted[i] <-> result.unrouted_reasons[i]),
    # NOT a join on (net, from, to).
    #
    # MEASURED (agent_router/router.py, route_board_with_hints, ~line 1957-1965):
    # a net's `connections` list is the automatic spanning-tree pairs PLUS any
    # user-authored `chain` pairs appended verbatim, UNDEDUPLICATED against the
    # tree — docs/routing.md's standing rule for authored input is "admitted or
    # rejected, never reinterpreted", so a chain naming two pads the spanning
    # tree already connects is not collapsed away. If that duplicated pair then
    # fails to route, `result.unrouted` legitimately carries the SAME
    # (net, from, to) triple twice, each with its own independently-computed
    # reason in `result.unrouted_reasons`. A join on the triple could not tell
    # those two entries apart — it would either pick one arbitrarily or pair the
    # wrong reason to the wrong attempt. Index alignment has no such ambiguity:
    # `unrouted` and `unrouted_reasons` are appended together, in lockstep, at
    # both failure sites in router.py (search `unrouted_reasons.append`), so entry i
    # of one is always entry i of the other today.
    #
    # That lockstep guarantee is the engine's, not this function's, so it is
    # verified rather than assumed: only when the two lists are the same length
    # is index i trusted to explain pair i. A shorter/mismatched
    # `unrouted_reasons` (an older engine path, or any future one that appends
    # to one list and not the other) falls back to the absent-key rule for
    # EVERY entry rather than pairing by luck.
    # HITL-4 (docs/llm-ergonomics.md F1): PER-SPAN OUTCOMES ride the reply.
    # ACCOUNTING IDENTITY — every span/net the engine was asked about lands in
    # exactly ONE of `routes`, `unrouted`, or `span_outcomes`; a reply with
    # routes_returned 0, empty unrouted AND no span_outcomes entry for the ask
    # is no longer producible (the live GND BAT1.2→U1.22 already-connected
    # span used to come back byte-identical to a dropped request). ABSENT-KEY
    # contract like `reason`/`hint_ids`: a run with nothing to report carries
    # no `span_outcomes` key at all, so every pre-F1 consumer sees the exact
    # bytes it always saw. Entries are the engine's own JSON-shaped dicts
    # ({span-level `net`, `status` ("already_connected" /
    # "terminals_unmatched" / "bridge_absorbed"), `pads`, best-effort
    # `connected_via` trace/via ids}) — see RoutingResult.span_outcomes for
    # the status vocabulary. `getattr` tolerance for the same reason the
    # corridor_adherence read below uses it: an older engine object without
    # the field must degrade to the absent key, not fault the reply.
    span_outcomes = [dict(o) for o in getattr(result, "span_outcomes", None) or []
                     if isinstance(o, dict)]
    reasons = result.unrouted_reasons
    reasons_aligned = len(reasons) == len(result.unrouted)
    unrouted = []
    for i, (net, p1, p2) in enumerate(result.unrouted):
        entry: dict = {"net": net, "from": f"{p1.component}.{p1.number}",
                       "to": f"{p2.component}.{p2.number}"}
        # `"reason" in reasons[i]` rather than `reasons[i]["reason"]`: a reason
        # dict without that key is unreachable today (`_unrouted_reason_entry`
        # always sets it, `unroutable_reason` returns one of five non-empty
        # constants, and both engine append sites go through that helper), but a
        # KeyError here would fault the ENTIRE route reply — routes, vias and
        # all — over a missing diagnostic. Degrading to the absent-key rule
        # costs one membership test and cannot lose real work.
        #
        # Deliberately NOT `reasons[i].get("reason")`: that smuggles a `None`
        # onto the entry, and a null `reason` claims "the engine looked and
        # found no reason" — the exact false statement the absent-key contract
        # (hint 019f9d061f13) exists to forbid.
        if reasons_aligned and "reason" in reasons[i]:
            entry["reason"] = reasons[i]["reason"]
        unrouted.append(entry)
    return {
        "success": bool(result.success),
        "via_count": int(result.via_count),
        "routes": [
            {
                "net": r.net,
                "segments": [
                    {"start": [s.start[0], s.start[1]],
                     "end": [s.end[0], s.end[1]],
                     "layer": s.layer}
                    for s in r.segments
                ],
                "vias": [[v[0], v[1]] for v in r.vias],
                # Per-connection corridor grading (bug 019fcf152791). Present
                # only for guided connections; an unguided route's shape is
                # byte-identical to what it always was.
                **({"corridor_adherence": list(r.corridor_adherence)}
                   if getattr(r, "corridor_adherence", None) else {}),
                # Station 9 (DCR 019fd095e694): the task routing_constraint
                # revision that steered this route, when a task_constraints
                # entry (not legacy inline waypoints) was what produced it.
                # Same absent-key contract as corridor_adherence above — a
                # route nothing steered from a task carries no such key.
                # F9 (cold review): `is not None`, NOT truthiness — revision 0
                # is a legitimate value (a task's very first constraint, or a
                # caller-supplied 0), and the truthy form used to drop it
                # silently, indistinguishable from "no task steered this".
                **({"constraint_revision": r.constraint_revision}
                   if getattr(r, "constraint_revision", None) is not None else {}),
            }
            for r in result.routes
        ],
        "unrouted": unrouted,
        # Absent-key when empty — see the span_outcomes note at the top.
        **({"span_outcomes": span_outcomes} if span_outcomes else {}),
    }


# NOTE: there is deliberately NO `_is_canonical_route_input` discriminator any
# more. It existed to choose between two input shapes; round A5 retired one of
# them, so there is nothing left to choose. `route` now has a single shape,
# board_model.load_board is its only parser, and the retired shape gets a named
# rejection in _route rather than a branch.


# ---------------------------------------------------------------------------
# DRC-at-propose (docket 019f6f1492e0): after a successful CANONICAL route,
# build the post-route board (existing traces + every returned route
# materialized as traces) and run the EXISTING drc.run_drc engine over it —
# this reuses drc.py's four checks verbatim, it does not reimplement any rule.
# Anything that is not a loadable canonical board is rejected by load_board
# before reaching this point, so every call that gets here has a canonical
# "components"/"nets"/"traces" board to check against.
# ---------------------------------------------------------------------------

# agent_router segment layers are KiCad aliases (F.Cu/In<k>.Cu/B.Cu since
# GA-2). The canonical board's OWN traces use "top"/"in<k>"/"bottom"
# (pcb/docs/board-yaml.md). drc.py's crossing/layer-change checks compare
# `seg.layer` by raw string equality, so a route segment must be normalized to
# the canonical spelling before merge — otherwise a same-layer collision
# between a new route and an existing "top" trace would be missed because
# "F.Cu" != "top" as strings, even though both mean the top layer.


def _canonical_drc_layer(layer: Any) -> str:
    # The FULL contract fold (epoch GA-2): the old hand-built reverse of the
    # 2-entry _LAYER_MAP sent "In2.Cu" to "in2.cu" — not a canonical name, so
    # an inner-layer crossing would have compared unequal to its own layer.
    # kicad_to_canon knows every copper spelling and keeps the historical
    # empty→"top" and unknown→lowercase behaviours (fail-visible).
    from agent_router.layers import kicad_to_canon
    return kicad_to_canon(layer)


def _routes_to_traces(routes: list) -> list:
    """One 2-point trace per route segment. drc._harvest_segments already
    breaks any traces[].points polyline into consecutive (a, b) pairs, so a
    2-point trace per segment is geometrically identical to a merged
    per-layer polyline — simpler and avoids re-deriving chain adjacency."""
    traces: list = []
    for r in routes:
        if not isinstance(r, dict):
            continue
        net = r.get("net")
        for seg in r.get("segments") or []:
            if not isinstance(seg, dict):
                continue
            start = seg.get("start")
            end = seg.get("end")
            if not (isinstance(start, (list, tuple)) and len(start) >= 2
                    and isinstance(end, (list, tuple)) and len(end) >= 2):
                continue
            traces.append({
                "net": net,
                "layer": _canonical_drc_layer(seg.get("layer")),
                "points": [
                    {"x_mm": float(start[0]), "y_mm": float(start[1])},
                    {"x_mm": float(end[0]), "y_mm": float(end[1])},
                ],
            })
    return traces


def _merge_drawn_routes(payload: dict, drawn_routes: list) -> dict:
    """Fold materialized as-drawn routes into an engine result, IN PLACE.

    Extracted so the arithmetic below is reachable by a test (cold review 2,
    finding 4). It was inline in ``_route``, where the only way to exercise it
    was a whole compiled board — so it was never exercised, and the bug sat in
    the one line nobody could reach.

    ``via_count`` is the reason this exists. It comes from
    ``_serialize_routing_result``, which only ever saw the ENGINE result, so a
    run whose only via was AUTHORED reported ``via_count`` 0 while
    ``routes[0].vias`` held it and the board commit went on to create it — a
    caller checking the headline number was told nothing happened.

    As-drawn routes go FIRST, matching the previous inline order.
    """
    payload["routes"] = list(drawn_routes) + list(payload.get("routes") or [])
    payload["success"] = bool(payload.get("success", False)) or not payload.get("unrouted")
    payload["via_count"] = int(payload.get("via_count", 0) or 0) + sum(
        len(r.get("vias") or []) for r in drawn_routes if isinstance(r, dict))
    return payload


def _routes_to_vias(routes: list) -> list:
    """Materialize proposed-route vias for DRC-at-propose (see _drc_for_routes).

    Each via dict carries first-class from_layer/to_layer (canonical
    top/bottom — see pcb_data.gd / board-yaml.md) so it matches the shape of
    a canonical board via. agent_router.router.Route.vias is positional
    ((x, y) only, no layer span — see agent_router/router.py's Route
    dataclass), and under the v1 THROUGH-VIA model (epoch GA-3) that is not
    a gap: a through via's RECORDED span is top<->bottom at ANY stack depth
    — the via physically crosses the whole board and joins every declared
    layer — so "top"/"bottom" here is CORRECT for N-layer boards, not a
    2-layer legacy. This does NOT change the public route() JSON contract
    (routes[].vias stays [[x, y], ...] — see _serialize_routing_result);
    this dict shape is internal to DRC harvesting only. Only a blind/buried
    via (explicitly out of scope v1) would need a real per-via span here.
    """
    vias: list = []
    for r in routes:
        if not isinstance(r, dict):
            continue
        for v in r.get("vias") or []:
            if isinstance(v, (list, tuple)) and len(v) >= 2:
                vias.append({"x_mm": float(v[0]), "y_mm": float(v[1]),
                             "from_layer": "top", "to_layer": "bottom"})
    return vias


def _finding_involves_net(finding: dict, net: Any) -> bool:
    """True if a drc.py finding dict 'involves' the given net name — either
    as the offending trace's own net, one of a crossing's two nets, or the
    net of a pad a trace wrongly landed on (a wrong_net_pad finding involves
    BOTH the trespassing net and the victim pad's net)."""
    if not isinstance(finding, dict) or net is None:
        return False
    if finding.get("net") == net:
        return True
    nets = finding.get("nets")
    if isinstance(nets, list) and net in nets:
        return True
    pad = finding.get("pad")
    if isinstance(pad, dict) and pad.get("net") == net:
        return True
    return False


def _post_route_board(board_dict: dict, routes: list) -> dict:
    """The POST-proposal board: board_dict's existing traces/vias + every
    proposed route materialized as traces/vias. Shallow-copies board_dict
    and replaces only "traces"/"vias" with new lists — the input's own lists
    are never mutated, and no other board field (components/nets/design_rules/
    revision bookkeeping — board_dict is the canonical board, which never
    carries per-hint revision_stack in the first place; that's stripped from
    the route_hints ANNOTATION envelopes upstream by PcbAnnotationHost.
    strip_hint_history, not from this board) is touched.

    Extracted from _drc_for_routes (HITL-4, docs/llm-ergonomics.md F2) so the
    connectivity COMPLETENESS pass reads the identical post-proposal board the
    violation kernel reads — one composition, two questions."""
    post_board = dict(board_dict)
    existing_traces = post_board.get("traces")
    post_board["traces"] = (list(existing_traces) if isinstance(existing_traces, list) else []) \
        + _routes_to_traces(routes)
    existing_vias = post_board.get("vias")
    post_board["vias"] = (list(existing_vias) if isinstance(existing_vias, list) else []) \
        + _routes_to_vias(routes)
    return post_board


def _drc_for_routes(board_dict: dict, routes: list) -> dict:
    """Run drc.run_drc over the post-proposal board (see _post_route_board)."""
    return drc.run_drc(_post_route_board(board_dict, routes))


def _run_drc_findings(runner) -> tuple[list | None, str | None]:
    """(findings, error) for one kernel invocation. A geometry fault is reported
    as DATA, never raised — mirrors _drc(). ``findings`` is None exactly when the
    run could not be made, so a caller can never mistake "no violations" for
    "no answer"; the two are different values, not the same empty list."""
    try:
        return list((runner() or {}).get("findings", [])), None
    except Exception as exc:  # noqa: BLE001 - a fault is a report, not a failure
        return None, str(exc)


def _attach_route_drc(payload: dict, board_dict: dict,
                      scope_nets: set | None = None) -> None:
    """Mutate payload in place with the CONNECTIVITY DRC-at-propose payloads,
    each partitioned into what the PROPOSAL introduces and what the BOARD already
    had (docket 019f9cc386b6).

    Per route:
        "drc": {"scope": "connectivity", "clean": bool, "violations": [...],
                "baseline": {"clean": bool, "violations": [...]}}
    Top level (violation_count ABSENT when clean is None — a check that did not
    run has no count):
        "drc_summary": {"scope": "connectivity", "clean": bool,
                        "violation_count": int,
                        "complete": bool|None, "missing_copper": [net, ...],
                        "partial": [{"net", "pin_groups"}]  (absent when empty),
                        "indeterminate": [{"net", "reason"}] (absent when empty),
                        "approximate": True,
                        "baseline": {"clean": bool, "violation_count": int,
                                     "findings": [...]}}

    COMPLETENESS (HITL-4, docs/llm-ergonomics.md F2): `clean` keeps meaning
    exactly what it meant — "this proposal introduces no short/mismatch" — so
    no existing consumer flips. What it could never say is "and the copper is
    all there": on the live round the summary read clean while net VCC_5V had
    ZERO copper on the board, because missing copper is not a violation the
    kernel can find. The census keys are computed by
    drc.connectivity_completeness over the SAME post-proposal board the
    violation runs read, narrowed to ``scope_nets`` (the run's `only_nets` —
    the nets this request actually asked about; None = whole-board run, every
    net); see _completeness_keys for the tri-state `complete` semantics,
    `indeterminate` (e.g. zone-bearing nets, reason "zone_copper") and the
    standing `approximate` label (DCR 019fd5fd9084 census corrections).
    Attached in the INDETERMINATE branch too: completeness is a separate
    census, and a kernel fault on the violation side does not un-answer it.

    These scoped keys are the PROPOSAL ledger. The BOARD ledger — the same
    census, whole-board scope, plus the assembly tri-state — is the top-level
    `board_health` every ok route reply carries (see _board_health).

    `clean` / `violations` / `violation_count` are PROPOSAL-SCOPED: they answer
    "does accepting this introduce a connectivity violation?", exactly as
    ir_candidates' `verdict` is candidate-scoped on the geometric side. The
    board's own pre-existing violations live under `baseline` and are NEVER
    folded in — a dirty board must not veto an honest proposal, and a clean
    proposal must not launder a dirty board. Before this partition existed both
    numbers billed the proposal for the board's own state — measured on
    tests/test_route_drc.py's `_DIRTY_BASELINE` fixture, whose 3 pre-existing
    findings plus 1 introduced crossing reported violation_count:4, with the
    route's own `violations` listing 3 findings of which 2 predated it.

    The partition comes from a SECOND kernel run over the base board — see
    ir_connectivity.partition_findings, which documents why the geometric
    surface's attribution mechanism cannot be reused for this kernel and why
    `baseline` is therefore exactly a base-only DRC run's output.

    THREE-WAY `clean` (unchanged contract): bool, or None meaning "could not
    determine", with an `error` string. That happens when the post-proposal run
    faults (the pre-existing case) and ALSO when the base run faults while the
    post run succeeded: post findings then exist but cannot be split, so the
    proposal-scoped question has no answer and saying `clean:false` would blame
    the proposal for a partition we could not compute. An indeterminate
    `baseline` carries `clean:None` + `error` and NO violation_count/findings —
    nothing a caller could read as "the board is clean". A DRC-engine fault
    never fails the route call.

    SCOPE (019f958aa6db): this is CONNECTIVITY/topology only — it runs the legacy
    centerline `drc.run_drc`, which cannot verify a clearance/width/annular ring.
    Every payload carries scope:"connectivity" so no consumer (PCBPanel.gd's status
    chip) can render it as a generic/geometric "DRC clean". It is NOT the
    fail-closed geometric union (drc_geometric), and nothing computed here can
    reach `drc_geometric_summary` — the two surfaces answer different questions
    and are kept apart deliberately (ui/panel_tools.gd _write_records_as_proposals).
    """
    routes = payload.get("routes")
    if not isinstance(routes, list):
        return

    base_findings, base_error = _run_drc_findings(lambda: drc.run_drc(board_dict))
    post_findings, post_error = _run_drc_findings(
        lambda: _drc_for_routes(board_dict, routes))

    # The baseline half is answerable on its own: the base run can succeed even
    # when the post run faults, and reporting the board's real state then is
    # strictly better than withholding it.
    if base_error is not None:
        base_summary = {"clean": None, "error": base_error}
    else:
        base_summary = {"clean": not base_findings,
                        "violation_count": len(base_findings),
                        "findings": base_findings}

    # The proposal half needs BOTH runs: post alone cannot be attributed.
    error = post_error or (
        f"connectivity baseline could not be computed: {base_error}"
        if base_error is not None else None)

    if error is not None:
        for r in routes:
            if isinstance(r, dict):
                r["drc"] = {"scope": "connectivity", "clean": None, "error": error,
                            "baseline": _baseline_for_net(base_summary, r.get("net"))}
        # NO violation_count: the check did not run, so there is no count. It
        # used to report 0 here, which reads as "nothing wrong" to anything that
        # does not first branch on clean is None — the same silent degradation
        # the indeterminate `baseline` above refuses to emit, one level up.
        payload["drc_summary"] = {"scope": "connectivity", "clean": None,
                                  "error": error, "baseline": base_summary}
        _attach_completeness(payload["drc_summary"], board_dict, routes,
                             scope_nets)
        return

    introduced, baseline = ir_connectivity.partition_findings(
        base_findings, post_findings)

    for r in routes:
        if not isinstance(r, dict):
            continue
        net = r.get("net")
        violations = [f for f in introduced if _finding_involves_net(f, net)]
        r["drc"] = {"scope": "connectivity", "clean": len(violations) == 0,
                    "violations": violations,
                    "baseline": _baseline_for_net(base_summary, net)}
    payload["drc_summary"] = {"scope": "connectivity", "clean": len(introduced) == 0,
                              "violation_count": len(introduced),
                              "baseline": {"clean": not baseline,
                                           "violation_count": len(baseline),
                                           "findings": baseline}}
    _attach_completeness(payload["drc_summary"], board_dict, routes, scope_nets)


def _completeness_keys(board_dict: dict, routes: list,
                       scope_nets: set | None) -> dict:
    """The connectivity COMPLETENESS census as reply-surface keys.

    ONE kernel behind BOTH ledgers (DCR 019fd5fd9084): the scoped
    `drc_summary` keys (the PROPOSAL ledger — scope_nets = the run's
    only_nets) and `board_health` (the BOARD ledger — scope_nets=None) both
    come from here, so the two can never disagree about what a census key
    means. Runs over the POST-proposal board (committed copper + this reply's
    routes, `_post_route_board`).

    Keys (reply-surface conventions applied — `partial`/`indeterminate`
    absent when empty)::

        {"complete": True|False|None,       # tri-state, drc.py module note
         "missing_copper": [net, ...],
         "partial": [{"net", "pin_groups"}],       # absent when empty
         "indeterminate": [{"net", "reason"}],     # absent when empty
         "fabrication_stage": str,   # DEFERRED BOARDS ONLY — absent on a
         "routing_deferred": True,   #   "routed" board, so no existing reply
         "expected_incomplete": bool,#   shape moves (DCR 01a0033a12a9 ch. 3)
         "approximate": True}                       # standing honesty label

    A DEFERRED board's `complete` is True over a non-empty `missing_copper`,
    and the three keys above are what make that honest: they always travel with
    the verdict they produced, never separately. See
    drc.connectivity_completeness for why intent outranks the lists and why the
    violation checks are untouched by it.

    A census FAULT degrades to `{"complete": None, "completeness_error": str,
    "approximate": True}` (the three-way-clean convention drc_summary already
    uses) — deliberately NO `missing_copper` key then, since an empty list a
    consumer could read as "nothing missing" would be the exact lie-by-
    omission class this census exists to remove. Never raises: a diagnostic
    must not sink the reply it rides."""
    try:
        completeness = drc.connectivity_completeness(
            _post_route_board(board_dict, routes), scope_nets)
    except Exception as exc:  # noqa: BLE001 - a fault is a report, not a failure
        return {"complete": None, "completeness_error": str(exc),
                "approximate": True}
    keys: dict = {"complete": completeness["complete"],
                  "missing_copper": completeness["missing_copper"],
                  "approximate": True}
    if completeness["partial"]:
        keys["partial"] = completeness["partial"]
    if completeness["indeterminate"]:
        keys["indeterminate"] = completeness["indeterminate"]
    # The declaration rides with the verdict it produced. Same absent-when-
    # default convention as the two lists above: a "routed" board says nothing
    # new, so every existing ledger shape is byte-unchanged.
    if completeness["routing_deferred"]:
        keys["fabrication_stage"] = completeness["fabrication_stage"]
        keys["routing_deferred"] = True
        keys["expected_incomplete"] = completeness["expected_incomplete"]
    return keys


def _attach_completeness(summary: dict, board_dict: dict, routes: list,
                         scope_nets: set | None) -> None:
    """Fold the connectivity COMPLETENESS census into a drc_summary in place.

    HITL-4 (docs/llm-ergonomics.md F2) — see _attach_route_drc's docstring for
    the contract, and _completeness_keys for the key shapes + fault
    degradation (`complete: None` + `completeness_error`, never an absent
    `complete` a consumer could read as the pre-F2 shape, never a raise)."""
    summary.update(_completeness_keys(board_dict, routes, scope_nets))


def _baseline_for_net(base_summary: dict, net: Any) -> dict:
    """The per-route view of the board's pre-existing state: the same baseline
    findings, narrowed to the ones involving this route's net, in the route
    payload's own vocabulary ("violations", matching the sibling key).

    An INDETERMINATE baseline is passed through verbatim ({clean:None, error})
    rather than narrowed to an empty list — "we could not check" must not render
    as "this net was clean before"."""
    if base_summary.get("clean") is None:
        return dict(base_summary)
    violations = [f for f in base_summary["findings"]
                  if _finding_involves_net(f, net)]
    return {"clean": len(violations) == 0, "violations": violations}


def _assembly_tri_state(board_dict: dict, *, layers: dict | None = None) -> dict:
    """The tri-state assembly check over the tolerantly-RESOLVED board.

    DCR 019fd5fd9084 / work item 019fd5fddc09 — the one computation behind
    every surface that carries an assembly verdict (the `assembly_check`
    method, route `board_health.assembly`, and resolve_best_effort's
    `assembly`), so no two surfaces can disagree about the same board.

    RESOLVE-FIRST, tolerantly, for the same reason the pre-tri-state route
    attach did (HITL-4 retry finding): the RAW canonical board carries no
    courtyard captures — resolve.py attaches those from the footprint
    libraries — so checking the raw dict silently degrades every library part
    to the pad_extent basis, which provably cannot see the D1/BAT1 class of
    collision (the JST body reaches ~4.5mm past its pads). Any resolution
    failure falls back to the raw board (pad_extent floor) rather than
    checking nothing.

    assembly_check owns its own fault->indeterminate boundary; the outer
    except here makes "never an unstructured exception, never a silent pass"
    a guarantee of THIS seam rather than a reading of that module's source
    (same belt-and-braces the old advisory attach used)."""
    try:
        adv_board = board_dict
        resolved_adv = _resolve_mapped(board_dict, tolerant=True, layers=layers)
        if isinstance(resolved_adv, dict) and not _is_error_reply(resolved_adv):
            adv_board = resolved_adv
        return assembly_advisory.assembly_check(adv_board)
    except Exception as exc:  # noqa: BLE001 - a fault is a report, not a failure
        return {"status": "indeterminate", "findings": [], "error": str(exc)}


def _board_health(census_board: dict, routes: list,
                  assembly_board: dict, *, layers: dict | None = None) -> dict:
    """The WHOLE-BOARD health ledger every ok route reply carries
    (DCR 019fd5fd9084).

    The scoped keys in `drc_summary` are the PROPOSAL ledger — they answer
    "did this run finish what it was asked?" over `only_nets`. This is the
    BOARD ledger: the same census kernel, whole-board scope
    (scope_nets=None), over the same post-proposal board — so a scoped route
    on net A still names net B's missing copper HERE while drc_summary stays
    honestly scoped. Shape::

        {"complete": True|False|None,          # tri-state (drc.py note)
         "missing_copper": [net, ...],          # whole-board census
         "partial": [{"net", "pin_groups"}],    # absent when empty
         "indeterminate": [{"net", "reason"}],  # absent when empty
         "assembly": {status, findings, indeterminate?, error?},
         "approximate": True}

    `census_board` is the connectivity projection the run's DRC read (one
    board, both ledgers); `assembly_board` is the RAW canonical board —
    assembly is placement-only, needs the captured graphics the projection
    drops, and _assembly_tri_state re-resolves it tolerantly for courtyards."""
    health = _completeness_keys(census_board, routes, None)
    health["assembly"] = _assembly_tri_state(assembly_board, layers=layers)
    return health


def _attach_island_deltas(payload: dict, census_board: dict) -> None:
    """Stamp per-route ``island_delta`` + hoist top-level ``island_deltas``.

    Epoch UX2 station 6 (docket 019fde367b24). Per route:
    ``{"pin_groups_before": B, "pin_groups_after": A}`` — the net's
    pin-island count on the PRE-proposal board vs the same board with THIS
    ONE route's copper added (drc.net_pin_group_count — the same union-find
    + credits as the census, so the delta can never disagree with
    board_health.partial about what "island" means). Each route is judged
    ALONE against the base board deliberately: "what does accepting this
    candidate buy?" is a per-candidate question, and crediting route 2 with
    route 1's merges would double-count when the caller accepts only one.

    Absent-key conventions: a net the census cannot judge (single-pin, zone
    copper) or a fault gets NO key — never zeros a reader could mistake for
    "merges nothing". The hoisted ``island_deltas`` list (span_outcomes /
    corridor_adherence convention) carries net + hint_ids attribution and is
    absent when no route earned a delta. Diagnostic only — never sinks the
    reply."""
    deltas: list = []
    for route in payload.get("routes") or []:
        if not isinstance(route, dict):
            continue
        net = route.get("net")
        if not isinstance(net, str) or not net:
            continue
        try:
            before = drc.net_pin_group_count(census_board, net)
            after = drc.net_pin_group_count(
                _post_route_board(census_board, [route]), net)
        except Exception:  # noqa: BLE001 - a diagnostic must not sink the reply
            continue
        if before is None or after is None:
            continue
        route["island_delta"] = {"pin_groups_before": before,
                                 "pin_groups_after": after}
        entry = {"net": net, "pin_groups_before": before,
                 "pin_groups_after": after}
        if route.get("hint_ids"):
            entry["hint_ids"] = list(route["hint_ids"])
        deltas.append(entry)
    if deltas:
        payload["island_deltas"] = deltas


# ---------------------------------------------------------------------------
# GEOMETRIC DRC-at-propose (docket 019f952b99f2) — the COMPLEMENT to the
# connectivity attach above, not a replacement for it.
#
# `_attach_route_drc` answers "is the net topology sane?" over centerlines and
# pad centers. It cannot represent a trace running through the CENTRE of a
# different-net pad, which is how bug 019f80b5124d shipped a shorting proposal
# under a "clean" label. `_attach_route_geometric_drc` answers the copper
# question, by projecting the proposal onto the compiled ResolvedBoard
# (`ir_candidates`) and running the UNCHANGED geometric kernel. Both payloads
# are attached; neither is authoritative for the other's question.
# ---------------------------------------------------------------------------


# PRECEDENCE — the run's EFFECTIVE design rules.
#
# THE chain itself now lives in ``agent_router.router.resolve_effective_rules``
# (019f9bc3909c). It moved because it was unreachable from the OTHER routing
# entry point: agent_router.cli has no compiler and could not import this
# package, so it routed at the engine's signature defaults on a board that
# authored its own (bug 019f9b38a93f). Everything below is a thin adapter — the
# ORDER, the predicates and the fail-closed policy are unchanged and are
# documented at that one implementation.
#
# What changed physically is only WHERE step 3 reads from: the chain now reads
# ``board.design_rules`` instead of reaching into the compiled IR itself. The
# worker fills that slot with the very same ``ResolvedDesignRules`` object it
# used to pass, so the number a worker run routes at is identical.

# Kept under their historical names because this module's own net-class logic
# refers to them; each now DELEGATES to the single implementation rather than
# being a second copy.
#
# The imports sit inside the bodies purely to match the local-import style the
# rest of this module already uses for engine types. NO cold-start claim is
# being made: importing ``pcb_worker.methods`` already pulls
# ``agent_router.router`` in eagerly, so a lazy import here would not restore
# anything. The verified chain (checked by importing methods and reading
# ``sys.modules``, not by reading source) is:
#
#   pcb_worker.ir_candidates:96  `from agent_router.layers import kicad_to_canon`
#     -> executes the agent_router PACKAGE __init__
#     -> agent_router/__init__.py:17  `from .router import (...)`
#
# It is the package __init__ that does it, so importing ANY agent_router
# submodule is enough; route_bridge is NOT the path (it is not even in
# sys.modules after importing methods).


def _nonnegative_mm(value) -> float | None:
    """A finite, non-negative millimetre scalar, or None — see
    :func:`agent_router.router.nonnegative_mm`, which is the implementation."""
    from agent_router import router as engine_router
    return engine_router.nonnegative_mm(value)


def _engine_default_mm(param: str) -> float | None:
    """A millimetre default the ROUTER applies when the caller sets none, read
    from the engine's own signature — see
    :func:`agent_router.router.engine_default_mm`, which is the implementation."""
    from agent_router import router as engine_router
    return engine_router.engine_default_mm(param)


def _ir_rule_mm(rb, *path: str, predicate) -> float | None:
    """One design-rule scalar off a board's ``design_rules``, or None — see
    :func:`agent_router.router._board_rule_mm`, which is the implementation."""
    from agent_router import router as engine_router
    return engine_router._board_rule_mm(rb, *path, predicate=predicate)


def _engine_default_trace_width_mm() -> float | None:
    """The width the ROUTER routes at when the caller sets none (see
    :func:`_engine_default_mm`). Kept as a named accessor because the candidate
    overlay's contract is specifically about the TRACE WIDTH."""
    return _engine_default_mm("trace_width")


def _candidate_overlay_defaults(rb, *,
                                run_trace_width_mm: float | None = None) -> dict:
    """THE precedence for ``ir_candidates.build_overlay``'s fallback dimensions.

    ONE function, both call sites (chore 019fc15cdf13). Before this, the
    propose/route path handed pinned candidates to ``build_overlay`` with NO
    defaults while the geometric-DRC path passed the board's — so the same
    candidate could project on one surface and come back
    ``unsupported_geometry`` on the other. Benign only for as long as every
    candidate happens to carry explicit dimensions; a cross-surface
    inconsistency is exactly the class the parity work exists to remove.

    The precedence, stated once:

      1. the ENTITY's own declared dimensions — ``build_overlay``'s own job, and
         always first: a segment/via that states its size is never overridden.
      2. the RUN's effective trace width, and ONLY for copper THIS RUN PRODUCED.
         That is what keeps the E2 property intact (a proposal is scored at the
         width it was actually routed at, never at a nominal one); it is
         deliberately NOT applied to copper the CALLER handed in, whose width is
         nothing to do with this run's options.
      3. the BOARD's own authored routing defaults (``design_rules.defaults``) —
         the same values acceptance writes, so a dimension-less candidate is
         modelled at what it would BECOME rather than at a guess.
      4. fail closed. ``build_overlay`` still raises when nothing above supplies
         a value; this widens where a value can come FROM, never what happens
         when there is none.

    Step 3 is unreachable on the propose path in practice — every route segment
    is stamped with its width by ``_stamp_effective_routing_rules`` and
    ``run_trace_width_mm`` is the resolved run width — so this is a widening of
    the rule, not a change to any shipped verdict.
    """
    defaults = rb.design_rules.defaults
    width = ir_candidates.positive_mm(run_trace_width_mm)
    if width is None:
        width = ir_candidates.positive_mm(defaults.trace_width_mm)
    return {
        "default_width_mm": width,
        "default_via_diameter_mm": defaults.via_diameter_mm,
        "default_via_drill_mm": defaults.via_drill_mm,
    }


def _effective_routing_rules_detailed(kw: dict, rb) -> tuple[float, str, float, str]:
    """(trace_width_mm, width_source, clearance_mm, clearance_source), or raise
    UnsupportedGeometry.

    Adapter over :func:`agent_router.router.resolve_effective_rules`. Two jobs,
    neither of which is precedence:

      * it accepts anything exposing ``.design_rules`` — the ``agent_router``
        ``Board`` the router consumes (what ``_route`` passes) or the compiled
        ``ResolvedBoard`` itself. Both expose the same two rule paths, so the
        chain is genuinely indifferent;
      * it translates the engine's ``RoutingRulesError`` into this package's
        ``UnsupportedGeometry``, so the worker's structured reply keeps its
        historical ``unsupported_geometry`` error kind.

    ``kw`` carries steps 1 and 2 already merged by ``_route`` (the caller option
    wins there, exactly as before), so from here they are indistinguishable and
    both report as ``"caller_or_hint"``. Only ``_route`` still knows which of the
    two actually supplied a merged value, and it is what refines that label into
    ``"caller_option"`` or ``"hint"`` for the reply.
    """
    from agent_router import router as engine_router
    from .route_bridge import UnsupportedGeometry
    try:
        return engine_router.resolve_effective_rules(rb, kw)
    except engine_router.RoutingRulesError as exc:
        raise UnsupportedGeometry(str(exc)) from exc


def _effective_routing_rules(kw: dict, rb) -> tuple[float, float]:
    """(trace_width_mm, clearance_mm) for this run, or raise UnsupportedGeometry.

    Thin wrapper over :func:`_effective_routing_rules_detailed` that drops the
    provenance labels — kept because most callers (and every pre-existing test)
    want only the pair, and re-deriving the same resolution twice is exactly the
    kind of drift this campaign has been removing.
    """
    width, _width_source, clearance, _clearance_source = \
        _effective_routing_rules_detailed(kw, rb)
    return (width, clearance)




def _net_class_overrides(rb) -> dict[str, tuple[float | None, float | None]]:
    """net name -> (class min_trace_width_mm, class min_clearance_mm), the NEW
    precedence step this round inserts (docs/routing.md, "Per-net-class
    minima"): between the hint-authored width (step 2) and the board's blanket
    design_rules (now step 4).

    Reads ``NetClass.min_trace_width_mm`` / ``.min_clearance_mm`` — the SAME
    two fields ``drc_geometric._net_class_minima`` reads to build GC1's
    ``_effective_min_trace_width`` and GC2's per-pair
    ``_effective_min_clearance`` (docket 019f958b45b9). A net-classed board's
    MINIMA are these two fields on both sides, so the width a net is ROUTED at
    and the floor it is CHECKED against are sourced from one rule rather than
    two that could drift. ``NetClass`` also carries a plain ``trace_width_mm``
    (mirroring
    ``RoutingDefaults.trace_width_mm``, a nominal/default width) — deliberately
    NOT read here: the task is "routes at that class's width/clearance
    MINIMA", and the minima are the ``min_``-prefixed pair, not the nominal
    one.

    A dimension the class says NOTHING about (that field is ``None`` on the
    ``NetClass``) is not in this dict's pair — the run falls through to the
    next step for THAT dimension exactly as if the class were absent, and
    ``_route`` never applies this step at all for a dimension steps 1/2
    already fixed for the whole run (an explicit caller option or a
    hint-authored width is never reinterpreted per net).

    ``rb.design_rules.net_classes`` and each net's ``net_class_id`` are BOTH
    validated at ResolvedBoard construction (resolved_board.py ~1039: "an
    unknown net class" raises there), so a referenced class always exists on
    a real compiled board — the ``None`` guard below is defensive, not a path
    a valid IR can reach.

    A class that DOES carry a value for a dimension is admitted or REJECTED,
    the same policy _explicit_mm already applies to an explicit caller option:
    a class authoring ``min_trace_width_mm: 0`` is a rule that cannot be
    sourced (zero-width copper is not copper), and silently treating it as
    "the class said nothing" would substitute the board's default for what
    the class author asked for — the same dishonesty this whole campaign has
    been removing one round at a time (E1's nominal 1.0x1.0 land, A5's 0x0 pad
    size, this chain's own non-positive explicit width). Fails closed with
    UnsupportedGeometry, same vocabulary as every other unsourceable rule.
    """
    from .route_bridge import UnsupportedGeometry

    # ONE admission policy, owned by net_class_policy (019fa20b11, epoch
    # GA-6): this and drc_geometric._net_class_minima both delegate, so the
    # loop/referenced-only/fail-closed structure can no longer drift between
    # the routed width and the checked floor. This side supplies its own
    # identity (net NAME — the router speaks names) and its own predicates.
    return net_class_policy.referenced_class_minima(
        rb,
        key_of=lambda net: net.name,
        width_admit=ir_candidates.positive_mm,
        clearance_admit=_nonnegative_mm,
        fail=UnsupportedGeometry,
        context="routing")


def _routes_to_candidates(routes: list) -> tuple[list, list]:
    """Split proposed routes into checkable CANDIDATES and the ones with no
    geometry to check. Each route becomes one candidate identified by its index +
    net, because a route reply carries no id of its own; the index is what a
    canvas already uses to address a ghost. Returns (candidates, empty_indices)."""
    candidates: list = []
    empty: list = []
    for index, r in enumerate(routes):
        if not isinstance(r, dict):
            empty.append(index)
            continue
        segments = [s for s in (r.get("segments") or []) if isinstance(s, dict)]
        vias = [v for v in (r.get("vias") or []) if v is not None]
        if not segments and not vias:
            empty.append(index)
            continue
        candidates.append({
            "candidate_id": f"route[{index}]",
            # A route reply carries no revision; the union's `source_digest`
            # (the compiled board's) is what makes a stale result detectable here.
            "revision": None,
            "net": r.get("net"),
            "segments": [dict(s, id=str(s.get("id", "") or f"segment:{i}"))
                         for i, s in enumerate(segments)],
            # Span is top<->bottom because that IS a through via's recorded
            # span at ANY stack depth (epoch GA-3; the engine routes the
            # declared N-layer stack now, but v1 vias are all through-hole
            # and a through via joins every layer). The downstream span
            # consumers expand it to the full occupied set against the
            # board's own stack, so inner-layer collisions ARE modelled.
            # Only a blind/buried via (out of scope v1) would need a real
            # per-via span from the engine.
            "vias": [{"id": f"via:{i}", "position": v, "from_layer": "top",
                      "to_layer": "bottom"} for i, v in enumerate(vias)],
        })
    return candidates, empty


def _attach_route_geometric_drc(payload: dict, rb, *,
                                trace_width_mm: float | None = None) -> None:
    """Mutate payload in place with the GEOMETRIC candidate verdict.

    Each route gains ``"drc_geometric"`` and the payload gains
    ``"drc_geometric_summary"`` (the full candidate union — findings, per-candidate
    verdicts, and the board's own pre-existing ``baseline``).

    DELIBERATELY NOT SPELLED ``clean``. The connectivity attach uses
    ``clean: bool|None``; this one uses ``verdict: "clean"|"violations"|
    "indeterminate"`` so the two can never be confused by a consumer reading a
    truthy field, and so "the check could not run" cannot be read as "the check
    passed". A geometric fault never fails the route call — the proposal still
    returns, with an honest indeterminate verdict.

    Candidate via geometry comes from the board's OWN authored routing defaults
    (``design_rules.via_diameter_mm``/``via_drill_mm``), which is what acceptance
    writes; the trace width is the width the engine routed at. Nothing is
    invented — a value the overlay cannot source makes it fail closed.
    """
    routes = payload.get("routes")
    if not isinstance(routes, list):
        return

    candidates, empty = _routes_to_candidates(routes)
    try:
        # ONE precedence, shared with the pinned-candidate projection in
        # _route (chore 019fc15cdf13) — see _candidate_overlay_defaults. This
        # copper IS what the run produced, so the run's width is passed.
        union = ir_candidates.check_candidates(
            rb, candidates,
            **_candidate_overlay_defaults(rb, run_trace_width_mm=trace_width_mm))
    except Exception as exc:  # noqa: BLE001 - a fault is NOT a clean.
        union = ir_candidates.candidate_indeterminate(
            "internal", f"geometric candidate DRC raised {exc!r}")

    payload["drc_geometric_summary"] = union

    if not union.get("ok"):
        # EVERY ROUTE GETS ITS OWN ENVELOPE, AND ITS OWN IDENTITY.
        #
        # The batch failed as a batch, so every route is indeterminate — that
        # part is shared and stays shared. What must NOT be shared is WHO the
        # reply is talking about. `error["candidate_id"]` names the ONE candidate
        # that could not be modeled, so copying one envelope onto every route
        # made route[1] carry `candidate_id: "route[0]"` — a reply that names the
        # wrong offender and sends someone to fix a route that is fine. That is
        # worse than the anonymity it replaced, so each route now carries:
        #
        #   candidate_id          -> WHICH ROUTE THIS IS (its own id in the batch)
        #   error["candidate_id"] -> THE OFFENDER (usually a different route)
        #
        # Equal => this route is the offender. Different => this route was not
        # checked because another candidate poisoned the batch. Absent from
        # `error` => the offender could not be identified at all (see
        # ir_candidates.UnmodelableCandidate on why absent is never null).
        #
        # `dict(error)` gives each route its own copy rather than an alias, so a
        # consumer that annotates one route's error cannot rewrite another's.
        # The ids are `f"route[{index}]"` over the ORIGINAL route list — the same
        # expression `_routes_to_candidates` uses, and it enumerates the same
        # list, so the two cannot drift.
        error = union.get("error")
        for index, r in enumerate(routes):
            if not isinstance(r, dict):
                continue
            r["drc_geometric"] = {
                "scope": union.get("scope"),
                "verifies_geometry": False,
                "verdict": "indeterminate",
                "candidate_id": f"route[{index}]",
                "error": dict(error) if isinstance(error, dict) else error,
            }
        return

    # An empty route never reaches the overlay (there is no copper to project),
    # so per_candidate would omit it and a caller reading ONLY the summary would
    # see an all-clean verdict with no sign that a route went unchecked. Record
    # them explicitly, for the same reason the per-route branch below refuses to
    # say "clean": silence about copper that was not checked is the dishonesty
    # this surface exists to remove.
    for index in empty:
        union.setdefault("per_candidate", {})[f"route[{index}]"] = {
            "revision": None, "verdict": "indeterminate", "finding_count": 0,
            "reason": "route carries no segments or vias to check"}

    by_candidate: dict = {}
    for finding in union.get("findings", []):
        for subject in finding.get("subjects", []):
            cid = subject.get("candidate_id")
            if cid and cid != ir_candidates.BOARD_SUBJECT_ID:
                by_candidate.setdefault(cid, []).append(finding)

    for index, r in enumerate(routes):
        if not isinstance(r, dict):
            continue
        if index in empty:
            # Nothing to model. Saying "clean" about copper that does not exist
            # would be the exact dishonesty this surface was built to remove.
            r["drc_geometric"] = {
                "scope": union["scope"], "verifies_geometry": False,
                "verdict": "indeterminate",
                "error": {"kind": "unsupported_geometry",
                          "message": "route carries no segments or vias to check",
                          "diagnostics": []}}
            continue
        violations = by_candidate.get(f"route[{index}]", [])
        r["drc_geometric"] = {
            "scope": union["scope"], "verifies_geometry": True,
            "verdict": "violations" if violations else "clean",
            "violations": violations}


def _widen_for_net_classes(baseline: float, source: str,
                          class_values: list) -> tuple[float, str]:
    """The CONSERVATIVE (never-under-block) value for a dimension the whole
    board's keepout margin depends on: the baseline, or whichever class value
    exceeds it. Never narrower than the baseline — a class that asks for LESS
    than the board's own rule does not get to shrink the reservation everyone
    else routes against (docs/routing.md, "Per-net-class minima"). Ties (a
    class exactly matching the baseline) keep the baseline's own source label,
    since nothing was actually widened."""
    result, result_source = baseline, source
    for value in class_values:
        if value > result:
            result, result_source = value, "net_class"
    return result, result_source


def _attach_effective_routing_rules(
    payload: dict, *,
    baseline_width: float, width_source: str,
    keepout_clearance: float, keepout_clearance_source: str,
    net_widths: dict, net_width_sources: dict,
) -> None:
    """Mutate payload in place with PROVENANCE (docs/routing.md, "Provenance"):
    which source supplied the width/clearance a route actually got, never left
    for a consumer to infer from whether a net-class override happens to exist.

    Same honesty principle ``drc_geometric``'s verdict enum already enforces —
    "could not determine" must never be indistinguishable from "determined" —
    applied here to sourcing rather than to a verdict: every route reports a
    concrete ``source``, not just a number, so "the board's own rule" and "an
    invented default" can never look alike to a caller who only reads the value.

    WIDTH is genuinely per-net (it is what gets FABRICATED for that one net's
    own copper) — ``net_widths`` (net name -> width_mm) says which nets differ
    from the baseline, and is the EXACT map handed to ``route_board``/
    ``route_board_with_hints`` (``kw["net_widths"]``), so the copper drawn and
    what this reply claims a route got cannot drift apart.

    ``net_width_sources`` (net name -> source label) is that map's PROVENANCE,
    and is required rather than defaulted: two per-net rules can supply a
    width (a net class's minimum, ``"net_class"``, and the net's own established
    copper, ``"net_copper"``), so a hard-coded label here would report one of
    them as the other. A net in ``net_widths`` with no entry
    here is a caller bug and raises, rather than reporting a source that was not
    consulted: this field exists precisely so a consumer never has to infer
    where a width came from.

    CLEARANCE is NOT per-net — it is already the board-WIDE, worst-case value
    (``keepout_clearance``, computed by ``_widen_for_net_classes`` before this
    is called) that sizes the grid's margin for EVERY marking, so every route
    reports the SAME clearance: the one actually reserved around it, not a
    per-net number a consumer might mistake for what was reserved (see
    docs/routing.md, "Per-net-class minima" -> "Keepout margin").

    Adds:
      * ``payload["effective_routing_rules"]`` — the run-wide values: width is
        the FALLBACK baseline (what an unclassed net's own copper gets),
        clearance is the actually-enforced (possibly class-widened) margin.
      * ``routes[].effective_routing_rules`` — THIS route's own width (differs
        from the baseline only if its net carries a class override) and the
        SAME run-wide clearance every route carries.
      * ``routes[].segments[].width_mm`` — FILLED IN with the per-net width
        where the segment does not already carry one, so the geometric
        candidate overlay below (``ir_candidates.build_overlay``, which reads a
        segment's own ``width_mm`` before any default) checks a net-classed
        proposal at the width it actually got, not the run's baseline
        (docs/routing.md, "the overlay must be checked at the width it was
        routed at" — the false-clean this whole surface exists to prevent). A
        segment that DOES carry one keeps it: that value is the overlay's first
        choice precisely because it is more specific than the net's.
    """
    payload["effective_routing_rules"] = {
        "trace_width_mm": {"value": baseline_width, "source": width_source},
        "clearance_mm": {"value": keepout_clearance, "source": keepout_clearance_source},
    }
    routes = payload.get("routes")
    if not isinstance(routes, list):
        return
    for r in routes:
        if not isinstance(r, dict):
            continue
        net_name = r.get("net")
        if net_name in net_widths:
            width, width_src = net_widths[net_name], net_width_sources[net_name]
        else:
            width, width_src = baseline_width, width_source
        r["effective_routing_rules"] = {
            "trace_width_mm": {"value": width, "source": width_src},
            "clearance_mm": {"value": keepout_clearance, "source": keepout_clearance_source},
        }
        for seg in r.get("segments") or []:
            if isinstance(seg, dict):
                # setdefault, NOT assignment: a segment that already declares a
                # width declared it for a reason (a detailed hint, a reroute
                # given an explicit width), and it is the value ir_candidates
                # reads FIRST when it builds the overlay. Overwriting it made
                # the overlay check that segment at the run's width instead of
                # its own — a phantom violation when the declared width is
                # narrower, and a false clean when it is wider.
                seg.setdefault("width_mm", width)


def _hint_ids_by_net(nets_by_hint: dict, drawn_routes: list) -> dict:
    """Invert {hint id: [nets]} into {net: [hint ids]} — the ATTRIBUTION map.

    Both halves of the reply are covered: engine-routed nets come from the
    translation's own record, as-drawn routes from the `hint_id` each one
    already carries (route_bridge.materialize_detailed_hints stamps it, so
    there is nothing to re-resolve there either).

    Insertion order is preserved rather than sorted: it is the order the hints
    were selected in, which is the order the caller listed them.
    """
    by_net: dict[str, list[str]] = {}
    for hint_id, nets in nets_by_hint.items():
        for net in nets:
            ids = by_net.setdefault(str(net), [])
            if hint_id and hint_id not in ids:
                ids.append(hint_id)
    for route in drawn_routes:
        hid = str(route.get("hint_id", ""))
        net = str(route.get("net", ""))
        if not hid or not net:
            continue
        ids = by_net.setdefault(net, [])
        if hid not in ids:
            ids.append(hid)
    return by_net


def _authored_hint_nets(hints) -> set:
    """Nets named by AUTHORED hint structures the engine routes OUTSIDE the
    scope filter, or inside it but from a user-written pad list.

    agent_router.route_board_with_hints routes buses before (and independently
    of) the scoped net loop, and consumes chains/bridges inside it. Any net
    named by one of those must therefore be IN the scope, or the run would
    either ignore an explicit instruction (chain/bridge) or route a net the
    scope says is out (bus). Folding them in here keeps `only_nets` a superset
    of what the engine will touch BY CONSTRUCTION rather than by an argument
    about which hint kinds route_bridge can currently emit.
    """
    nets: set = set()
    for bus in getattr(hints, "buses", None) or []:
        for net in getattr(bus, "nets", None) or []:
            nets.add(str(net))
    for chain in getattr(hints, "chains", None) or []:
        if getattr(chain, "net", None):
            nets.add(str(chain.net))
    for bridge in getattr(hints, "internal_bridges", None) or []:
        if getattr(bridge, "net", None):
            nets.add(str(bridge.net))
    return nets


def _route(params: dict) -> dict:
    """Autoroute a board with the vendored agent_router engine.

    See the module-level note above for the input/output contract. Engine
    faults are returned as structured errors (never crash the loop).
    """
    bridge_warnings: list = []
    compile_warnings: list = []  # non-fatal compile diagnostics (canonical path)
    drawn_routes: list = []
    selected_hint_ids: list = []
    drc_board: dict | None = None  # set only on the CANONICAL path (see below)
    # The COMPILED board the router consumed — the base the geometric candidate
    # overlay layers proposals onto (019f952b99f2). Same single compile as the
    # other two consumers; canonical path only, like drc_board.
    geometric_board = None

    # Only pass through options the engine actually accepts.
    opts = params.get("options") or {}
    kw: dict = {}
    for key in ("allow_vias", "single_layer", "order",
                "trace_width", "clearance", "grid_resolution"):
        if key in opts and opts[key] is not None:
            kw[key] = opts[key]

    from agent_router.router import route_board, route_board_with_hints

    _board = params.get("board")
    if isinstance(_board, dict) and "pads" in _board \
            and "components" not in _board:
        # Native pad-list shape retired this round (module note above, and
        # pcb/docs/routing.md "Not yet done"): no compile, no IR, no DRC of
        # any kind, and a missing pad size silently became `0x0` — the same
        # class of fictional copper Round E1 removed from the canonical path.
        # Reject it BY NAME here rather than falling through to
        # board_model.load_board below, which rejects it too but with a
        # message that never names what to send instead.
        #
        # Deliberately narrow, in two directions.
        #
        # It fires ONLY on a board that actually carries "pads". Every other
        # malformed input — {}, a non-dict board, a bad yaml type, a dict with
        # neither key — falls through to load_board, whose message accurately
        # describes what IS wrong with it. Gating on "is this not canonical?"
        # instead would have been shorter and would have told a caller who
        # sent {} that the pads shape was retired: a misdiagnosis of an input
        # that never used that shape.
        #
        # And it requires "components" to be ABSENT. A board carrying BOTH
        # keys is treated as canonical, not as an ambiguous shape needing its
        # own error. Before this round the opposite held — any "pads" key
        # vetoed "components" — so a structurally canonical board fell through
        # to the unsafe uncompiled branch on nothing more than a leftover key.
        # No legitimate canonical producer emits a top-level "pads" (canonical
        # pads live under each component's "pins", see docs/board-yaml.md), so
        # treating it as inert is the same "unknown fields survive" tolerance
        # the rest of the canonical contract already extends.
        return {"ok": False, "error": {"kind": "parse", "message": (
            "the flat \"pads\" list board shape was retired; send a "
            "canonical board dict with a \"components\" list, or \"yaml\" "
            "source (see pcb/docs/board-yaml.md).")}}

    # --- Canonical board + pcb_route_hint envelopes -> engine (bridge) ---
    from . import route_bridge
    try:
        board_dict = board_model.load_board(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}
    # DRC-at-propose runs against the projection of the SAME compiled board the
    # router consumes (set below, once the compile succeeds) — never the raw
    # dict. See ir_connectivity: one compile feeds both halves of the reply.
    drc_board = None
    # ROUND E CUTOVER (019f783860c8): canonical routing consumes the compiled
    # ResolvedBoard IR or it does not route. Before this, the router was handed
    # the RAW board and invented a nominal 1.0x1.0 land for any pad without
    # authored geometry — keepouts around fictional copper, so an accepted
    # proposal could cross the real package land. The owner-ratified Step-4
    # ruling puts ROUTING in the fail-closed bucket ("No approximated copper"),
    # so an uncompilable board now returns its compile diagnostics and ZERO
    # routes. Compiled against the narrower ROUTING capability profile: a
    # mask-only limitation must not disable routing, but any dropped
    # copper/drill/rule is still fatal.
    compiled = _compile_or_fail(
        board_dict, _layer_params(params),
        requested_outputs=compile_board.V1_ROUTING_OUTPUTS)
    if _is_error_reply(compiled):
        return compiled
    compile_warnings = [_diagnostic_to_payload(d) for d in compiled.diagnostics]
    # ONE compile, BOTH halves of the reply (019f97d021a8), under ONE error
    # boundary (019f97eb6adf). Routing consumes the IR; connectivity DRC
    # consumes the connectivity projection of that same compiled board. Both
    # projections sit inside this try, so EITHER one meeting geometry it cannot
    # model faithfully produces the same structured zero-route reply — the
    # connectivity projection used to run ahead of the guard, where its failure
    # would have escaped the route error envelope entirely.
    # Net members the projection had to EXCLUDE (a copper-less pad on a net) —
    # collected here so they survive into the reply's warnings rather than
    # taking the whole board down; merged into bridge_warnings below.
    projection_warnings: list[dict] = []
    try:
        board = route_bridge.resolved_board_to_router(
            compiled.board, projection_warnings)
        # The board's FIXED copper: ALREADY-ACCEPTED (T7 019f70ebc9ed) plus any
        # PINNED workspace candidate the caller named (DCR finding 7). Inside the
        # SAME boundary as the other two projections, for the same reason they
        # are: copper the grid cannot model must produce the identical structured
        # zero-route reply, not escape as an unhandled exception. A pinned
        # candidate is a decision the user already made, so the run routes AROUND
        # it exactly as it routes around accepted copper — see
        # route_bridge.existing_copper_with_pinned.
        # SAME overlay-default precedence the geometric DRC uses (chore
        # 019fc15cdf13) — see _candidate_overlay_defaults. No run width is
        # passed: a PINNED candidate is copper the CALLER already has, not
        # copper this run produced, so this run's trace_width option has
        # nothing to say about it; a dimension-less pinned candidate falls to
        # the board's own authored routing defaults, and to fail-closed after
        # that. (kw["trace_width"] is not even resolved yet at this point in
        # _route, which is a second reason the run width does not belong here.)
        existing_traces, existing_vias = \
            route_bridge.existing_copper_with_pinned(
                compiled.board, params.get("pinned_candidates"),
                **_candidate_overlay_defaults(compiled.board))
        # It now also lives ON the Board (019f9bc3909c). Still passed explicitly
        # below — this path always did, correctly, and that is unchanged — but a
        # Board handed to the engine WITHOUT those options no longer silently
        # routes through its own copper.
        board.existing_traces = existing_traces
        board.existing_vias = existing_vias
        drc_board = ir_connectivity.connectivity_board(compiled.board)
        geometric_board = compiled.board
    except route_bridge.UnsupportedGeometry as exc:
        # Compiled fine, but carries geometry the routing grid cannot model
        # faithfully (inner copper, zones, a copper graphic, a non-rectangular
        # outline, or accepted copper spanning a layer the grid does not carry).
        # Fail closed with its own kind so
        # a consumer can tell "this board will not compile" from "this board
        # compiles but is not routable yet".
        return {"ok": False, "error": {
            "kind": "unsupported_geometry", "message": str(exc),
            "diagnostics": compile_warnings}}
    except Exception as exc:
        return {"ok": False, "error": {"kind": "route",
                "message": f"invalid board: {exc}",
                "traceback": traceback.format_exc()}}

    envelopes = params.get("route_hints") or []
    if not isinstance(envelopes, list):
        return {"ok": False, "error": {"kind": "parse",
                "message": "route_hints must be a list of envelopes"}}
    # EXPLICIT RUN SCOPE (DCR finding 7) — the caller STATES the scope instead of
    # it being inferred from whatever hint annotations happen to exist. See
    # route_bridge.parse_route_scope for the shape, and for why a SPAN is refused
    # rather than widened to its whole net.
    #
    # Parsed HERE, against the INTACT board, and deliberately BEFORE
    # materialize_detailed_hints below pops as-drawn nets out of `board.nets`. A
    # scope naming a net an as-drawn hint had already consumed would otherwise be
    # told that net "is not on this board", which is both false and the wrong
    # diagnosis to hand a human. It is APPLIED further down, once the
    # hint-inferred scope it has to be reconciled with exists.
    try:
        explicit_scope = route_bridge.parse_route_scope(
            params.get("scope"), board)
    except route_bridge.UnsupportedRouteScope as exc:
        return {"ok": False, "error": {
            "kind": "unsupported_scope", "message": str(exc),
            "diagnostics": compile_warnings}}

    # Route-as-drawn (HITL-2): 'detailed' single-trace hints ARE the route.
    # Materialize them directly, consume their nets so the engine neither
    # re-routes nor duplicates them, and keep everything else on the
    # engine-guided path.
    drawn_routes, consumed_nets, drawn_warnings, consumed_ids = \
        route_bridge.materialize_detailed_hints(
            envelopes, board, params.get("selection"),
            # The board's DECLARED copper stack, so authored hint geometry
            # cannot land on a layer this board does not have (cold review,
            # epoch NLC). board_dict is the canonical dict `layers` lives on;
            # connectivity_board does NOT carry it, so wiring this to drc_board
            # would have been a check that silently never ran.
            declared_layers=(board_dict or {}).get("layers"))
    for net_name in consumed_nets:
        board.nets.pop(net_name, None)
    remaining = [e for e in envelopes
                 if str((e or {}).get("id", "")) not in consumed_ids] \
        if consumed_ids else envelopes
    # Station 9 (DCR 019fd095e694): the panel-built `task_constraints` map
    # ({hint_id: {corridor_points, preferred_layer, revision}}) rides straight
    # through — hints_to_router owns the override-vs-legacy-waypoints decision
    # per hint; this call site's only job is to not lose the key.
    translation = route_bridge.hints_to_router(
        remaining, board, params.get("selection"), params.get("task_constraints"))
    bridge_warnings = projection_warnings + drawn_warnings + translation.warnings
    selected_hint_ids = consumed_ids + [
        i for i in translation.selected_ids if i not in consumed_ids]

    # RUN SCOPE + ATTRIBUTION (019f80a80123) — see the module note above for the
    # rule and why the empty scope is honoured rather than widened.
    hint_ids_by_net = _hint_ids_by_net(translation.nets_by_hint, drawn_routes)
    only_nets: set | None = None
    if envelopes:
        only_nets = set(hint_ids_by_net) | _authored_hint_nets(translation.hints)
        if not only_nets:
            # Deliberately a warning and an empty run, NOT a whole-board
            # fallback: the caller named hints, so it asked for a scoped run,
            # and the hints failing to resolve is the moment to say so loudest.
            # Every reason each individual hint failed is already in
            # bridge_warnings above (route_bridge._net_for_hint records one per
            # hint); this line names the CONSEQUENCE, which no per-hint warning
            # can, because none of them knows it was the last one.
            bridge_warnings = bridge_warnings + [{"id": "", "message":
                "route_hints were supplied but none resolved to a net on this "
                "board — nothing was routed (a hinted run is scoped to the "
                "nets its hints name; see pcb/docs/routing.md, 'Run scope')"}]

    # The explicit scope (parsed above, against the intact board) is APPLIED here.
    if explicit_scope is not None:
        # A hinted run ALSO carries a scope (above). Two scopes that disagree is
        # the caller telling us two different things, and picking either one
        # silently is the whole defect class this argument exists to close — so
        # the disagreement is named. Intersecting would drop a hint the caller
        # authored without saying so; unioning would route past the scope the
        # caller just stated. Neither is safe to do quietly.
        outside = sorted(n for n in (only_nets or set())
                         if n not in explicit_scope.nets)
        if outside:
            return {"ok": False, "error": {"kind": "unsupported_scope", "message": (
                f"route_hints resolve to net(s) {outside} that the explicit "
                f"scope does not name ({sorted(explicit_scope.nets)}). The run "
                f"has two scopes and they disagree; widening to the union would "
                f"route past the scope you stated, narrowing to the "
                f"intersection would drop a hint you authored. Name the same "
                f"nets in both, or drop one."),
                "diagnostics": compile_warnings}}
        only_nets = set(explicit_scope.nets)
        # Span scoping (docket 019fcb6f9d20): per-net terminal subsets resolved
        # by parse_route_scope ride beside only_nets into the engine — the ask
        # is the task boundary, so "connect A to B" routes A↔B, not the whole
        # net. None when every task was whole-net (unchanged behaviour).
        if explicit_scope.net_terminals:
            kw["net_terminals"] = {
                net: set(refs)
                for net, refs in explicit_scope.net_terminals.items()}
        bridge_warnings = bridge_warnings + [
            {"id": "", "message": w} for w in explicit_scope.warnings]
    # Captured BEFORE the hint merge below, because afterwards "trace_width" in
    # kw no longer says WHICH of the two supplied it — that distinction only
    # exists here, and is what turns _effective_routing_rules_detailed's generic
    # "caller_or_hint" label into the specific one the reply carries.
    caller_set_width = "trace_width" in kw
    caller_set_clearance = "clearance" in kw
    # A hint-authored width becomes the run's trace_width unless the caller
    # set one explicitly (per-hint width has no RoutingHints slot).
    hint_set_width = bool(translation.trace_width_mm and "trace_width" not in kw)
    if hint_set_width:
        kw["trace_width"] = translation.trace_width_mm

    # EFFECTIVE DESIGN RULES (Round E2) — see the precedence note above
    # _effective_routing_rules. Both values are now ALWAYS passed explicitly, so
    # the engine's signature defaults are no longer what a board gets routed at,
    # and the grid inflates its keepouts by `clearance + trace_width / 2` using
    # this exact pair (agent_router/grid.py::keepout_margin). Plumbing the width
    # WITHOUT the matching inflation would be worse than neither: the router
    # would path a 0.35mm trace against keepouts reserved for 0.25mm, so the
    # proposed copper would be wider than the space held for it.
    try:
        # Resolved against the BOARD the engine is about to consume, not against
        # the IR beside it (019f9bc3909c). Same numbers — the Board carries that
        # IR's own ``design_rules`` object — but now the thing being routed and
        # the thing supplying the rules are the SAME object, which is what makes
        # a second entry point inherit them by construction.
        (kw["trace_width"], width_source,
         kw["clearance"], clearance_source) = _effective_routing_rules_detailed(
            kw, board)
    except route_bridge.UnsupportedGeometry as exc:
        return {"ok": False, "error": {
            "kind": "unsupported_geometry", "message": str(exc),
            "diagnostics": compile_warnings}}
    # Refine the generic "caller_or_hint" label into which of the two it was —
    # only this function still has both pieces of information (see the capture
    # above). Steps 3/4 need no refinement; each already names one place.
    if width_source == "caller_or_hint":
        width_source = "caller_option" if caller_set_width else "hint"
    if clearance_source == "caller_or_hint":
        clearance_source = "caller_option"

    # PER-NET-CLASS MINIMA (this round) — the NEW step 3 of the precedence
    # chain, between the hint-authored width (step 2, folded into kw above) and
    # the board's blanket design_rules (now step 4, already resolved into
    # kw["trace_width"]/kw["clearance"]). An explicit caller option or a hint
    # already fixed the WHOLE RUN's value for a dimension — that decision is a
    # run-wide one and is never reinterpreted per net, so a class override for
    # that dimension is dropped rather than silently overriding what the caller
    # or the hint decided (docs/routing.md, "Per-net-class minima" explains the
    # placement). A class's own rule is otherwise admitted-or-rejected exactly
    # like an explicit option — see _net_class_overrides.
    try:
        net_overrides = _net_class_overrides(compiled.board)
    except route_bridge.UnsupportedGeometry as exc:
        return {"ok": False, "error": {
            "kind": "unsupported_geometry", "message": str(exc),
            "diagnostics": compile_warnings}}
    if caller_set_width or hint_set_width:
        net_overrides = {n: (None, c) for n, (w, c) in net_overrides.items()}
    if caller_set_clearance:
        net_overrides = {n: (w, None) for n, (w, c) in net_overrides.items()}
    net_overrides = {n: v for n, v in net_overrides.items() if v != (None, None)}

    # COPPER WIDTH is genuinely per-net — THIS net's own trace is drawn at its
    # class's width, and every other net is unaffected.
    net_widths = {n: w for n, (w, _c) in net_overrides.items() if w is not None}
    net_width_sources = {n: "net_class" for n in net_widths}

    # THE NET'S OWN ESTABLISHED WIDTH — the OTHER per-net rule, resolved in the
    # SAME step 3 and combined with the class minimum by MAX, not by precedence.
    # Both are floors: the class rule is a minimum by name
    # (`min_trace_width_mm`) and by consumer (`drc_geometric` enforces it as
    # GC1's floor whatever routing decided), and GC1 checks only a minimum, so a
    # span joining 0.8mm copper at the board's 0.25mm default passes every gate
    # while being a quarter the width of the copper it joins.
    #
    # The net routes at whichever is wider, and the provenance names the one
    # that decided it. A tie keeps the class label. See
    # route_bridge.established_net_widths for the widest-wins rule on a net whose
    # own copper is not uniform, and docs/routing.md ("Per-net-class minima" ->
    # "The net's own established width").
    #
    # Dropped wholesale — like the class width, and for the identical reason —
    # when steps 1/2 already fixed the width for the WHOLE RUN: a caller who
    # states `trace_width: 0.6` gets 0.6 on every net, reported as
    # `caller_option`.
    if not (caller_set_width or hint_set_width):
        try:
            established = route_bridge.established_net_widths(existing_traces)
        except route_bridge.UnsupportedGeometry as exc:
            return {"ok": False, "error": {
                "kind": "unsupported_geometry", "message": str(exc),
                "diagnostics": compile_warnings}}
        for net_name, established_width in established.items():
            if established_width > net_widths.get(net_name, 0.0):
                net_widths[net_name] = established_width
                net_width_sources[net_name] = "net_copper"

    # The KEEPOUT MARGIN is NOT per-net (Codex must-fix on this round): a ring
    # sized to one net's own requirement cannot ALSO satisfy a STRICTER class
    # net that approaches that same copper later — the ring is a static
    # reservation, sized once, by whichever net's copper it protects, and has
    # no notion of "the net that queries it later has a bigger demand of its
    # own". That is an UNDER-block, and routing.md's invariant ("the modeled
    # keepout must be a SUPERSET of the fabricated copper... under-blocking
    # never is legal") has no net-class exception. The fix is the same
    # conservative move this campaign uses everywhere it meets an under-block
    # it cannot model exactly (the pad AABB superset, the oval-hole containing
    # disc, the conservative NPTH obstacle): the grid's OWN clearance/
    # trace_width — which size EVERY marking uniformly — become the WIDEST
    # value any class present on the board demands, never narrower than the
    # run's own baseline. See docs/routing.md, "Per-net-class minima" ->
    # "Keepout margin".
    keepout_clearance, keepout_clearance_source = _widen_for_net_classes(
        kw["clearance"], clearance_source,
        [c for _w, c in net_overrides.values() if c is not None])
    # Read off `net_widths` — the FINAL per-net map, class minima and
    # established-copper widths already merged — rather than off `net_overrides`
    # alone. The grid's margin is `clearance + trace_width / 2` where that
    # trace_width is the NEWCOMER's half-width (agent_router/grid.py::mark_trace),
    # so it must cover the widest copper THIS RUN may draw: a net routed at its
    # own established 0.8mm while the grid reserved for 0.25mm is an under-block.
    keepout_trace_width = max([kw["trace_width"]] + list(net_widths.values()))

    kw["net_widths"] = net_widths
    kw["keepout_clearance"] = keepout_clearance
    kw["keepout_trace_width"] = keepout_trace_width
    # ALREADY-ACCEPTED COPPER (T7 019f70ebc9ed). Other-net copper becomes an
    # obstacle through the same markers — and therefore the same
    # RoutingGrid.keepout_margin — as the copper this run lays; same-net copper
    # is already-connected, so the net may path along it and the pads it joins
    # are not proposed again. Both engine entry points take it, so hinted and
    # unhinted runs see the identical board.
    kw["existing_traces"] = existing_traces
    kw["existing_vias"] = existing_vias
    # THE BOARD'S OWN COPPER STACK (epoch GA-2): the engine allocates one grid
    # plane per declared layer, stack-ordered. Same source _routing_layer_ids
    # every other projection uses, so the grid, the pads, and the accepted
    # copper all agree on which planes exist.
    kw["layers"] = list(route_bridge._routing_layer_ids(compiled.board))
    # A PROPOSED via now reserves its own annulus on every layer (GA-2); the
    # diameter is the board's authored via size — the same number the
    # committed via will fabricate at.
    kw["via_diameter"] = float(
        compiled.board.design_rules.defaults.via_diameter_mm)
    # RUN SCOPE (019f80a80123), resolved above. Set HERE, beside the other engine
    # kwargs, and deliberately AFTER the two lines above: `existing_traces` is
    # the whole board's accepted copper and stays that way whatever the scope
    # is. An out-of-scope net's copper is still marked on the grid — see
    # agent_router/router.py::_scoped_nets.
    kw["only_nets"] = only_nets

    try:
        if translation.hints.net_hints or translation.hints.buses \
                or translation.hints.chains or translation.hints.internal_bridges:
            result = route_board_with_hints(board, translation.hints, **kw)
        else:
            result = route_board(board, **kw)
    except Exception as exc:
        return {"ok": False, "error": {"kind": "route",
                "message": str(exc), "traceback": traceback.format_exc()}}

    payload = _serialize_routing_result(result)
    if drawn_routes:
        _merge_drawn_routes(payload, drawn_routes)
    # PER-ROUTE ATTRIBUTION (019f80a80123). Stamped over the MERGED route list,
    # so as-drawn and engine routes are attributed by the one map; and stamped
    # only when hints were supplied, so an unhinted whole-board run carries no
    # `hint_ids` key at all rather than an empty list that would read as "no
    # hint wanted this" when the truth is "no hint was asked".
    #
    # A route whose net is in NO hint's list gets []. Writing the blanket
    # `selected_hint_ids` here instead would be the exact field-that-lies this
    # round exists to remove, and a field that lies is worse than no field at
    # all (same ruling as routing-rule provenance, round A4).
    #
    # CORRECTED IN REVIEW — an earlier version of this comment claimed the []
    # case "cannot happen under the scope above, because the scope IS the union
    # of those lists". That is false: the scope is that union UNION
    # `_authored_hint_nets`. A chain or bridge net reaches the run through the
    # second term and is absent from `nets_by_hint`, so it would be stamped
    # `hint_ids: []` — reading as "no hint wanted this" when a hint did.
    # LATENT ONLY today: route_bridge.hints_to_router never emits chains or
    # bridges, so the lists read above are always empty and no route can take
    # that path. If chain/bridge authoring is ever wired up, `nets_by_hint`
    # must gain those nets in the same pass, or this stamp starts lying.
    if envelopes:
        for route in payload.get("routes") or []:
            if isinstance(route, dict):
                route["hint_ids"] = list(
                    hint_ids_by_net.get(str(route.get("net", "")), []))
        # HITL-4 (docs/llm-ergonomics.md F1): span OUTCOMES are attributed by
        # the same net->hints map as routes, under the same hinted-run-only
        # gate — an already-connected span the caller's hint asked about must
        # be filed back against that hint exactly as a routed one would be.
        for outcome in payload.get("span_outcomes") or []:
            if isinstance(outcome, dict):
                outcome["hint_ids"] = list(
                    hint_ids_by_net.get(str(outcome.get("net", "")), []))
    # Non-fatal COMPILE diagnostics travel with the proposal too (Codex ruling 2):
    # a route computed over a board that compiled with warnings must not look
    # indistinguishable from one that compiled clean.
    if bridge_warnings or compile_warnings:
        payload["warnings"] = bridge_warnings + compile_warnings
    if selected_hint_ids:
        payload["selected_hint_ids"] = selected_hint_ids
    # CORRIDOR ADHERENCE, hoisted to the top level (bug 019fcf152791 Stage B).
    # It lives per-route as well, but the caller that has to decide whether a
    # proposal honoured its author's intent should not have to walk every
    # route to discover that one corridor was missed.
    _corridor_report: list = []
    for _route in payload.get("routes") or []:
        if isinstance(_route, dict):
            _corridor_report.extend(_route.get("corridor_adherence") or [])
    if _corridor_report:
        payload["corridor_adherence"] = _corridor_report
    # Echoed so a task-form scope is distinguishable from a net-form one in the
    # reply — the caller sent RouteTask ids, and a reply that drops them makes
    # the two forms indistinguishable to the workspace that has to file the
    # result back against a task.
    if explicit_scope is not None and explicit_scope.task_ids:
        payload["scope_task_ids"] = list(explicit_scope.task_ids)

    # PROVENANCE (this round; docs/routing.md "Provenance") — attached to every
    # route, including drawn/as_drawn ones merged in above, BEFORE the DRC
    # attaches below so the geometric overlay reads the per-net width this just
    # stamped rather than falling back to the run's baseline for a net-classed
    # net (see _attach_effective_routing_rules).
    _attach_effective_routing_rules(
        payload, baseline_width=kw["trace_width"], width_source=width_source,
        keepout_clearance=keepout_clearance,
        keepout_clearance_source=keepout_clearance_source,
        net_widths=net_widths, net_width_sources=net_width_sources)

    # DRC-at-propose (docket 019f6f1492e0): every call reaching here is on the
    # canonical path (the native pad-list shape is rejected at the top of
    # _route, everything else by load_board), so drc_board is always set below.
    if drc_board is not None:
        # `only_nets` (None = whole-board) scopes the F2 completeness census to
        # the nets this request asked about — see _attach_route_drc.
        _attach_route_drc(payload, drc_board, scope_nets=only_nets)
    # GEOMETRIC DRC-at-propose (019f952b99f2) — the copper complement, attached
    # ALONGSIDE the connectivity result above (never instead of it). The overlay
    # is checked at the width the run ACTUALLY routed at: since E2 that is
    # `kw["trace_width"]` itself, the one value _effective_routing_rules resolved
    # and handed to the engine, so a proposal can no longer be geometrically
    # cleared at a width it was not routed at (a false clean). This USED to be a
    # parallel re-derivation of the same precedence, which agreed by coincidence
    # rather than by construction; the coincidence is now a shared variable.
    if geometric_board is not None:
        _attach_route_geometric_drc(
            payload, geometric_board,
            trace_width_mm=ir_candidates.positive_mm(kw.get("trace_width")))

    # BOARD HEALTH (DCR 019fd5fd9084): the whole-board ledger, ALWAYS present
    # on an ok route result regardless of request scope — the scoped
    # drc_summary keys above are the PROPOSAL ledger, this is the BOARD one
    # (see _board_health). It replaces the old optional top-level
    # `assembly_advisories` key: the assembly verdict now rides INSIDE it as
    # the tri-state `board_health.assembly` (work item 019fd5fddc09), so a
    # clean board says "pass" out loud instead of saying nothing. Census over
    # the SAME connectivity projection the run's DRC read (drc_board is
    # always set on this path — module comment above — but the raw canonical
    # board is an honest fallback, not a skipped ledger, if that ever
    # changes); assembly over the raw board, re-resolved for courtyards.
    # ISLAND DELTA (Epoch UX2 station 6, docket 019fde367b24): per-route
    # census CREDIT, computed against the pre-proposal board — "GND partial,
    # 9 pin groups" is true but unactionable on its own; "this route merges
    # 2 islands -> 8 remain" is a decision aid. Rides each route AND is
    # hoisted top-level as `island_deltas` (the span_outcomes/
    # corridor_adherence convention), attributed by the same hint_ids stamp.
    _attach_island_deltas(
        payload, drc_board if drc_board is not None else board_dict)

    payload["board_health"] = _board_health(
        drc_board if drc_board is not None else board_dict,
        payload.get("routes") or [], board_dict,
        layers=_layer_params(params))

    return {"ok": True, "result": payload}


# ---------------------------------------------------------------------------
# draft_check (T2.4) — honest DRC over the COMPLETE effective candidate set.
#
# The reusable NATIVE draft-check seam T5 (verbs) depends on. Unlike route()'s
# DRC-at-propose (which checks the ONE route it just computed), draft_check is
# SET-SCOPED: it runs the EXISTING drc.run_drc primitives (drc.py's four checks,
# reused verbatim — this reimplements no rule) over the UNION of the board's
# committed copper AND every candidate's draft segments/vias. A verdict for a
# candidate therefore depends on the whole effective set — a collision between
# two candidates, or between a candidate and committed copper, is found.
#
# ON-DEMAND ONLY. Debounce/coalescing/cancellation/auto-recheck are T6 and are
# NOT built here — draft_check is a pure function of its params.
#
# params = {
#   board: <canonical board dict>,
#   candidates: [{candidate_id, net, revision, segments:[{id,layer,width,points}],
#                 vias:[{id,position,from_layer,to_layer,...}]}],
#   board_token: <opaque str — the GD board-coherence fingerprint>,
#   workspace_generation: <opaque int — the GD workspace generation>,
# }
# Segment points and via positions travel as [[x,y], ...] / [x,y] (JSON-friendly,
# mirroring route()'s segment coordinate style); {x_mm,y_mm}/{x,y} dicts are also
# accepted defensively. Candidate layers are canonical "top"/"bottom" (same
# spelling as committed board traces) so drc's raw-string layer equality lines
# up; F.Cu/B.Cu are normalized defensively.
#
# reply = {ok, result: {board_token, workspace_generation, findings:[...],
#          per_candidate:{candidate_id: "clean"/"violating"/"error"}}}
# board_token + workspace_generation are ECHOED VERBATIM (never coerced) so the
# GD side can discard a stale reply. Each finding names SUBJECT IDENTITY —
# subjects:[{candidate_id, segment_id?/via_id?}] — not net-only; a violation
# between two candidates names BOTH subjects (candidate-vs-committed names the
# candidate + a {candidate_id:"board"} subject).
# ---------------------------------------------------------------------------


def _dc_dist(a, b) -> float:
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


# The candidate wire-shape coercion moved to the neutral :mod:`ir_candidates`
# owner (019f952b99f2) so the CONNECTIVITY candidate surface (draft_check) and the
# GEOMETRIC one accept exactly the same candidate language. A shape one accepts
# and the other silently drops would be a correctness trap. Aliased, not
# re-implemented; the local names are kept for existing callers/tests.
_dc_points = ir_candidates.candidate_points
_dc_via_pos = ir_candidates.candidate_via_position


def _dc_pt_touches_seg(pt, a, b, eps: float) -> bool:
    """True if pt lies within eps of segment a-b (endpoints included)."""
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    seg_len2 = dx * dx + dy * dy
    if seg_len2 <= 1e-18:
        return _dc_dist(pt, a) <= eps
    t = ((pt[0] - ax) * dx + (pt[1] - ay) * dy) / seg_len2
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    proj = (ax + t * dx, ay + t * dy)
    return _dc_dist(pt, proj) <= eps


def _dc_clearance(board) -> float:
    """Same clearance derivation drc.run_drc uses — the attribution tolerance."""
    clr = drc.DEFAULT_COINCIDENT_MM
    dr = (board or {}).get("design_rules") if isinstance(board, dict) else None
    if isinstance(dr, dict):
        c = dr.get("clearance_mm")
        if isinstance(c, (int, float)) and not isinstance(c, bool) and c > 0:
            clr = float(c)
    return clr


def _dc_attribute(finding: dict, seg_subjects: list, via_subjects: list,
                  eps: float) -> list:
    """Map a drc.py finding back to the candidate/board subjects it names.

    A finding carries only net(s) + an `at` point (drc is net-scoped); this
    re-derives WHICH candidate segment/via that point falls on so the seam can
    surface subject identity. crossing names both crossing nets' segments;
    the endpoint checks (wrong_net_pad / dangling / layer_change_no_via) name
    the offending net's segments (and any candidate via coincident with `at`,
    e.g. the layer-change meeting point)."""
    at = finding.get("at")
    if not (isinstance(at, (list, tuple)) and len(at) >= 2):
        return []
    pt = (float(at[0]), float(at[1]))
    kind = finding.get("type")
    subjects: list = []
    seen: set = set()

    if kind == "crossing":
        nets = {str(n) for n in (finding.get("nets") or [])}
        layer = finding.get("layer")
        for s in seg_subjects:
            if s["net"] in nets and s["layer"] == layer \
                    and _dc_pt_touches_seg(pt, s["a"], s["b"], eps):
                key = ("seg", s["candidate_id"], s["segment_id"])
                if key not in seen:
                    seen.add(key)
                    subjects.append({"candidate_id": s["candidate_id"],
                                     "segment_id": s["segment_id"]})
    else:
        net = str(finding.get("net"))
        for s in seg_subjects:
            if s["net"] == net and _dc_pt_touches_seg(pt, s["a"], s["b"], eps):
                key = ("seg", s["candidate_id"], s["segment_id"])
                if key not in seen:
                    seen.add(key)
                    subjects.append({"candidate_id": s["candidate_id"],
                                     "segment_id": s["segment_id"]})
        for v in via_subjects:
            if _dc_dist(pt, v["pos"]) <= eps:
                key = ("via", v["candidate_id"], v["via_id"])
                if key not in seen:
                    seen.add(key)
                    subjects.append({"candidate_id": v["candidate_id"],
                                     "via_id": v["via_id"]})
    return subjects


def _draft_geometric(board: dict, candidates: list,
                     layer_params: dict) -> tuple[list, dict, dict]:
    """Geometric findings over the COMPOSED DRAFT BOARD (K9, 019fa6ed5e23).

    WHY THIS EXISTS, and what was wrong without it. The panel composes canonical
    geometry plus the live staged overlay — staged zones appended, staged
    placements applied — and sends that board to draft_check. But draft_check's
    own subject set is built ONLY from board["traces"] and board["vias"] plus the
    candidates, and its verdict came from drc.run_drc, whose module docstring
    states outright that it reads pad CENTERS and trace CENTERLINES only and
    CANNOT verify clearances. So the composition was INERT: a staged zone or a
    moved component could not produce a finding no matter how badly it violated,
    because nothing in the path ever looked at zones, components or pads.

    That is the difference between composing correctly and CHECKING what was
    composed, and only the first half had been built.

    This compiles the composed board ONCE, then delegates candidate projection,
    checking and attribution to :func:`ir_candidates.check_candidates` — the
    existing neutral owner used by propose-time geometric DRC. That owner adds
    candidates at the ResolvedBoard level, supplies board-authored via defaults,
    and attributes every geometric finding by the IR entity ids the kernel
    actually reports. Rebuilding a second raw-board overlay here previously
    omitted required via fields and then tried to attribute witness-pair findings
    with the connectivity checker's unrelated ``at``-point heuristic.

    FAIL-CLOSED. Returns (all_findings, per_candidate, indeterminate). A compile
    that refuses, an unmodelable candidate, or a kernel that meets geometry it
    cannot model yields NO findings and a NAMED indeterminate — never an empty
    finding list a caller could read as clean. ``all_findings`` includes the
    composed board's baseline findings as well as candidate-introduced findings;
    only the latter carry candidate subjects and affect per-candidate verdicts.
    """
    try:
        result = compile_board.compile_board(board, **layer_params)
    except board_model.BoardParseError as exc:
        return [], {}, {"kind": "parse", "message": str(exc)}
    except Exception as exc:  # noqa: BLE001 — data, not a crash
        return [], {}, {"kind": "internal", "message": f"compile_board raised {exc!r}"}

    if isinstance(result, compile_board.ResolutionSuccess):
        warnings = tuple(_diagnostic_to_payload(d) for d in result.diagnostics)
        try:
            union = ir_candidates.check_candidates(
                result.board, candidates, warnings=warnings,
                **_candidate_overlay_defaults(result.board))
        except Exception as exc:  # noqa: BLE001 — a fault is NOT a clean.
            union = ir_candidates.candidate_indeterminate(
                "internal", f"draft candidate geometric DRC raised {exc!r}")
    else:
        union = geometric_drc_from_resolution(result)
    if not union.get("verifies_geometry", False):
        # INDETERMINATE: the kernel could not model this board. Reported as
        # itself rather than flattened into "no findings", which is the exact
        # false-clean K14 forbids.
        #
        # READ FROM THE SHAPE THE KERNEL ACTUALLY RETURNS (Codex re-review
        # finding 5): the reason lives under `error`, not at the top level. The
        # first version read nonexistent top-level keys, so every refusal —
        # parse fault, unresolved geometry, unmodelable primitive — collapsed
        # into the same default string and the actual cause was lost. An
        # indeterminate that cannot say WHY is barely better than a silent one.
        err = union.get("error") if isinstance(union.get("error"), dict) else {}
        indeterminate = {
            "kind": str(err.get("kind", "unresolved_geometry")),
            "message": str(err.get("message", "geometry could not be verified")),
            "details": err.get("diagnostics", []),
        }
        # Preserve the structured attribution supplied by UnmodelableCandidate.
        # In a batch-atomic refusal this is the only machine-readable answer to
        # "which candidate poisoned the batch?"; leaving it embedded only in
        # prose makes automated repair needlessly guess.
        if "candidate_id" in err:
            indeterminate["candidate_id"] = err["candidate_id"]
        return [], {}, indeterminate

    findings = list((union.get("baseline") or {}).get("findings", []) or [])
    findings += list(union.get("findings", []) or [])
    per_candidate = {}
    for raw_cid, record in (union.get("per_candidate") or {}).items():
        verdict = record.get("verdict") if isinstance(record, dict) else None
        if verdict == "violations":
            per_candidate[str(raw_cid)] = "violating"
        elif verdict == "clean":
            per_candidate[str(raw_cid)] = "clean"
        else:
            # The current producer has exactly two determinate tokens. A future
            # partial/unknown token is not evidence of clean geometry; treat the
            # contract mismatch as batch-indeterminate until this adapter gains
            # explicit semantics for it.
            return [], {}, {
                "kind": "internal",
                "message": "geometric candidate DRC returned unknown verdict "
                           f"{verdict!r} for candidate {raw_cid!r}",
                "candidate_id": str(raw_cid),
                "details": [],
            }
    return findings, per_candidate, {}


def _draft_check(params: dict) -> dict:
    # Board-by-reference resolve, the same shape _promote_check uses. This
    # request rides the same capped broker pipe every board-carrying channel
    # does, so an oversized board arrives as {board_path, board_digest} — and
    # without this it arrived as no board at all, which this method reads as
    # "score the candidates against empty committed copper". That is a CLEAN
    # verdict on a board whose copper was never looked at: precisely the
    # false-clean the whole draft check exists to prevent, and it fires on
    # exactly the large boards that need checking most.
    params = dict(params or {})
    if not isinstance(params.get("board"), dict) \
            and isinstance(params.get("board_path"), str):
        try:
            params["board"] = board_model.load_board({
                "board_path": params["board_path"],
                "board_digest": params.get("board_digest"),
            })
        except board_model.BoardParseError as exc:
            # FAIL CLOSED: no verdict at all rather than a verdict computed
            # without the committed copper. The panel reverts every candidate
            # to the validation it had.
            return {"ok": True, "result": {
                "board_token": params.get("board_token"),
                "workspace_generation": params.get("workspace_generation"),
                "findings": [],
                "per_candidate": {},
                "error": "draft_check board_path unreadable: %s" % exc,
            }}
    board = params.get("board")
    candidates = params.get("candidates") or []
    # Echoed VERBATIM (no int/str coercion) so the GD guard can compare exactly.
    board_token = params.get("board_token")
    workspace_generation = params.get("workspace_generation")

    # Echoed back so the panel can tie a finding that names a staged entity to
    # the store entry it came from. Sent by the panel beside the board; without
    # the echo it was write-only, which is why it had no consumer.
    draft_provenance = params.get("draft_provenance")

    def _reply(findings, per_candidate, error=None, geometric_indeterminate_=None):
        result = {
            "board_token": board_token,
            "workspace_generation": workspace_generation,
            "findings": findings,
            "per_candidate": per_candidate,
        }
        if isinstance(draft_provenance, list) and draft_provenance:
            result["draft_provenance"] = draft_provenance
        if geometric_indeterminate_:
            # NEVER folded into "no findings": a caller that cannot tell
            # "checked and clean" from "could not check" will read the second
            # as the first, which is the false-clean this whole check exists
            # to prevent.
            result["geometric_indeterminate"] = geometric_indeterminate_
        if error is not None:
            result["error"] = error
        return {"ok": True, "result": result}

    per_candidate: dict = {}
    seg_subjects: list = []  # {candidate_id, segment_id, net, layer, a, b}
    via_subjects: list = []  # {candidate_id, via_id, pos}

    # Committed board copper as SUBJECTS (candidate_id="board") so a
    # candidate-vs-committed collision can name the board side too. Traces on
    # disk are canonical top/bottom {x_mm,y_mm} polylines.
    base_traces: list = []
    base_vias: list = []
    if isinstance(board, dict):
        base_traces = list(board.get("traces")) if isinstance(board.get("traces"), list) else []
        base_vias = list(board.get("vias")) if isinstance(board.get("vias"), list) else []
        for tr in base_traces:
            if not isinstance(tr, dict):
                continue
            net = str(tr.get("net", ""))
            layer = _canonical_drc_layer(tr.get("layer"))
            pts = [(float(p.get("x_mm", 0.0)), float(p.get("y_mm", 0.0)))
                   for p in (tr.get("points") or []) if isinstance(p, dict)]
            for a, b in zip(pts, pts[1:]):
                seg_subjects.append({"candidate_id": "board", "segment_id": "",
                                     "net": net, "layer": layer, "a": a, "b": b})

    new_traces: list = []
    new_vias: list = []
    geometric_candidates: list = []
    candidate_id_counts: dict[str, int] = {}
    for ordinal, cand in enumerate(candidates):
        if isinstance(cand, dict):
            cid = ir_candidates.candidate_id(cand, ordinal)
            candidate_id_counts[cid] = candidate_id_counts.get(cid, 0) + 1
    for ordinal, cand in enumerate(candidates):
        if not isinstance(cand, dict):
            # Keep malformed values in the geometric batch so the neutral owner
            # rejects them fail-closed. They have no identity to expose in the
            # connectivity map.
            geometric_candidates.append(cand)
            continue
        cid = ir_candidates.candidate_id(cand, ordinal)
        net = str(cand.get("net", ""))
        per_candidate.setdefault(cid, "clean")
        had_geometry = False
        raw_segments = cand.get("segments")
        connectivity_segments = raw_segments \
            if isinstance(raw_segments, (list, tuple)) else []
        for seg in connectivity_segments:
            if not isinstance(seg, dict):
                continue
            pts = _dc_points(seg.get("points"))
            if len(pts) < 2:
                continue
            had_geometry = True
            sid = str(seg.get("id", ""))
            layer = _canonical_drc_layer(seg.get("layer"))
            width = float(seg.get("width", 0.25) or 0.25)
            new_traces.append({
                "net": net, "layer": layer, "width_mm": width,
                "points": [{"x_mm": p[0], "y_mm": p[1]} for p in pts],
            })
            for a, b in zip(pts, pts[1:]):
                seg_subjects.append({"candidate_id": cid, "segment_id": sid,
                                     "net": net, "layer": layer, "a": a, "b": b})
        raw_vias = cand.get("vias")
        connectivity_vias = raw_vias \
            if isinstance(raw_vias, (list, tuple)) else []
        for via in connectivity_vias:
            if not isinstance(via, dict):
                continue
            pos = _dc_via_pos(via)
            if pos is None:
                continue
            had_geometry = True
            vid = str(via.get("id", ""))
            new_vias.append({"x_mm": pos[0], "y_mm": pos[1],
                             "from_layer": _canonical_drc_layer(via.get("from_layer", "top")),
                             "to_layer": _canonical_drc_layer(via.get("to_layer", "bottom"))})
            via_subjects.append({"candidate_id": cid, "via_id": vid, "pos": pos})
        if not had_geometry:
            # A candidate with no usable geometry can't be checked → error verdict.
            per_candidate[cid] = "error"
        # Empty candidates have no copper and therefore cannot interact with any
        # sibling. Excluding ONLY this provably-empty shape keeps their own error
        # local; malformed/non-empty copper still reaches the batch and poisons it
        # if the geometric owner cannot model it.
        if (not ir_candidates.candidate_is_provably_empty(cand)
                or candidate_id_counts.get(cid, 0) > 1):
            # Stamp the shared fallback before filtering changes ordinals. If an
            # empty index 0 is omitted, an id-less index 1 must remain
            # "candidate:1" when build_overlay enumerates the reduced list.
            geometric_cand = dict(cand)
            geometric_cand["candidate_id"] = cid
            geometric_candidates.append(geometric_cand)

    # Effective board = committed copper ∪ every candidate's draft copper.
    effective: dict = dict(board) if isinstance(board, dict) else {}
    effective["traces"] = base_traces + new_traces
    effective["vias"] = base_vias + new_vias

    try:
        drc_result = drc.run_drc(effective)
    except Exception as exc:  # geometry faults reported as data, mirrors _drc()
        for cid in per_candidate:
            per_candidate[cid] = "error"
        return _reply([], per_candidate, error=str(exc))

    # THE GEOMETRIC HALF (K9). Compile the composed canonical+staged board, then
    # let the neutral candidate-overlay owner add and attribute candidate copper
    # at the IR level. `effective` above remains connectivity's raw-board union;
    # feeding its hand-built vias to compile_board used to omit net/size fields
    # and made every via-bearing candidate permanently indeterminate.
    geo_findings, geo_per_candidate, geo_indeterminate = _draft_geometric(
        board, geometric_candidates, _layer_params(params))

    # One authoritative per-candidate result. A determinate geometric violation
    # overrides connectivity clean; indeterminate downgrades every otherwise-
    # clean candidate to error in the WORKER reply itself, so no consumer can
    # accidentally expose the connectivity-only clean value.
    if geo_indeterminate:
        for cid in per_candidate:
            if per_candidate[cid] == "clean":
                per_candidate[cid] = "error"
    else:
        for cid, verdict in geo_per_candidate.items():
            if cid in per_candidate and verdict == "violating":
                per_candidate[cid] = "violating"

    eps = _dc_clearance(board)
    findings_out: list = []
    # Geometric findings FIRST and passed through whole. Candidate-introduced
    # findings already carry exact IR-identity subjects from ir_candidates;
    # composed-board baseline findings deliberately carry none.
    for gf in geo_findings:
        if not isinstance(gf, dict):
            continue
        finding = dict(gf)
        # Geometric payloads use `type` for the rule class and may use `kind`
        # for the primitive involved (for example "pth_pad"). This draft-check
        # surface historically defines kind as the rule class, so normalize it
        # explicitly and preserve the richer primitive detail in its own source
        # fields rather than emitting two contradictory class spellings.
        if gf.get("kind") not in (None, gf.get("type")):
            finding["entity_kind"] = gf.get("kind")
        finding["kind"] = gf.get("type")
        finding.setdefault("scope", "geometric")
        findings_out.append(finding)
    for f in drc_result.get("findings", []):
        if not isinstance(f, dict):
            continue
        subjects = _dc_attribute(f, seg_subjects, via_subjects, eps)
        # PASS THE SOURCE FINDING THROUGH, then stamp the reply's own keys on
        # top (Epoch UX3 station 4, K11 — cold review F1). The old hand-picked
        # projection dropped every key it did not know, which silently
        # stripped the geometry the canvas witness overlay draws: a finding
        # with no `closest`/`witness` never renders, so the whole feedback
        # loop was dead against the real pipeline. `kind` (the reply's
        # historical spelling) and `type` (the geometric checks' spelling, and
        # what the canvas reads) are BOTH present so neither consumer breaks.
        finding: dict = dict(f)
        finding["kind"] = f.get("type")
        finding.setdefault("type", f.get("type"))
        finding["subjects"] = subjects
        finding["at"] = f.get("at")
        # K11 witness-geometry contract: every stored finding carries a
        # closest/witness [x, y] pair. Connectivity findings are POINT
        # findings — their evidence is `at` — so both keys collapse to it,
        # exactly as the geometric point classes (gc3 drill) already do.
        # Findings that someday arrive with their own pair keep it.
        at = f.get("at")
        if isinstance(at, (list, tuple)) and len(at) == 2:
            finding.setdefault("closest", list(at))
            finding.setdefault("witness", list(at))
        findings_out.append(finding)
        for s in subjects:
            scid = str(s.get("candidate_id", ""))
            # A definite connectivity violation remains sound even when the
            # complementary geometric pass was indeterminate. Preserve that
            # useful result; fail-closed only forbids an unverified CLEAN.
            # Geometryless error candidates have no subjects and never enter
            # this branch.
            if scid in per_candidate:
                per_candidate[scid] = "violating"

    return _reply(findings_out, per_candidate,
                  geometric_indeterminate_=geo_indeterminate or None)


# ---------------------------------------------------------------------------
# Rendered bless (S3/B2, docket 019ff5687b99) — the library trust boundary.
# ---------------------------------------------------------------------------
#
# Three methods over `pcb_worker.bless`: STAGE a footprint into the WIP layer,
# REPORT it (fact table + SVG), and BLESS it. The gate itself lives in the
# library module (an unblessed entry is absent from the resolving chain's lock
# view); these handlers only carry arguments across the bridge and convert
# refusals into the structured envelope every sibling method already uses.
#
# WHERE "NOW" COMES FROM: `bless.py` never reads the clock, so its records are a
# pure function of their arguments and its tests assert exact bytes. This layer
# is the boundary where wall-clock time enters — `blessed_at`/`retrieved_at` are
# taken from the caller when supplied and defaulted to UTC now when not, so an
# agent-facing tool stays ergonomic without making the library nondeterministic.

_BLESS_SVG_MAX_BYTES = 200_000


def _utc_now_iso() -> str:
    """UTC 'now' as ``YYYY-MM-DDTHH:MM:SSZ``. The ONE clock read on this
    surface (see the section note above)."""
    import datetime
    return (datetime.datetime.now(datetime.timezone.utc)
            .replace(microsecond=0).isoformat().replace("+00:00", "Z"))


def _bless_error(exc: Exception) -> dict:
    """Structured refusal envelope for the bless surface.

    The two exception types are kept DISTINCT rather than collapsed to one
    'error' kind because they mean opposite things to the caller: 'bless' is a
    policy/provenance refusal the caller can fix by supplying better arguments,
    while 'footprint' is a lookup/integrity failure of the library itself."""
    kind = "bless" if isinstance(exc, bless.BlessError) else "footprint"
    return {"ok": False, "error": {"kind": kind, "message": str(exc)}}


def _wip_root(params: dict, *, required: bool):
    """The WIP library root the Go side supplies (``<plugin data dir>/library_wip``).

    REFUSED rather than defaulted when required: the worker has no business
    inventing a data directory — it does not know the host's plugin data dir,
    and guessing one would stage parts into a location nothing else reads."""
    root = (params or {}).get("wip_root")
    if isinstance(root, str) and root.strip():
        return root
    if required:
        raise bless.BlessError(
            "wip_root is required: it names the staging library root "
            "(<plugin data dir>/library_wip) and is supplied by the plugin "
            "host, which is the only party that knows the data directory")
    return None


def _report_summary(report: dict) -> dict:
    """The report WITHOUT its svg body — the shape stage/bless replies carry.

    ``artifact_sha256`` is always present: it is what a bless record pins (and
    what a human-tier bless must quote back as expected_artifact_sha256), so a
    caller can verify the artifact it approved without the tool ever having to
    ship the whole picture back through the bridge."""
    return {"facts": report["facts"], "not_rendered": report["not_rendered"],
            "svg_sha256": report["svg_sha256"],
            "artifact_sha256": report["artifact_sha256"]}


def _footprint_stage(params: dict) -> dict:
    """Stage a .kicad_mod into the WIP library layer, sha-pinned and unblessed.

    params: {ref|name, kicad_mod_text, source_kind, source_ref, license,
             wip_root, retrieved_at?, provenance_note?}
    Reply:  {ok: True, result: {ref, entry, report:{facts, not_rendered,
             svg_sha256}}}

    The staged entry is deliberately born with ``bless: null`` and therefore
    CANNOT supply copper yet (pcb_worker.bless module docstring). A report is
    generated here so the same call that stages a part also proves it renders —
    a part that cannot be rendered can never be blessed, and finding that out at
    staging time is strictly better than at review time.
    """
    params = params or {}
    ref = params.get("ref") or params.get("name")
    try:
        wip_root = _wip_root(params, required=True)
        entry = bless.stage_footprint(
            ref,
            params.get("kicad_mod_text"),
            wip_root,
            source_kind=params.get("source_kind"),
            source_ref=params.get("source_ref"),
            license=params.get("license"),
            retrieved_at=params.get("retrieved_at") or _utc_now_iso(),
            provenance_note=params.get("provenance_note"),
        )
        report = bless.footprint_report(ref, wip_root=wip_root)
    except (bless.BlessError, footprints.FootprintLookupError) as exc:
        return _bless_error(exc)
    return {"ok": True, "result": {"ref": ref, "entry": entry,
                                   "report": _report_summary(report)}}


def _footprint_geometry(params: dict) -> dict:
    """One library ref's fabricable geometry — the ADD-BY-REF seam.

    params: {ref, wip_root?, library_layers?}
    Reply:  {ok: True, result: <pcb_worker.resolve.footprint_geometry(...)>}

    This is what lets a part be added to a live board by library ref with real
    lands and real silk instead of a sketch the compiler will refuse. It
    resolves through the SAME live chain (_layer_params) every compile-bearing
    method uses, so geometry the panel could place is geometry the worker can
    compile — the two cannot disagree about which layer supplied the part.

    Fail-closed and BY NAME: an unresolvable ref raises FootprintLookupError,
    which names the ref and the layers searched. Handing back an empty part
    would put exactly the placeholder this method exists to retire back on the
    board, and the caller would not know.
    """
    params = params or {}
    ref = params.get("ref") or params.get("footprint") or params.get("name")
    if not isinstance(ref, str) or not ref.strip():
        return {"ok": False, "error": {
            "kind": "footprint",
            "message": "ref is required: a library footprint reference "
                       "'LibNick:PartName'"}}
    try:
        result = resolve.footprint_geometry(
            ref.strip(), **_layer_params(params))
    except (bless.BlessError, footprints.FootprintLookupError) as exc:
        return _bless_error(exc)
    return {"ok": True, "result": result}


def _footprint_report(params: dict) -> dict:
    """Fact table + SVG render for one footprint ref — the bless artifacts.

    params: {ref, wip_root?, max_svg_bytes?}
    Reply:  {ok: True, result: {ref, facts, not_rendered, svg, svg_sha256,
             svg_bytes, svg_truncated}}

    ``wip_root`` puts the RAW WIP layer on top of the chain, which is the ONE
    path in this plugin that can see unblessed content — a part nobody can look
    at could never be blessed. ``svg`` may be truncated for transport when it is
    large; ``svg_sha256`` and ``svg_bytes`` always describe the WHOLE artifact,
    and ``svg_truncated`` says so explicitly rather than letting a caller hash
    a fragment and think it matches a bless record.
    """
    params = params or {}
    ref = params.get("ref") or params.get("name")
    try:
        report = bless.footprint_report(
            ref, wip_root=_wip_root(params, required=False))
    except (bless.BlessError, footprints.FootprintLookupError) as exc:
        return _bless_error(exc)
    svg = report["svg"]
    raw = svg.encode("utf-8")
    limit = params.get("max_svg_bytes")
    limit = int(limit) if isinstance(limit, (int, float)) and limit > 0 \
        else _BLESS_SVG_MAX_BYTES
    truncated = len(raw) > limit
    if truncated:
        svg = raw[:limit].decode("utf-8", errors="ignore")
    return {"ok": True, "result": {
        "ref": ref,
        "facts": report["facts"],
        "not_rendered": report["not_rendered"],
        "svg": svg,
        "svg_sha256": report["svg_sha256"],
        "artifact_sha256": report["artifact_sha256"],
        "svg_bytes": len(raw),
        "svg_truncated": truncated,
    }}


def _footprint_bless(params: dict) -> dict:
    """Record a bless verdict against a staged footprint.

    params: {ref, wip_root, verdict?, who?, blessed_at?, expected_artifact_sha256?}
    Reply:  {ok: True, result: {ref, entry, report:{...}}}

    TIER ROUTING, and why it is decided by the ABSENCE of a verdict rather than
    by a mode flag: an ``official_kicad`` entry auto-blesses on provenance, so
    passing a verdict for one is refused (bless_footprint) with a message saying
    exactly that; every other source kind requires an explicit verdict, so
    omitting one is refused (auto_bless_footprint) naming the tier it needs. The
    caller therefore cannot get a bless recorded under the wrong tier by
    guessing at arguments — whichever way it guesses wrong, it is told which.

    A HUMAN verdict additionally requires ``expected_artifact_sha256`` — the
    ``artifact_sha256`` of the report the reviewer actually looked at; a
    mismatch against the current staged content refuses (Codex 1160 P1: an
    approval must not silently transfer to an artifact nobody reviewed).
    """
    params = params or {}
    ref = params.get("ref") or params.get("name")
    verdict = params.get("verdict")
    who = params.get("who")
    blessed_at = params.get("blessed_at") or _utc_now_iso()
    expected = params.get("expected_artifact_sha256")
    try:
        wip_root = _wip_root(params, required=True)
        if verdict is None or (isinstance(verdict, str) and not verdict.strip()):
            entry = bless.auto_bless_footprint(ref, wip_root, blessed_at,
                                               who=who or None)
        else:
            entry = bless.bless_footprint(ref, wip_root, verdict, who,
                                          blessed_at, expected)
        report = bless.footprint_report(ref, wip_root=wip_root)
    except (bless.BlessError, footprints.FootprintLookupError) as exc:
        return _bless_error(exc)
    return {"ok": True, "result": {"ref": ref, "entry": entry,
                                   "report": _report_summary(report)}}


def _footprint_promote(params: dict) -> dict:
    """Move a BLESSED WIP footprint into the durable USER library layer (B7).

    params: {ref, wip_root, dest_root, overwrite?}
    Reply:  {ok: True, result: {ref, layer:"user", path, entry}}

    ``wip_root`` AND ``dest_root`` are both host-supplied (the Go side forces
    them, same write-anywhere argument as staging: the agent chooses the part,
    never the path). Everything that can refuse — unstaged ref, unblessed or
    rejected entry, disk-vs-lock sha drift, a v1 destination lock, an existing
    destination entry without ``overwrite`` — refuses BEFORE any write
    (bless.promote_footprint). After a promote, the ref resolves from the
    ``user`` layer in every live chain and the WIP staging slot is free.
    """
    params = params or {}
    ref = params.get("ref") or params.get("name")
    dest_root = params.get("dest_root")
    overwrite = params.get("overwrite", False)
    try:
        wip_root = _wip_root(params, required=True)
        if not (isinstance(dest_root, str) and dest_root.strip()):
            raise bless.BlessError(
                "dest_root is required: it names the durable user library "
                "root (<plugin data dir>/library_user) and is supplied by "
                "the plugin host, which is the only party that knows the "
                "data directory")
        # The DESTRUCTIVE switch takes a JSON boolean and nothing else (Codex
        # 1173 F2): bool("false") is True in Python, so coercing here would
        # turn the single most common malformed LLM argument into an
        # authorization to replace a durable library part. Only an absent
        # value defaults; every non-boolean is a named pre-write refusal.
        if not isinstance(overwrite, bool):
            raise bless.BlessError(
                f"overwrite must be a JSON boolean (true or false); got "
                f"{overwrite!r}. A string or number is refused rather than "
                f"coerced, because this switch authorizes replacing an "
                f"existing durable library entry. Nothing was written")
        result = bless.promote_footprint(
            ref, wip_root, dest_root, overwrite=overwrite)
    except (bless.BlessError, footprints.FootprintLookupError) as exc:
        return _bless_error(exc)
    return {"ok": True, "result": result}


#: The provenance class the acquisition path stages under. FIXED HERE, never
#: taken from params: this method exists to store bytes the Go side fetched from
#: the pinned OFFICIAL KiCad release, and official_kicad is the one source_kind
#: that auto-blesses. A caller-supplied source_kind would let any text be posted
#: to this method and auto-trusted, which is exactly the hole the tiering table
#: exists to keep shut.
_ACQUIRE_SOURCE_KIND = "official_kicad"


def _footprint_acquire_store(params: dict) -> dict:
    """Store an ACQUIRED official footprint: cross-check, stage, auto-bless.

    params: {ref, kicad_mod_text, source_ref, fetched_sha256, license, wip_root,
             retrieved_at?, provenance_note?, blessed_at?}
    Reply:  {ok: True, result: {ref, layer, sha256, source_ref, license, bless,
             entry, report_summary:{facts, not_rendered, svg_sha256}}}

    ONE method rather than two tool calls (stage then bless) because the pair is
    not independently useful on this path: the Go fetcher has already established
    the only thing the auto tier rests on -- that these bytes came from the
    pinned official release -- so a caller left holding a staged-but-unblessed
    entry between two calls would have nothing to decide and no way to finish if
    the second call never came. Fusing them also means the auto-bless argument
    (``source_kind``) is decided by THIS method, not passed in.

    It reuses the B2 machinery verbatim (``stage_footprint`` parse-validates and
    sha-pins; ``auto_bless_footprint`` regenerates the render and records the
    auto-tier verdict) rather than writing a second staging path -- a second path
    is a second place the bless gate can be forgotten.

    ORDER, and what each step guarantees:

    1. cross-check the fetched sha against the arrived text -- BEFORE any write,
       so a corrupted transfer stages nothing;
    2. stage (which itself validates the text before writing anything);
    3. re-check the sha of the bytes now ON DISK. Step 1 compared wire to
       message; this compares message to file. It is expected to be tautological
       -- and it is cheap, it is the only check that would catch an encoding
       fault in the write path, and its failure mode is safe: the entry exists
       but stays UNBLESSED, so it cannot supply copper;
    4. auto-bless, which is what makes the ref resolvable.
    """
    params = params or {}
    ref = params.get("ref") or params.get("name")
    fetched_sha256 = params.get("fetched_sha256")
    try:
        wip_root = _wip_root(params, required=True)
        bless.cross_check_fetched_sha256(ref, params.get("kicad_mod_text"),
                                         fetched_sha256)
        entry = bless.stage_footprint(
            ref,
            params.get("kicad_mod_text"),
            wip_root,
            source_kind=_ACQUIRE_SOURCE_KIND,
            source_ref=params.get("source_ref"),
            license=params.get("license"),
            retrieved_at=params.get("retrieved_at") or _utc_now_iso(),
            provenance_note=params.get("provenance_note"),
        )
        staged_sha = str(entry.get("sha256") or "").lower()
        if staged_sha != str(fetched_sha256).strip().lower():
            raise bless.BlessError(
                f"{ref}: the staged file's sha256 ({staged_sha}) does not match "
                f"the fetched sha256 ({fetched_sha256}); the entry is left "
                f"UNBLESSED and therefore unresolvable")
        entry = bless.auto_bless_footprint(
            ref, wip_root, params.get("blessed_at") or _utc_now_iso())
        report = bless.footprint_report(ref, wip_root=wip_root)
    except (bless.BlessError, footprints.FootprintLookupError) as exc:
        return _bless_error(exc)
    return {"ok": True, "result": {
        "ref": ref,
        "layer": entry.get("layer"),
        "sha256": entry.get("sha256"),
        "source_ref": entry.get("source_ref"),
        "license": entry.get("license"),
        "bless": entry.get("bless"),
        "entry": entry,
        "report_summary": _report_summary(report),
    }}


def _footprint_import_store(params: dict) -> dict:
    """Store an IMPORTED footprint from an arbitrary source: cross-check, stage.

    params: {ref, kicad_mod_text, source_kind, source_ref, fetched_sha256,
             license, original_filename, wip_root, retrieved_at?,
             provenance_note?, converter_version?}
    Reply:  {ok: True, result: {ref, layer, sha256, source_kind, source_ref,
             license, original_source_path, bless, entry,
             report_summary:{facts, not_rendered, svg_sha256, artifact_sha256}}}

    THE SIBLING OF ``_footprint_acquire_store``, AND ITS OPPOSITE. Both land
    bytes the Go side read, and both cross-check the fetcher's sha256 against
    the text that arrived before writing anything. Where acquisition then
    AUTO-BLESSES on the strength of the pinned official release, this one
    stops: there is no bless call in this method, ``bless`` stays ``None`` on
    the entry, and the ref therefore resolves from no layer until a human runs
    ``footprint_report`` and records a verdict. ``bless: None`` in the reply is
    not an omission -- it is the answer.

    ``source_kind`` comes from the Go importer that ran (git / url /
    vendor_export), and ``bless.import_footprint`` refuses anything outside that
    set independently of the Go check -- so posting ``official_kicad`` straight
    at this method cannot buy an auto-bless, because this method has no way to
    bless at all and the kind is refused besides.

    A report IS generated (same as ``_footprint_stage``): a part that cannot be
    rendered can never be blessed, and learning that at import time beats
    learning it when a reviewer sits down.
    """
    params = params or {}
    ref = params.get("ref") or params.get("name")
    fetched_sha256 = params.get("fetched_sha256")
    try:
        wip_root = _wip_root(params, required=True)
        bless.cross_check_fetched_sha256(ref, params.get("kicad_mod_text"),
                                         fetched_sha256)
        entry = bless.import_footprint(
            ref,
            params.get("kicad_mod_text"),
            wip_root,
            source_kind=params.get("source_kind"),
            source_ref=params.get("source_ref"),
            license=params.get("license"),
            retrieved_at=params.get("retrieved_at") or _utc_now_iso(),
            original_filename=params.get("original_filename"),
            provenance_note=params.get("provenance_note"),
            converter_version=params.get("converter_version"),
        )
        staged_sha = str(entry.get("sha256") or "").lower()
        if staged_sha != str(fetched_sha256).strip().lower():
            raise bless.BlessError(
                f"{ref}: the staged file's sha256 ({staged_sha}) does not match "
                f"the imported sha256 ({fetched_sha256}); the entry is left "
                f"UNBLESSED and therefore unresolvable")
        report = bless.footprint_report(ref, wip_root=wip_root)
    except (bless.BlessError, footprints.FootprintLookupError) as exc:
        return _bless_error(exc)
    return {"ok": True, "result": {
        "ref": ref,
        "layer": entry.get("layer"),
        "sha256": entry.get("sha256"),
        "source_kind": entry.get("source_kind"),
        "source_ref": entry.get("source_ref"),
        "license": entry.get("license"),
        "original_source_path": entry.get("original_source_path"),
        "converter_version": entry.get("converter_version"),
        "bless": entry.get("bless"),
        "entry": entry,
        "report_summary": _report_summary(report),
    }}


def _init() -> dict:
    return {"ok": True, "result": {
        "worker_version": WORKER_VERSION,
        "pyyaml": _pyyaml_version(),
        "circuit_synth": _circuit_synth_version(),
        "circuit_synth_available": _circuit_synth_version() is not None,
        "cold_start_ms": COLD_START_MS,
    }}


def _ping(params: dict) -> dict:
    return {"ok": True, "result": {
        "pong": True,
        "worker_version": WORKER_VERSION,
        "cold_start_ms": COLD_START_MS,
        "echo": (params or {}).get("echo"),
    }}


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

_HANDLERS = {
    "validate": lambda req: _validate(req.get("params") or {}),
    "generate": lambda req: _generate(req.get("params") or {}),
    "gerbers": lambda req: _gerbers(req.get("params") or {}),
    "drc": lambda req: _drc(req.get("params") or {}),
    "drc_geometric": lambda req: _drc_geometric(req.get("params") or {}),
    "resolve": lambda req: _resolve(req.get("params") or {}),
    # Tolerant sibling of "resolve", used by the Go pcb.deserialize board-LOAD
    # path. NOT exposed as an LLM tool: minerva_pcb_resolve stays strict.
    "resolve_best_effort": lambda req: _resolve_best_effort(req.get("params") or {}),
    # Tri-state assembly check (DCR 019fd5fd9084 / 019fd5fddc09) — the
    # standalone surface for board_health.assembly.
    "assembly_check": lambda req: _assembly_check(req.get("params") or {}),
    # Whole-board health without a routing run (Epoch UX2 station 9) — the
    # load path's census+assembly surface.
    "board_health": lambda req: _board_health_method(req.get("params") or {}),
    # Solder-mask overlay for the panel (WYSIWYG G4) — Projection.mask verbatim.
    "mask_view": lambda req: _mask_view(req.get("params") or {}),
    # The compiled copper of every pour — the regions a caller needs to answer
    # what a plane already joins.
    "zone_fill": lambda req: _zone_fill(req.get("params") or {}),
    "fab_preview": lambda req: _fab_preview(req.get("params") or {}),
    "promote_check": lambda req: _promote_check(req.get("params") or {}),
    "normalize": lambda req: _normalize(req.get("params") or {}),
    "lock_libraries": lambda req: _lock_libraries(req.get("params") or {}),
    # Rendered-bless surface (S3/B2) — stage into the WIP layer, render the
    # bless artifacts, record the verdict. See the section above _init().
    "footprint_stage": lambda req: _footprint_stage(req.get("params") or {}),
    "footprint_report": lambda req: _footprint_report(req.get("params") or {}),
    # ONE ref's fabricable geometry, for a part that is not on a board yet —
    # what add-by-library-ref places.
    "footprint_geometry": lambda req: _footprint_geometry(req.get("params") or {}),
    "footprint_bless": lambda req: _footprint_bless(req.get("params") or {}),
    # Promotion (B7) — the bless gate's exit door: a blessed WIP part moves
    # whole (bless record intact) into the durable user layer, where every
    # live chain resolves it without a wip_root.
    "footprint_promote": lambda req: _footprint_promote(req.get("params") or {}),
    # Acquisition (S4/B3) — the Go fetcher's landing point: cross-check the
    # sha the fetcher reported, then stage + auto-bless through the same B2
    # machinery above, in one atomic call. The worker NEVER fetches.
    "footprint_acquire_store": lambda req: _footprint_acquire_store(req.get("params") or {}),
    # Arbitrary-source import (B4) — the same landing shape as acquisition and
    # the opposite trust decision: git/url/vendor_export bytes are staged
    # UNBLESSED, with the original source file preserved beside them. No bless
    # call exists on this path.
    "footprint_import_store": lambda req: _footprint_import_store(req.get("params") or {}),
    "check_libraries": lambda req: _check_libraries(req.get("params") or {}),
    "check_bom": lambda req: _check_bom(req.get("params") or {}),
    "assembly_bom": lambda req: _assembly_bom(req.get("params") or {}),
    "assembly_cpl": lambda req: _assembly_cpl(req.get("params") or {}),
    "route": lambda req: _route(req.get("params") or {}),
    "draft_check": lambda req: _draft_check(req.get("params") or {}),
    "ping": lambda req: _ping(req.get("params") or {}),
}


def handle_request(req: dict) -> dict | None:
    """Dispatch a decoded request dict and return a response dict.

    Returns None only for inbound notifications (no id, non-init/shutdown).
    """
    method: str = req.get("method", "")
    req_id = req.get("id")

    if req_id is None and method not in ("init", "shutdown"):
        return None

    if method == "init":
        result = _init()
        result["id"] = req_id
        return result

    if method == "shutdown":
        return None  # dispatcher handles the clean exit

    handler = _HANDLERS.get(method)
    if handler is not None:
        try:
            result = handler(req)
        except Exception as exc:  # defensive: never crash the loop
            return {"id": req_id, "ok": False, "error": {
                "kind": "python", "message": str(exc), "traceback": traceback.format_exc()}}
        result["id"] = req_id
        return result

    return {"id": req_id, "ok": False, "error": {
        "kind": "internal", "message": f"unknown method: {method!r}"}}

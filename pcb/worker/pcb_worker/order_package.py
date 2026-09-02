"""THE ORDER PACKAGE: every file a house is sent, from one compilation, with a
digest for each and an honest statement of what was and was not established.

ONE ACTION, ONE COMPILATION, SEVEN ARTIFACTS::

    <board>-<profile>/
      gerbers.zip           fabrication files ONLY (see the allowlist below)
      bom.csv               what to buy
      cpl.csv               where to put it
      assembly-preview.svg  what we claimed, drawn, for a person to disagree with
      ORDER-CHECKLIST.md    the order-form choices no uploaded file encodes
      preflight.json        what was checked, advised, and not looked at
      order-manifest.json   the audit record, including a digest per output

The caller compiles the board once and hands the result here; the gerbers, both
CSVs, the placement map and every claim in the manifest are read off that one
``ResolvedBoard``. Two compilations could describe two boards while every gate
inside each still passed.

THE ARCHIVE IS AN ALLOWLIST, NOT A CONVENTION. ``gerbers.zip`` may contain only
Gerber layers, Excellon drill files and the ``.gbrjob`` — the extensions in
:data:`ARCHIVE_ALLOWED_SUFFIXES`. A house's uploader is entitled to reject an
archive carrying anything else, and it is entitled to do it after payment, so
membership is CHECKED rather than assumed: a file the emitter starts producing
one day that does not belong in a fabrication archive refuses the package by
name instead of riding along inside it. Nothing else in the package goes in the
zip — the manifest and the checklist sit beside it, where a person reads them.

READINESS IS THREE SEPARATE CLAIMS, and the package makes only two of them:

1. ``package_generated`` — the files exist and agree with each other. This is
   what serialization proves, and it is ALL that serialization proves.
2. ``preflight_status`` — ``pass``, ``advisories`` or ``blocked``, over the
   checks the selected service actually ran AND the WARNING channel of the one
   compilation and the one emission. A selected manufacturing service refuses
   when its geometric floors are violated. The dialect-only selector may emit
   a mid-layout quote/reference package with ``package_generated=true`` and a
   blocked preflight; its checklist names every blocker and says not to submit
   it for manufacture. ``pass`` never covers the ``unchecked`` list, which is
   always non-empty: it is the statement of what nothing looked at.
3. ``order_page_verified`` — a person uploaded these files and wrote down what
   the quote page said. There is no input to this module that can set it and no
   code path that computes it: it leaves here as ``None``, every time, and the
   only place it can ever be recorded is the checklist a human fills in. An
   export that inferred it would be claiming an answer from a page it never
   loaded.

PROVENANCE IS EVIDENCE OR IT IS LABELLED. The manifest's ``source.git`` block
carries the ``basis`` minted at the load — see :class:`board_model.BoardOrigin`
for what each one takes — and a revision appears under one of them only.

DETERMINISM. Everything except the manifest is byte-identical across runs of the
same input: the archive pins its member order and timestamps, the CSVs and the
Gerbers were already deterministic, the preview is drawn in board order from
fixed-precision coordinates, and the checklist and preflight report carry no
clock. The manifest is the one file that carries the export time, which is
also why it is the one file whose digest it does not record — a file cannot
contain its own hash.
"""

from __future__ import annotations

import hashlib
import importlib
import json
import platform
import re
import subprocess
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path

from . import (assembly_outputs, assembly_preview, board_model, drc_geometric,
               gerber, order_provenance, order_write, resolved_board)
from .board_model import (BASIS_CALLER_ASSERTED, BASIS_INLINE,  # noqa: F401
                          BASIS_WORKER_READ)

#: The package layout, in build order. The checklist and the preflight report
#: are digested by the manifest, so they are produced before it.
GERBER_ARCHIVE = "gerbers.zip"
BOM_FILE = "bom.csv"
CPL_FILE = "cpl.csv"
#: The one artifact NOBODY UPLOADS. It is drawn from the same emission the CPL
#: is written from and exists to be looked at before paying — see
#: :mod:`assembly_preview`.
PREVIEW_FILE = assembly_preview.PREVIEW_FILE
CHECKLIST_FILE = "ORDER-CHECKLIST.md"
PREFLIGHT_FILE = "preflight.json"
MANIFEST_FILE = "order-manifest.json"

#: What may be inside ``gerbers.zip`` — Gerber layers, Excellon drills, and the
#: job file that indexes them. Matched on the file name's suffix because that is
#: what a house's uploader dispatches on.
ARCHIVE_ALLOWED_SUFFIXES = (".gbr", ".drl", ".gbrjob")

#: Fixed member timestamp, so an archive of the same layers is the same bytes.
#: 1980-01-01 is the earliest a ZIP entry can express.
_ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)

MANIFEST_VERSION = 1
PREFLIGHT_VERSION = 1

#: The refusal codes this module raises. Stable names, carried on the exception
#: the same way every other assembly refusal carries one.
CODE_ARCHIVE_CONTENT = "order_package_archive_content"
CODE_ARCHIVE_INCOMPLETE = "order_package_archive_incomplete"
CODE_ARCHIVE_SEMANTICS = "order_package_archive_semantics"
CODE_GEOMETRIC_VIOLATIONS = "order_package_geometric_violations"
CODE_GEOMETRIC_INDETERMINATE = "order_package_geometric_indeterminate"
CODE_JSON_INVALID = "order_package_json_invalid"

#: Rules this package deliberately does not claim to have checked. Same
#: ``{id, reason}`` shape the service profile's own unchecked list uses, so the
#: two merge into one list a reader reads once. They ride in the preflight
#: report so a clean export is never mistaken for a fully verified one.
UNCHECKED_UPLOADER = {
    "id": "gerber_archive_uploader_acceptance",
    "reason": ("whether a house's uploader parses this archive is only settled "
               "by uploading it. This package allowlists members and binds each "
               "Gerber's X2 function/polarity identity to its .gbrjob path, but "
               "nothing here independently re-parses or compares the plotted "
               "geometry — those checks are necessary, not sufficient"),
}
UNCHECKED_LICENCE = {
    "id": "ip_licence_compatibility",
    "reason": ("declared footprint licences are RECORDED in the manifest, not "
               "judged; no compatibility opinion is formed here"),
}

#: What a dialect-only profile says about itself, written once and read by both
#: surfaces that say it — the manifest's ``profile.service_note`` and the
#: checklist's header — so the two cannot drift into claiming different things.
NO_SERVICE_NOTE = (
    "This export claims NO manufacturing tier: the CSV dialect is JLCPCB's, "
    "and nothing was checked against a service's capabilities.")


class OrderPackageError(ValueError):
    """A package refused by name, before any byte reached disk."""

    def __init__(self, code: str, message: str, *, field: str | None = None,
                 geometric: dict | None = None):
        super().__init__(message)
        self.code = code
        self.field = field
        self.geometric = geometric


# ---------------------------------------------------------------------------
# The archive.
# ---------------------------------------------------------------------------


def check_archive_contents(files) -> None:
    """Refuse any member that is not a fabrication file, by name.

    Runs over the names BEFORE the archive is built, so a rejected package
    produces no archive at all rather than one that has to be thrown away."""
    for name in files:
        if not isinstance(name, str) or not name:
            raise OrderPackageError(
                CODE_ARCHIVE_CONTENT,
                f"refusing to put an artifact named {name!r} into {GERBER_ARCHIVE}")
        if "/" in name or "\\" in name:
            raise OrderPackageError(
                CODE_ARCHIVE_CONTENT,
                f"refusing to put {name!r} into {GERBER_ARCHIVE}: an archive "
                f"member is a plain file name, not a path", field=name)
        if not name.endswith(ARCHIVE_ALLOWED_SUFFIXES):
            raise OrderPackageError(
                CODE_ARCHIVE_CONTENT,
                f"{name!r} is not a fabrication file, so it may not go into "
                f"{GERBER_ARCHIVE} — the archive carries "
                f"{'/'.join(ARCHIVE_ALLOWED_SUFFIXES)} only, and a house's "
                f"uploader is entitled to reject an archive that carries "
                f"anything else. Documents belong beside the archive, not in it",
                field=name)


def build_archive(files) -> bytes:
    """The fabrication archive, deterministic and allowlisted.

    Members are sorted, stamped with a fixed date and given fixed permissions,
    so two runs over one board produce the same bytes and therefore the same
    digest."""
    check_archive_contents(files)
    if not files:
        raise OrderPackageError(
            CODE_ARCHIVE_INCOMPLETE,
            f"refusing to emit an empty {GERBER_ARCHIVE}: the board produced no "
            f"fabrication files")
    check_archive_semantics(files)
    buffer = BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(files):
            info = zipfile.ZipInfo(filename=name, date_time=_ZIP_EPOCH)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            info.create_system = 3  # Unix, pinned: the host OS must not show up
            archive.writestr(info, files[name].encode("utf-8"))
    return buffer.getvalue()


_GERBER_FUNCTION = re.compile(r"TF\.FileFunction,([^*]+)\*")
_GERBER_POLARITY = re.compile(r"TF\.FilePolarity,([^*]+)\*")


def _job_function(function: str) -> str:
    """Normalize an in-file X2 function to the job-file vocabulary.

    Gerber X2 and Gerber Job deliberately spell three functions differently;
    the emitter records that distinction in :mod:`gerber`.  Normalizing only
    those measured differences lets the archive bind each layer's own semantic
    declaration to the path the job file assigns it without guessing from
    geometry or from a filename suffix.
    """
    if function.startswith("Copper,") and function.endswith(",Signal"):
        return function[:-len(",Signal")]
    if function.startswith("Paste,"):
        return "SolderPaste," + function[len("Paste,"):]
    if function.startswith("Soldermask,"):
        return "SolderMask," + function[len("Soldermask,"):]
    if function == "Profile,NP":
        return "Profile"
    return function


def check_archive_semantics(files) -> None:
    """Bind every fabrication member's declared role to the job manifest.

    Parsing a Gerber proves syntax, not identity: top-copper bytes remain a
    valid Gerber when renamed as bottom copper.  Every emitted Gerber carries
    its own X2 FileFunction/FilePolarity declarations, and the job file carries
    the declaration expected at each path.  Requiring those independent
    declarations to agree catches layer swaps before an archive is built.

    Excellon has no equivalent job-file row in this emitter, so its PTH/NPTH
    split is bound to the explicit generator comment rather than inferred from
    the hole coordinates.
    """
    jobs = [(name, text) for name, text in files.items()
            if name.endswith(".gbrjob")]
    if len(jobs) != 1:
        raise OrderPackageError(
            CODE_ARCHIVE_SEMANTICS,
            f"{GERBER_ARCHIVE} requires exactly one .gbrjob semantic manifest; "
            f"found {len(jobs)}")
    job_name, job_text = jobs[0]
    try:
        job = json.loads(job_text)
        rows = job["FilesAttributes"]
    except (TypeError, ValueError, KeyError) as exc:
        raise OrderPackageError(
            CODE_ARCHIVE_SEMANTICS,
            f"{job_name!r} does not carry a readable FilesAttributes table: {exc}",
            field=job_name) from exc
    if not isinstance(rows, list):
        raise OrderPackageError(
            CODE_ARCHIVE_SEMANTICS,
            f"{job_name!r} FilesAttributes must be a list", field=job_name)

    by_path: dict[str, dict] = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("Path"), str):
            raise OrderPackageError(
                CODE_ARCHIVE_SEMANTICS,
                f"{job_name!r} carries a malformed FilesAttributes row",
                field=job_name)
        path = row["Path"]
        if path in by_path:
            raise OrderPackageError(
                CODE_ARCHIVE_SEMANTICS,
                f"{job_name!r} assigns {path!r} more than once", field=path)
        by_path[path] = row

    gerber_names = {name for name in files if name.endswith(".gbr")}
    if set(by_path) != gerber_names:
        missing = sorted(gerber_names - set(by_path))
        extra = sorted(set(by_path) - gerber_names)
        raise OrderPackageError(
            CODE_ARCHIVE_SEMANTICS,
            f"{job_name!r} does not describe exactly the emitted Gerbers "
            f"(missing={missing}, extra={extra})", field=job_name)

    for name in sorted(gerber_names):
        text = files[name]
        function = _GERBER_FUNCTION.search(text)
        polarity = _GERBER_POLARITY.search(text)
        if function is None or polarity is None:
            raise OrderPackageError(
                CODE_ARCHIVE_SEMANTICS,
                f"{name!r} lacks its X2 FileFunction/FilePolarity identity",
                field=name)
        row = by_path[name]
        actual = (_job_function(function.group(1)), polarity.group(1))
        expected = (row.get("FileFunction"), row.get("FilePolarity"))
        if actual != expected:
            raise OrderPackageError(
                CODE_ARCHIVE_SEMANTICS,
                f"{name!r} declares function/polarity {actual!r}, but "
                f"{job_name!r} assigns {expected!r}; refusing a renamed or "
                "layer-swapped fabrication member",
                field=name)

    for name, text in sorted(files.items()):
        if not name.endswith(".drl"):
            continue
        marker = ("PLATED THROUGH HOLES" if name.endswith("-PTH.drl")
                  else "NON-PLATED HOLES" if name.endswith("-NPTH.drl")
                  else None)
        if marker is None or marker not in text:
            raise OrderPackageError(
                CODE_ARCHIVE_SEMANTICS,
                f"{name!r} does not declare the drill role its filename claims",
                field=name)


def archive_members(data: bytes) -> tuple[str, ...]:
    """The member names inside a built archive — what the allowlist test reads
    back rather than trusting the input it was handed."""
    with zipfile.ZipFile(BytesIO(data)) as archive:
        return tuple(archive.namelist())


# ---------------------------------------------------------------------------
# Facts about the source and the tools.
# ---------------------------------------------------------------------------


def digest(content) -> str:
    data = content if isinstance(content, bytes) else str(content).encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def _safe_name(value: str) -> str:
    """A directory-name-safe rendering of a board or profile id."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", value or "").strip("-.")
    return cleaned or "board"


def package_directory_name(board_name: str, profile_id: str) -> str:
    return f"{_safe_name(board_name)}-{_safe_name(profile_id)}"


def git_state(origin: board_model.BoardOrigin) -> dict:
    """The revision the board source sits at, or a NAMED reason there is none.

    THE BASIS IS READ OFF ``origin``, never re-derived here. Which standing a
    record has is settled where the board was loaded (:class:`BoardOrigin`); a
    consumer that decided it again from the presence of a path would be a second
    opinion able to disagree with the first.

    A revision is read for exactly one basis. Every other record names its
    reason rather than leaving the field blank, because a blank field reads as
    "clean".
    """
    if origin.basis == BASIS_CALLER_ASSERTED:
        return {"available": False, "basis": BASIS_CALLER_ASSERTED,
                "asserted_path": str(origin.asserted_path),
                "reason": "this path is the caller's claim about where the "
                          "board came from, not the file this tool parsed it "
                          "out of, so no revision was taken from it. Pass the "
                          "board by reference (board_path) naming the same "
                          "file to record a measured revision"}
    if origin.basis != BASIS_WORKER_READ:
        return {"available": False, "basis": BASIS_INLINE,
                "reason": "the board arrived as content rather than as a file "
                          "named as its source (an inline document, or a "
                          "transport snapshot of one), so no repository speaks "
                          "for it"}
    path = Path(origin.path)
    directory = path.parent if path.is_file() else path
    try:
        rev = subprocess.run(
            ["git", "-C", str(directory), "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=10, check=False)
        if rev.returncode != 0:
            return {"available": False, "basis": BASIS_WORKER_READ,
                    "path": str(path),
                    "reason": f"{directory} is not inside a git repository"}
        status = subprocess.run(
            ["git", "-C", str(directory), "status", "--porcelain"],
            capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"available": False, "basis": BASIS_WORKER_READ,
                "path": str(path), "reason": f"git could not be run: {exc}"}
    return {"available": True, "basis": BASIS_WORKER_READ,
            "revision": rev.stdout.strip(),
            "dirty": bool(status.stdout.strip()), "path": str(path)}


def tool_versions() -> dict:
    """Which code wrote these files. Every version is read from the module that
    owns it, so a bumped emitter cannot leave a stale figure here."""
    versions = {"worker": gerber.WORKER_VERSION,
                "python": platform.python_version()}
    for label, module in (("pyyaml", "yaml"), ("gerber_writer", "gerber_writer")):
        try:
            versions[label] = getattr(importlib.import_module(module),
                                      "__version__", "unknown")
        except Exception:
            versions[label] = "unavailable"
    return versions


def _profile_record(profile) -> dict:
    """The selected profile as the manifest records it: what it pinned, not a
    copy of the file."""
    record = {
        "selector": profile.id,
        "display_name": profile.display_name,
        "dialect": profile.renderer_id,
        "identity_required": list(profile.identity_required),
        "house_part_key": profile.house_part_id,
        "max_refs_per_row": profile.max_refs_per_row,
        "min_designator_separation_mm": profile.min_designator_separation_mm,
        "coordinate_unit": profile.coordinate_unit,
        "service": None,
    }
    service = profile.service
    if service is None:
        record["service_note"] = NO_SERVICE_NOTE
        return record
    record["service"] = {
        "id": service.id,
        "version": service.version,
        "fab_profile": service.fab_profile,
        "assembly_sides": list(service.constraints.assembly_sides),
        "templates": [{"artifact": pin.artifact, "url": pin.url,
                       "fetched": pin.fetched, "sha256": pin.sha256,
                       "columns": list(pin.columns)}
                      for pin in service.templates],
        "checked_rules": list(service.checked_rules),
        "advisory_rules": list(service.advisory_rules),
    }
    return record


# ---------------------------------------------------------------------------
# What the board says about the parts.
# ---------------------------------------------------------------------------


def placement_map(board) -> list[dict]:
    """LOGICAL COMPONENT -> PHYSICAL PLACEMENTS, with the transform each one
    resolved to.

    The whole content of "one drawn socket is two soldered strips" lives here,
    and so does the difference between the footprint datum a part is drawn
    against and the anchor the house is told to put its nozzle on. Recorded per
    placement rather than recomputed by a reader, because a second derivation is
    a second chance to disagree."""
    out: list[dict] = []
    for component in board.components:
        assembly = component.assembly
        entry = {
            "component": component.ref,
            "footprint": assembly.footprint_ref if assembly else None,
            "footprint_id": component.footprint_id,
            "populate": bool(assembly.populate) if assembly else None,
            "paste": assembly.paste if assembly else None,
            "placement": {
                "x_mm": component.placement.position[0],
                "y_mm": component.placement.position[1],
                "rotation_deg": component.placement.rotation_deg,
                "side": component.placement.side.value,
            },
            "physical": [{
                "ref": physical.ref,
                "origin": {"x_mm": physical.origin[0], "y_mm": physical.origin[1]},
                "anchor": {"x_mm": physical.anchor[0], "y_mm": physical.anchor[1]},
                "anchor_basis": physical.anchor_basis,
                "rotation_deg": physical.rotation_deg,
                "side": physical.side.value,
                # THE DRAWING THIS PART IS — the placement's own when it named
                # one, else the component's. Stated per placement so a reader
                # never has to know the fallback rule to name the part.
                "footprint": assembly.drawing_for(physical) if assembly else None,
            } for physical in component.physical_placements],
        }
        out.append(entry)
    return out


def not_populated(board) -> list[dict]:
    """Every part the house is deliberately NOT being sent, with its paste
    decision — the thing a reader of two CSVs cannot recover from them."""
    out: list[dict] = []
    for component in board.components:
        assembly = component.assembly
        if assembly is None or assembly.populate:
            continue
        out.append({"component": component.ref,
                    "footprint": assembly.footprint_ref,
                    "paste": assembly.paste,
                    "refs": [p.ref for p in component.physical_placements]})
    return out


def ip_questions(board) -> list[dict]:
    """Licence questions about the footprints whose artwork this package ships.

    A footprint with NO declared licence is a QUESTION: the package is about to
    send its artwork to a manufacturer and cannot say under what terms. Reported
    as ONE finding naming every such footprint rather than one per footprint —
    the answer is a single decision about where the library came from, and a
    list of forty identical lines is a list nobody reads.

    A footprint that DOES declare a licence is a FACT, recorded by
    :func:`licences` and not judged here: whether a declared licence permits
    this use is an owner decision, named in the unchecked list rather than
    guessed at."""
    used = {component.footprint_id for component in board.components}
    undeclared = sorted(
        definition.name for definition in board.footprint_definitions
        if definition.content_id in used
        and not getattr(definition.provenance, "license", None))
    if not undeclared:
        return []
    listed = ", ".join(undeclared[:8])
    if len(undeclared) > 8:
        listed += f" (+{len(undeclared) - 8} more)"
    return [{
        "code": "ip_licence_undeclared",
        "field": "library_lock",
        "footprints": undeclared,
        "message": (
            f"{len(undeclared)} footprint(s) whose artwork is in this package's "
            f"fabrication files declare no licence: {listed}. The board's library "
            f"lock is where a licence is recorded; confirm the terms this "
            f"artwork may be manufactured under before ordering"),
    }]


def licences(board) -> list[dict]:
    """The declared licences of the footprints this package ships, deduplicated
    — the list a person reviews, as facts rather than findings."""
    used = {component.footprint_id for component in board.components}
    seen: dict[tuple, dict] = {}
    for definition in board.footprint_definitions:
        if definition.content_id not in used:
            continue
        provenance = definition.provenance
        licence = getattr(provenance, "license", None) if provenance else None
        if not licence:
            continue
        key = (licence, getattr(provenance, "source_id", None))
        entry = seen.setdefault(key, {"license": licence, "source": key[1],
                                      "footprints": []})
        entry["footprints"].append(definition.name)
    for entry in seen.values():
        entry["footprints"].sort()
    return sorted(seen.values(), key=lambda e: (e["license"], e["source"] or ""))


# ---------------------------------------------------------------------------
# Readiness.
# ---------------------------------------------------------------------------

PREFLIGHT_PASS = "pass"
PREFLIGHT_ADVISORIES = "advisories"
PREFLIGHT_BLOCKED = "blocked"

#: Why the third readiness state is always None here. Kept as one string so the
#: manifest, the preflight report and the checklist say the same thing.
ORDER_PAGE_NOTE = (
    "order_page_verified can only be recorded by a person who uploaded these "
    "files and read the quote page. Nothing in this export sets it: generating "
    "a package proves the files are internally consistent, not that a house "
    "accepts them")


def readiness(*, generated: bool, status: str) -> dict:
    """The three states, as the package reports them.

    ``order_page_verified`` takes no argument and has no branch. It is not that
    the value is defaulted to None — there is nowhere to pass one in."""
    return {"package_generated": generated,
            "preflight_status": status,
            "order_page_verified": None,
            "order_page_verified_note": ORDER_PAGE_NOTE}


def blocked_report(code: str, message: str, *, component=None, field=None,
                   refs=(), geometric=None) -> dict:
    """The preflight a REFUSED export reports. No package exists, so this is the
    whole answer: the third readiness state is still unrecordable and the first
    is honestly false."""
    blocker = {"code": code, "message": message}
    if component:
        blocker["component"] = component
    if field:
        blocker["field"] = field
    if refs:
        blocker["refs"] = list(refs)
    report = {"preflight_version": PREFLIGHT_VERSION,
              "status": PREFLIGHT_BLOCKED,
              "blockers": [blocker],
              "advisories": [],
              "unchecked": [],
              "readiness": readiness(generated=False, status=PREFLIGHT_BLOCKED)}
    if geometric is not None:
        report["geometric"] = geometric
    return report


# ---------------------------------------------------------------------------
# The package.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class OrderPackage:
    """Every artifact, plus the structured facts a caller reports without
    re-parsing a file."""

    directory: str
    files: dict
    digests: dict
    manifest: dict
    preflight: dict
    blockers: tuple
    advisories: tuple
    unchecked: tuple
    ip_questions: tuple
    #: Every WARNING-channel diagnostic this package's one compilation and one
    #: emission produced, serialized. Both channels, because a caller reading
    #: only one would be told less than the manifest records.
    warnings: tuple

    def write(self, out_dir, *, overwrite: bool = False) -> list:
        """Publish the package under ``out_dir`` as ONE visible step."""
        return order_write.publish_directory(out_dir, self.directory, self.files,
                                             overwrite=overwrite)


def _geometric_finding(row: dict, *, blocking: bool = False) -> dict:
    """Adapt a geometric row to the package's named report shape.

    The full machine verdict is preserved under ``preflight.geometric``; this
    projection is the compact row consumed by the GUI/MCP report.  ``layer``
    and ``impact`` stay structured: display salience must not depend on prose.
    """
    code = str(row.get("type") or "geometric_advisory")
    measured = row.get("measured_mm")
    required = row.get("required_mm")
    relation = ""
    if measured is not None and required is not None:
        relation = f" ({measured} mm measured; {required} mm required)"
    component = row.get("ref")
    layer = row.get("layer")
    grade = "blocking finding" if blocking else "advisory"
    message = f"geometric DRC {grade} {code}{relation}"
    if layer:
        message += f" on {layer}"
    out = {"code": code, "message": message, "scope": "geometric",
           "impact": "fabrication"}
    if component:
        out["component"] = component
    if layer:
        out["layer"] = layer
    return out


def build(board_source: dict, board, profile_id: str, *,
          origin: board_model.BoardOrigin | None = None, generated_at=None,
          compile_diagnostics=(), orientation=None) -> OrderPackage:
    """Assemble the whole order package from ONE compiled board.

    ``board_source`` is the raw board dict the compilation came from — the
    digest projection reads it, and nothing else does. ``board`` is the compiled
    ``ResolvedBoard`` every artifact derives from. ``compile_diagnostics`` are
    that compilation's own diagnostics, already serialized; the EMITTER's are
    read here and both end up in one ``warnings`` list, the way the gerbers
    reply merges the two channels.

    ``origin`` is the :class:`board_model.BoardOrigin` the loader minted for
    this request. Omitting it records the inline basis: a builder that was not
    told how the board arrived has been told nothing that could earn a
    revision.

    ``orientation`` is the part-orientation ledger the CPL's rotation
    correction is read from, passed straight through to the emitter; omitting
    it reads the shipped one."""
    provenance, provenance_advisories = order_provenance.check(board_source)
    assembly = assembly_outputs.build_package(board, profile_id,
                                             orientation=orientation)
    profile = assembly.emission.profile

    # A rule profile selected at compile time supplies the geometric floors; it
    # does not itself compare the finished copper against them.  Run the
    # fail-closed geometric kernel over THIS SAME ResolvedBoard before emitting
    # a byte.  Calling compile_board again here would break the package's single-
    # compilation invariant and could check a different library snapshot than
    # the one the files describe.
    geometric = drc_geometric.run_geometric_drc(
        board, warnings=tuple(compile_diagnostics))
    # Python's json.dumps otherwise emits bare NaN/Infinity tokens.  Validate
    # the externally supplied union before copying it into two JSON artifacts;
    # an invalid union is neither a report nor evidence and must fail by name.
    try:
        json.dumps(geometric, allow_nan=False)
    except (TypeError, ValueError) as exc:
        raise OrderPackageError(
            CODE_JSON_INVALID,
            f"geometric DRC returned a value that cannot be represented as "
            f"strict JSON: {exc}", field="geometric") from exc
    verdict = geometric.get("verdict")
    geometric_blockers: tuple[dict, ...] = ()
    if verdict == "violations":
        findings = tuple(geometric.get("findings") or ())
        if profile.service is not None:
            raise OrderPackageError(
                CODE_GEOMETRIC_VIOLATIONS,
                f"geometric DRC reports {len(findings)} fabrication-rule "
                "violation(s); refusing a package that claims a selected "
                "manufacturing service",
                field="design_rules.rule_profile", geometric=geometric)
        # The dialect-only selector deliberately claims no manufacturer.  The
        # owner-approved DCR permits mid-layout quote exports, labelled
        # honestly: files can be internally consistent while preflight is
        # blocked.  Keep every violation named and do not call it an advisory.
        geometric_blockers = tuple(
            _geometric_finding(row, blocking=True) for row in findings)
    if verdict not in ("clean", "violations"):
        kind = (geometric.get("error") or {}).get("kind", "unknown")
        raise OrderPackageError(
            CODE_GEOMETRIC_INDETERMINATE,
            f"geometric DRC is indeterminate ({kind}); refusing to generate "
            "an unverifiable order package",
            field="design_rules.rule_profile", geometric=geometric)

    gerbers = gerber.build_gerbers_ir(board)
    archive = build_archive(gerbers)
    # The emitter's OWN warning channel, read off the value it returned (a copy
    # of a GerberResult is a plain dict and drops it). A silk primitive or drill
    # feature the emitter captured but could not emit is recorded here or
    # nowhere: this package is the account of what the fabrication files hold,
    # and it is the one artifact a reader trusts to be complete.
    emission_warnings = tuple(resolved_board.diagnostic_payload(d)
                              for d in getattr(gerbers, "diagnostics", ()))

    geometric_advisories = tuple(
        _geometric_finding(row) for row in geometric.get("advisories") or ())
    advisories = (tuple(assembly.emission.advisories)
                  + tuple(provenance_advisories)
                  + geometric_advisories)
    unchecked = (tuple(assembly.emission.unchecked)
                 + (UNCHECKED_UPLOADER, UNCHECKED_LICENCE))
    questions = tuple(ip_questions(board))
    warnings = emission_warnings + tuple(compile_diagnostics)
    # WARNINGS MOVE THE STATUS. A WARNING-channel diagnostic is the compiler or
    # the emitter saying something about the board did not survive into these
    # files — a dropped drill, a silk primitive that was captured and not
    # emitted. The artifacts in the envelope are then not a complete rendering
    # of the board, and `pass` over that is the exact claim this package exists
    # to stop making. They are advisory, not blocking: the files are still
    # emitted, and the WARNINGS section of the preflight report says which
    # feature went missing.
    status = (PREFLIGHT_BLOCKED if geometric_blockers else
              PREFLIGHT_ADVISORIES if (advisories or questions or warnings)
              else PREFLIGHT_PASS)

    directory = package_directory_name(board.name, profile.id)
    files: dict = {
        GERBER_ARCHIVE: archive,
        BOM_FILE: assembly.files[assembly.bom_file],
        CPL_FILE: assembly.files[assembly.cpl_file],
        # Rendered from ``assembly.emission`` — the SAME walk cpl.csv is written
        # from, not a second one over the same board. A preview built from its
        # own emission would be a picture of a board that merely looks like the
        # one in the envelope.
        PREVIEW_FILE: assembly_preview.render(board, assembly.emission),
    }
    digests = {name: digest(content) for name, content in files.items()}

    files[CHECKLIST_FILE] = render_checklist(
        board=board, profile=profile, provenance=provenance, digests=digests,
        blockers=geometric_blockers, advisories=advisories,
        unchecked=unchecked, questions=questions, excluded=not_populated(board))
    digests[CHECKLIST_FILE] = digest(files[CHECKLIST_FILE])

    preflight = {
        "preflight_version": PREFLIGHT_VERSION,
        "status": status,
        "board": board.name,
        "profile": profile.id,
        "blockers": [dict(item) for item in geometric_blockers],
        "advisories": [dict(item) for item in advisories],
        "unchecked": [dict(item) for item in unchecked],
        "ip_questions": [dict(item) for item in questions],
        # Carried here as well as in the manifest, because these are half of
        # what moved the status above and a report that states a status it
        # cannot account for sends a reader to the wrong file.
        "warnings": [dict(item) for item in warnings],
        "geometric": geometric,
        "readiness": readiness(generated=True, status=status),
    }
    files[PREFLIGHT_FILE] = _json(preflight)
    digests[PREFLIGHT_FILE] = digest(files[PREFLIGHT_FILE])

    manifest = {
        "manifest_version": MANIFEST_VERSION,
        "generated_at": generated_at or datetime.now(timezone.utc).isoformat(
            timespec="seconds").replace("+00:00", "Z"),
        "package": {"directory": directory,
                    # Every output but this file. A manifest cannot carry its
                    # own digest, so it names what it can prove and says so.
                    "outputs": [{"file": name, "sha256": digests[name],
                                 "bytes": len(_encoded(files[name]))}
                                for name in sorted(digests)],
                    "self": {"file": MANIFEST_FILE,
                             "sha256": None,
                             "note": "a file cannot record its own digest; "
                                     "the order_package reply hashes these "
                                     "finalized bytes, and hashing this file "
                                     "on disk reproduces that value"}},
        "source": {**provenance,
                   "git": git_state(origin or board_model.BoardOrigin(BASIS_INLINE))},
        "board": {"name": board.name, "id": board.id,
                  "fab_rule_profile": board.design_rules.rule_profile.id},
        "profile": _profile_record(profile),
        "tools": tool_versions(),
        "placements": placement_map(board),
        "not_populated": not_populated(board),
        "licences": licences(board),
        "ip_questions": [dict(item) for item in questions],
        "checks": {"status": status,
                   "blockers": [dict(item) for item in geometric_blockers],
                   "advisories": [dict(item) for item in advisories],
                   "unchecked": [dict(item) for item in unchecked],
                   "warnings": [dict(item) for item in warnings],
                   "geometric": geometric},
        "readiness": readiness(generated=True, status=status),
    }
    files[MANIFEST_FILE] = _json(manifest)

    return OrderPackage(directory=directory, files=files, digests=digests,
                        manifest=manifest, preflight=preflight,
                        blockers=geometric_blockers,
                        advisories=advisories, unchecked=unchecked,
                        ip_questions=questions, warnings=warnings)


def _encoded(content) -> bytes:
    return content if isinstance(content, bytes) else str(content).encode("utf-8")


def _json(payload: dict) -> str:
    """One spelling for every JSON artifact: sorted keys, trailing newline."""
    try:
        return json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False,
                          allow_nan=False) + "\n"
    except (TypeError, ValueError) as exc:
        raise OrderPackageError(
            CODE_JSON_INVALID,
            f"order-package record cannot be represented as strict JSON: {exc}",
            field="json") from exc


# ---------------------------------------------------------------------------
# The checklist: what the uploaded files do not encode.
# ---------------------------------------------------------------------------


def render_checklist(*, board, profile, provenance, digests, blockers, advisories,
                     unchecked, questions, excluded) -> str:
    """The human half of the order.

    Gerbers describe copper; they do not describe quantity, finish, colour,
    assembly tier or consent to a house drilling extra holes in the board. Those
    are chosen on a web form, and if nobody writes them down the order is not
    reproducible. The last section is the ONLY place ``order_page_verified`` can
    be recorded, which is why it is a form a person fills in rather than a field
    this code sets."""
    service = profile.service
    lines: list[str] = []
    add = lines.append
    add(f"# Order checklist — {board.name}")
    add("")
    add(f"Profile: **{profile.display_name}** (`{profile.id}`)")
    if service is not None:
        add(f"Fabrication rules: `{service.fab_profile}` · "
            f"assembly side(s): {', '.join(service.constraints.assembly_sides)}")
    else:
        add(NO_SERVICE_NOTE)
    add("")
    add(f"Design revision printed on the board: "
        f"{provenance['design_revision'] or '— none —'} "
        f"({provenance['state']})")
    add(f"Source digest: `{provenance['source_digest']}`")
    if blockers:
        add("")
        add("## BLOCKED — quote/reference package only")
        add("")
        add("This package was generated because the selected dialect claims no "
            "manufacturing service. Do not submit it for manufacture until every "
            "blocking finding below is cleared:")
        add("")
        for item in blockers:
            where = item.get("component") or item.get("layer") or "board-wide"
            add(f"- `{item.get('code', '')}` ({where}): "
                f"{item.get('message', '')}")
    add("")
    add("## Upload these, and only these")
    add("")
    for name in (GERBER_ARCHIVE, BOM_FILE, CPL_FILE):
        add(f"- `{name}` — sha256 `{digests[name]}`")
    add("")
    add(f"`{GERBER_ARCHIVE}` holds fabrication files only "
        f"({'/'.join(ARCHIVE_ALLOWED_SUFFIXES)}). Do not add the manifest, this "
        f"checklist or a README to it.")
    add("")
    add("## Open this before you upload anything")
    add("")
    add(f"- `{PREVIEW_FILE}` — sha256 `{digests[PREVIEW_FILE]}`. Opens in any "
        f"browser. It draws every part's body and lands from the board's own "
        f"geometry and every centroid, rotation and designator from `{CPL_FILE}`, "
        f"in the frame that file is written in. A crosshair that is not on the "
        f"middle of the part it names is a placement this order gets wrong, and "
        f"this is the last point at which that costs nothing.")
    add("")
    add("## Order-form choices these files do not encode")
    add("")
    add("Fill each in as you set it, so the order can be repeated:")
    add("")
    for prompt in ("Quantity", "Base material", "Board thickness",
                   "Outer copper weight", "Surface finish", "Solder-mask colour",
                   "Silkscreen colour", "PCBA tier and side",
                   "Panelization / delivery format",
                   "Serial-number or barcode service (opt-in, changes the artwork)"):
        add(f"- [ ] {prompt}: ______")
    add("- [ ] \"Confirm production file\" selected, so any house modification "
        "is shown before manufacture")
    if service is not None and service.constraints.tooling_holes_added:
        add(f"- [ ] Tooling holes reviewed: {profile.display_name} typically adds "
            f"{service.constraints.tooling_hole_count} non-plated holes of "
            f"{service.constraints.tooling_hole_diameter_mm} mm near the corners "
            f"after upload. That is a physical change to the board these files "
            f"do not describe")
    add("")
    add("## Review before paying")
    add("")
    add("- [ ] Every part in the BOM is the part you meant, and the house "
        "selected it rather than substituting")
    add(f"- [ ] `{PREVIEW_FILE}` and the house's own placement preview agree. "
        f"Ours shows what WE claimed; theirs shows THEIR part turned the way "
        f"THEIR tape holds it — a disagreement between the two is the thing to "
        f"stop for, and rotation zero follows their tape orientation, not ours")
    add("- [ ] Polarity and pin-1 markings on both previews match the design")
    if excluded:
        add(f"- [ ] {len(excluded)} part(s) are deliberately NOT populated and "
            f"are absent from both CSVs: "
            f"{', '.join(item['component'] for item in excluded)}")
    for question in questions:
        add(f"- [ ] IP question: {question['message']}")
    add("")
    add("## What this export did not check")
    add("")
    for item in unchecked:
        rule = item.get("id") or item.get("code") or "unnamed"
        add(f"- `{rule}` — {item.get('reason') or item.get('message') or ''}")
    if advisories:
        add("")
        add("## Advisories")
        add("")
        for item in advisories:
            where = item.get("component") or item.get("field") or ""
            add(f"- `{item.get('code', '')}`{f' ({where})' if where else ''}: "
                f"{item.get('message', '')}")
    add("")
    add("## Quote-page record (a person fills this in)")
    add("")
    add(ORDER_PAGE_NOTE + ".")
    add("")
    for prompt in ("Date uploaded", "Layers / dimensions / drills the site read",
                   "BOM recognized (rows matched / parts found)",
                   "CPL recognized (rows matched)",
                   "Parts the house could not supply",
                   "Placement-preview verdict",
                   "Tooling-hole or production-file changes the house proposed",
                   "Order number"):
        add(f"- {prompt}: ______")
    add("")
    return "\n".join(lines) + "\n"

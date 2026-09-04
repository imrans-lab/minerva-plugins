#!/usr/bin/env python3
"""Generate cad/NOTICE.md — the licence/attribution inventory for everything
third-party that ships inside the cad plugin's embedded Python runtime bundle.

WHAT THIS INVENTORIES AND WHY IT IS NOT AUTOMATIC
--------------------------------------------------
The bundle is built by ``scripts/build-python-runtime-bundle.sh`` from the pins
in ``cad/scripts/runtime-bundle.lock``. A pin names a PyPI distribution; what
lands in the tarball is that distribution's wheel, and a wheel routinely
carries compiled copies of other projects (``python-fcl``'s wheel contains
FCL, libccd, OctoMap and Eigen — but ships only python-fcl's own LICENSE).
Nothing in the pin, the wheel metadata or the dist-info can tell us about those
four, so :data:`RUNTIME_COMPONENTS` is maintained BY HAND, from the wheel
contents and the upstream build recipe, and this script is what stops the hand
list and the lock from drifting apart.

The licence texts themselves live in ``cad/licenses/runtime/`` and are copied
into the bundle and the release tarball, because binary redistribution under
BSD/MIT requires the notice, the conditions and the disclaimer to travel "in
the documentation and/or other materials provided with the distribution" — a
NOTICE that only names a licence does not satisfy that.

GATE SEMANTICS (fail-closed)
-----------------------------
Generation REFUSES, naming every violation at once, when:

* a lock pin (``PIP_PKGS`` / ``PIP_NO_DEPS_PKGS``) has neither an inventory
  entry nor a :data:`PENDING_INVENTORY` declaration — so adding a dependency
  without inventorying it fails here rather than shipping unattributed;
* an inventory entry is missing any field, or names a licence text file that
  does not exist or is empty — the load-bearing case: deleting a licence text
  must fail the build, not silently ship a NOTICE pointing at nothing;
* a licence text file exists in ``cad/licenses/runtime/`` that no entry
  references (the other direction: a stale text left behind by a removed
  dependency claims an attribution we no longer make);
* an entry's licence is outside :data:`PERMISSIVE_LICENCES` — GPL or LGPL
  anywhere in the tree is a stop, and an unrecognised licence is refused
  rather than guessed at;
* an ``MPL-2.0`` entry carries no ``source_url``: MPL §3.2(a) obliges us to
  tell recipients where the covered source is, so an MPL entry without that
  URL renders a NOTICE that does not discharge the obligation.

MODES
-----
``python3 cad/scripts/gen_notice.py``
    Writes ``cad/NOTICE.md``. Paths resolve relative to this script, never the
    caller's cwd.

``python3 cad/scripts/gen_notice.py --check``
    Writes nothing; exits 1 on a gate violation or on any drift between the
    committed ``cad/NOTICE.md`` and a fresh generation. This is what CI runs.

The output is a pure function of the lock file, the inventory and the licence
files' existence — nothing here reads the clock or the environment, so two runs
over an unchanged tree are byte-identical.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path
from typing import NamedTuple, Optional, Union

# cad/scripts/this.py -> cad/
CAD = Path(__file__).resolve().parents[1]

DEFAULT_LOCK_PATH = CAD / "scripts" / "runtime-bundle.lock"
DEFAULT_NOTICE_PATH = CAD / "NOTICE.md"
#: The whole directory that ships (into the bundle and beside the binary).
#: Everything under it is inventoried — see DECLARED_SUPPORT_FILES.
LICENCE_ROOT = CAD / "licenses"
LICENCE_DIR = LICENCE_ROOT / "runtime"
REGEN_COMMAND = "python3 cad/scripts/gen_notice.py"

#: Licences we are willing to ship inside a binary distribution. MPL-2.0 is
#: file-level copyleft and is allowed only because the covered files are
#: unmodified headers compiled into someone else's library (see the Eigen
#: entry); it drags in the extra source-availability obligation the gate
#: enforces below. Anything not listed here — GPL and LGPL above all — is a
#: refusal, not a warning.
PERMISSIVE_LICENCES = frozenset({
    "BSD-2-Clause",
    "BSD-3-Clause",
    "MIT",
    "Apache-2.0",
    "MPL-2.0",
    "LicenseRef-Microsoft-VC-Redistributable",
})


#: Files under ``cad/licenses/`` that are NOT a component's licence text but
#: still ship with the distribution, declared so the tree check below can
#: demand them by name.
#:
#: With only the licence texts declared, moving ``cad/licenses/README.md``
#: away leaves the gate reporting "up to date". The inventory — not a
#: directory listing — decides what must be present, so anything the directory
#: ships has to be named somewhere.
DECLARED_SUPPORT_FILES = {
    "README.md": "explains what the directory is, how it reaches the "
                 "distribution, and what to do when adding a dependency",
}


class RuntimeComponent(NamedTuple):
    """One third-party component that ships inside the runtime bundle.

    ``distribution`` is the PyPI pin it arrives through (the join back to the
    lock file), or ``None`` for something that enters the bundle by another
    route — the C++ runtime DLLs the Windows wheel repair copies in are not a
    PyPI package at all. ``component`` is what the thing actually is:
    python-fcl's wheel yields five entries sharing one distribution.

    ``license_files`` are names inside ``cad/licenses/runtime/``. More than one
    is normal (Eigen's MPL2 text plus the upstream COPYING.README that records
    which of its files are under which licence).
    """

    distribution: Optional[str]
    component: str
    version: str
    license: str
    copyright: str
    source_url: str
    license_files: tuple
    note: str


#: Every third-party component inside the bundle, in render order.
#:
#: The four components under the ``python-fcl`` distribution are what its wheel
#: vendors, verified by unzipping the wheels for all four release targets: the
#: linux wheel carries ``python_fcl.libs/`` (libfcl, libccd, liboctomap,
#: liboctomath), the macOS wheels carry the same set under ``fcl/.dylibs/``,
#: and the Windows wheel links FCL into the .pyd and ships ccd.dll, octomap.dll
#: and octomath.dll beside it. Eigen is header-only and leaves no file behind —
#: it is compiled INTO libfcl, which is exactly why a file-based inventory
#: cannot find it and this list is maintained by hand.
RUNTIME_COMPONENTS: tuple = (
    RuntimeComponent(
        distribution="python-fcl",
        component="python-fcl",
        version="0.7.0.11",
        license="BSD-3-Clause",
        copyright="Copyright (c) 2017, Matthew Matl",
        source_url="https://github.com/BerkeleyAutomation/python-fcl",
        license_files=("python-fcl-0.7.0.11.LICENSE.txt",),
        note="Cython bindings to FCL. The only licence the wheel itself "
             "ships; the four components below are compiled into it.",
    ),
    RuntimeComponent(
        distribution="python-fcl",
        component="FCL (Flexible Collision Library)",
        version="0.7.0",
        license="BSD-3-Clause",
        copyright="Copyright (c) 2008-2014, Willow Garage, Inc.; "
                  "Copyright (c) 2014-2016, Open Source Robotics Foundation",
        source_url="https://github.com/flexible-collision-library/fcl/tree/0.7.0",
        license_files=("fcl-0.7.0.LICENSE.txt",),
        note="Built by python-fcl from the ambi-robotics/fcl fork pinned at "
             "FCL 0.7.0. Ships as libfcl (linux/macOS) or linked into "
             "fcl.cp312-win_amd64.pyd (Windows).",
    ),
    RuntimeComponent(
        distribution="python-fcl",
        component="libccd",
        version="2.1",
        license="BSD-3-Clause",
        copyright="Copyright (c) 2010-2012 Daniel Fiser <danfis@danfis.cz>, "
                  "Intelligent and Mobile Robotics Group, Czech Technical "
                  "University in Prague",
        source_url="https://github.com/danfis/libccd/tree/v2.1",
        license_files=("libccd-2.1.BSD-LICENSE.txt",),
        note="FCL's convex-collision backend. Ships as libccd / ccd.dll.",
    ),
    RuntimeComponent(
        distribution="python-fcl",
        component="OctoMap (octomap + octomath)",
        version="1.9.8",
        license="BSD-3-Clause",
        copyright="Copyright (c) 2009-2013, K.M. Wurm and A. Hornung, "
                  "University of Freiburg",
        source_url="https://github.com/OctoMap/octomap/tree/v1.9.8",
        license_files=("octomap-1.9.8.LICENSE.txt",),
        note="FCL's octree collision geometry. Only the New-BSD octomap and "
             "octomath libraries are in the wheel — octovis, the GPL viewer "
             "in the same upstream repository, is not.",
    ),
    RuntimeComponent(
        distribution="python-fcl",
        component="Eigen",
        version="3.3.9",
        license="MPL-2.0",
        copyright="Copyright (c) the Eigen authors "
                  "(see the upstream source for per-file notices)",
        source_url="https://gitlab.com/libeigen/eigen/-/archive/3.3.9/eigen-3.3.9.tar.gz",
        license_files=("eigen-3.3.9.COPYING.MPL2.txt",
                       "eigen-3.3.9.COPYING.README.txt"),
        note="Header-only, compiled unmodified into libfcl, so no Eigen file "
             "appears in the bundle. FCL 0.7.0 includes only <Eigen/Core>, "
             "<Eigen/Dense> and <Eigen/StdVector>; Eigen's two LGPL-2.1 files "
             "(IterativeLinearSolvers/IncompleteLUT.h, "
             "SparseCholesky/SimplicialCholesky_impl.h) are sparse-solver "
             "headers FCL never includes, so no LGPL code is compiled in. "
             "Re-check this on any Eigen or FCL version bump.",
    ),
    RuntimeComponent(
        distribution=None,
        component="Microsoft Visual C++ runtime (MSVCP140.dll and the "
                  "VCRUNTIME140 pair)",
        version="Visual Studio 2022 redistributable",
        license="LicenseRef-Microsoft-VC-Redistributable",
        copyright="Copyright (c) Microsoft Corporation",
        source_url="https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution",
        license_files=("microsoft-vc-runtime.ATTRIBUTION.txt",),
        note="Windows bundle only. The python-fcl extension imports "
             "MSVCP140.dll, which python-build-standalone does not ship, so "
             "the Windows build repairs the wheel with delvewheel and the DLL "
             "travels inside the bundle instead of being resolved from the "
             "user's machine. Nothing is checked into this repository.",
    ),
)

#: Lock pins whose licence tree has NOT been inventoried yet, each mapped to
#: the reason. They render in the NOTICE as an explicit gap.
#:
#: A pending entry is a claim a reader can check; silence is not. These two
#: predate the inventory and carry large trees of their own (OCCT above all),
#: and this list is what keeps that gap visible instead of letting a green
#: gate imply the inventory is complete.
PENDING_INVENTORY = {
    "build123d": "pre-existing pin; its own licence and its transitive tree "
                 "(cadquery-ocp, OCCT, and the IPython/jedi chain) are not "
                 "yet inventoried.",
    "cadquery-ocp": "pulled in transitively by build123d and repeated here "
                    "only if pinned directly; OCCT's licence tree is not yet "
                    "inventoried.",
}


class NoticeGateError(Exception):
    """Raised when the inventory or the lock fails the gate (fail-closed).

    The message names EVERY violation, never just the first: a release
    engineer fixing one and re-running should not discover the second only on
    the next attempt.
    """


# ---------------------------------------------------------------------------
# lock file
# ---------------------------------------------------------------------------

_LOCK_ASSIGNMENT = re.compile(r'^\s*([A-Z0-9_]+)="([^"]*)"\s*$')


def read_lock_vars(lock_path: Union[str, Path]) -> dict:
    """Parse the shell-sourceable runtime-bundle lock into a dict.

    Deliberately NOT ``bash -c 'source ...'``: this runs in CI over a file that
    a branch can change, and sourcing it would execute whatever it contains.
    The build and probe scripts do source it — they are the build's own shell,
    reading the lock they were invoked with — and this is the one reader that
    is not. The lock's format is one ``KEY="value"`` per line (comments and
    blanks ignored), and a line that does not match that shape is simply not a
    pin — the build script would not get a usable value out of it either.
    """
    values: dict = {}
    text = Path(lock_path).read_text(encoding="utf-8")
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = _LOCK_ASSIGNMENT.match(line)
        if m:
            values[m.group(1)] = m.group(2)
    return values


def lock_pins(lock_vars: dict) -> list:
    """Every pinned distribution name in the lock, sorted, de-duplicated.

    Both install lists count: ``PIP_NO_DEPS_PKGS`` is not a lesser pin, it is
    the same wheel installed without its declared dependencies, and it ships
    exactly the same bytes.
    """
    specs = f"{lock_vars.get('PIP_PKGS', '')} {lock_vars.get('PIP_NO_DEPS_PKGS', '')}"
    names = set()
    for spec in specs.split():
        names.add(re.split(r"[<>=!~\[]", spec, 1)[0].strip())
    names.discard("")
    return sorted(names)


# ---------------------------------------------------------------------------
# gate
# ---------------------------------------------------------------------------


def _component_violations(components: tuple, licence_dir: Path) -> list:
    violations: list = []
    for comp in components:
        who = comp.component or "<unnamed component>"
        for field in ("component", "version", "license", "copyright",
                      "source_url", "note"):
            if not getattr(comp, field, None):
                violations.append(f"{who}: missing/empty {field}")
        if not comp.license_files:
            violations.append(f"{who}: declares no licence text file")
        if comp.license and comp.license not in PERMISSIVE_LICENCES:
            violations.append(
                f"{who}: licence {comp.license!r} is not in PERMISSIVE_LICENCES "
                f"({sorted(PERMISSIVE_LICENCES)}) — copyleft is a stop, and an "
                f"unrecognised licence is refused rather than guessed")
        if comp.license == "MPL-2.0" and not comp.source_url:
            violations.append(
                f"{who}: MPL-2.0 requires a source_url (MPL 2.0 §3.2(a): "
                f"recipients must be told where the covered source is)")
        for name in comp.license_files:
            path = licence_dir / name
            if Path(name).name != name:
                violations.append(
                    f"{who}: licence file {name!r} must be a bare filename "
                    f"inside {licence_dir}")
                continue
            if not path.is_file():
                violations.append(
                    f"{who}: licence text {name} is missing from {licence_dir} "
                    f"— the binary distribution must carry the full text")
            elif not path.read_text(encoding="utf-8", errors="replace").strip():
                violations.append(f"{who}: licence text {name} is empty")
    return violations


def _sha256(path: Path) -> str:
    """Content hash of a shipped file, recorded in the NOTICE.

    The hash is what turns "the file is present" into "the file still says
    what it said when this NOTICE was generated" — a text truncated, emptied
    of its disclaimer, or replaced with a different project's licence passes
    an existence check and fails this one.
    """
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _tree_violations(components: tuple, licence_dir: Path,
                     licence_root: Path) -> list:
    """Every disagreement between the declared inventory and what is on disk.

    BOTH directions, over the WHOLE shipped directory rather than the licence
    subdirectory alone:

    * a declared support file that is missing — the case that exposed this
      function: with only ``runtime/`` walked, removing ``licenses/README.md``
      changed nothing the gate could see;
    * a file on disk that nothing declares — a stale text left by a removed
      dependency is an attribution this project no longer makes, and it would
      keep shipping.

    Component licence texts are checked for existence in
    :func:`_component_violations`; here they only make up the declared set.
    """
    violations: list = []
    if not licence_dir.is_dir():
        violations.append(f"licence directory {licence_dir} does not exist")
    if not licence_root.is_dir():
        return violations + [f"licence directory {licence_root} does not exist"]

    declared = {f"runtime/{name}"
                for comp in components for name in comp.license_files}
    declared |= set(DECLARED_SUPPORT_FILES)

    for name in sorted(DECLARED_SUPPORT_FILES):
        path = licence_root / name
        if not path.is_file():
            violations.append(
                f"{name}: declared file is missing from {licence_root} — it "
                f"ships with the distribution, so the inventory demands it")
        elif not path.read_text(encoding="utf-8", errors="replace").strip():
            violations.append(f"{name}: declared file is empty")

    on_disk = {str(p.relative_to(licence_root)).replace("\\", "/")
               for p in licence_root.rglob("*") if p.is_file()}
    for name in sorted(on_disk - declared):
        violations.append(
            f"{name}: file in {licence_root} that the inventory does not "
            f"declare (a component licence text, or DECLARED_SUPPORT_FILES)")
    return violations


def _pin_violations(pins: list, components: tuple) -> list:
    inventoried = {c.distribution for c in components if c.distribution}
    return [
        f"{pin}: lock pin with no RUNTIME_COMPONENTS entry and no "
        f"PENDING_INVENTORY declaration — a new dependency must be "
        f"inventoried (or explicitly declared pending) before it ships"
        for pin in pins
        if pin not in inventoried and pin not in PENDING_INVENTORY
    ]


# ---------------------------------------------------------------------------
# render
# ---------------------------------------------------------------------------


def render_notice(lock_vars: dict,
                  components: tuple = RUNTIME_COMPONENTS,
                  licence_dir: Path = LICENCE_DIR,
                  licence_root: Union[Path, None] = None) -> str:
    """Render the NOTICE body, or raise :class:`NoticeGateError`.

    The gate runs before any output is built, so a refused run never
    half-renders a NOTICE around the components that did pass.
    """
    # The root defaults to the licence directory's parent so a test (or a
    # future second licence subdirectory) can point the whole check at a copy.
    licence_root = licence_root if licence_root is not None else licence_dir.parent
    pins = lock_pins(lock_vars)
    violations = (_pin_violations(pins, components)
                  + _component_violations(components, licence_dir)
                  + _tree_violations(components, licence_dir, licence_root))
    if violations:
        raise NoticeGateError(
            "the cad runtime NOTICE gate refuses (fail-closed) — every "
            "violation:\n  " + "\n  ".join(violations))

    lines = [
        "# NOTICE — cad runtime bundle",
        "",
        "**This file is GENERATED. Do not hand-edit it.**",
        "",
        "Regenerate with:",
        "",
        f"    {REGEN_COMMAND}",
        "",
        "Licence and attribution inventory for the third-party content that "
        "ships inside the cad plugin's embedded Python runtime bundle, whose "
        "pins live in `cad/scripts/runtime-bundle.lock`. The full text of "
        "every licence below is in `cad/licenses/runtime/`, which is copied "
        "into the bundle (as `licenses/`) and into the release tarball beside "
        "the plugin binary — BSD and MIT terms require the notice, conditions "
        "and disclaimer to be provided with a binary distribution, so naming "
        "the licence here is not on its own enough.",
        "",
        "A wheel's own metadata cannot see what it vendors: python-fcl's "
        "wheel contains compiled FCL, libccd, OctoMap and Eigen while "
        "shipping only python-fcl's LICENSE. The inventory below is therefore "
        "maintained by hand in `cad/scripts/gen_notice.py`, and its `--check` "
        "mode is the gate that keeps it honest against the lock.",
        "",
        f"Runtime pins in the lock: {', '.join(pins) if pins else '(none)'}",
        "",
        "HOW COMPLETE THIS IS. The inventory is complete for the python-fcl "
        "tree — python-fcl itself and the four components compiled into its "
        "wheel (FCL, libccd, OctoMap, Eigen) — plus the Microsoft C++ runtime "
        "the Windows build vendors. It is NOT complete for the whole bundle: "
        + (", ".join(f"`{name}`" for name in sorted(PENDING_INVENTORY))
           + " and their transitive trees (OCCT above all) are listed under "
             "\"Not yet inventoried\" below and have not been inventoried."
           if PENDING_INVENTORY else
           "every lock pin is inventoried below.")
        + " The `--check` gate passes with those named as pending, so a green "
          "gate means \"nothing has drifted and nothing new arrived "
          "unannounced\", not \"every licence in the bundle has been "
          "reviewed\".",
        "",
    ]

    for comp in components:
        lines.append(f"## {comp.component} {comp.version}")
        lines.append("")
        lines.append(f"- Licence: {comp.license}")
        lines.append(f"- {comp.copyright}")
        lines.append(f"- Source: {comp.source_url}")
        origin = (f"`{comp.distribution}` wheel" if comp.distribution
                  else "not a PyPI distribution")
        lines.append(f"- Arrives via: {origin}")
        for name in comp.license_files:
            # The hash makes the NOTICE a record of WHICH bytes were
            # attributed, not just which filenames existed.
            digest = _sha256(licence_dir / name)
            lines.append(f"- Licence text: `cad/licenses/runtime/{name}` "
                         f"(sha256 {digest})")
        lines.append("")
        lines.append(comp.note)
        lines.append("")

    lines.append("## Shipped alongside the licence texts")
    lines.append("")
    lines.append(
        "Files under `cad/licenses/` that are not a component's licence text "
        "but travel with the distribution. Declared in "
        "`DECLARED_SUPPORT_FILES`, so the gate demands them by name.")
    lines.append("")
    for name in sorted(DECLARED_SUPPORT_FILES):
        digest = _sha256(licence_root / name)
        lines.append(f"- `cad/licenses/{name}` (sha256 {digest}) — "
                     f"{DECLARED_SUPPORT_FILES[name]}")
    lines.append("")

    lines.append("## Not yet inventoried")
    lines.append("")
    lines.append(
        "Lock pins whose licence trees this inventory does not yet cover. "
        "They are listed rather than omitted so the gap is visible; the gate "
        "refuses any OTHER pin that is neither inventoried nor listed here.")
    lines.append("")
    if PENDING_INVENTORY:
        for name in sorted(PENDING_INVENTORY):
            lines.append(f"- `{name}` — {PENDING_INVENTORY[name]}")
    else:
        lines.append("**None.** Every lock pin is inventoried above.")
    lines.append("")
    lines.append(f"Total: {len(components)} inventoried components, "
                 f"{len(PENDING_INVENTORY)} pending.")
    lines.append("")
    return "\n".join(lines)


_HASH_LINE = re.compile(r"`(cad/licenses/[^`]+)` \(sha256 ([0-9a-f]{64})\)")


def hashed_files(notice_body: str) -> dict:
    """The {path: sha256} pairs a NOTICE body records."""
    return {path: digest for path, digest in _HASH_LINE.findall(notice_body)}


def hash_differences(committed: str, fresh: str) -> list:
    """Human-readable differences between two NOTICEs' recorded hashes.

    Drift between the committed NOTICE and a fresh generation already fails
    the check; this turns "something differs" into "THIS file's bytes are not
    the bytes that were attributed", which is the difference between a message
    a release engineer can act on and one they have to investigate.
    """
    before, after = hashed_files(committed), hashed_files(fresh)
    messages: list = []
    for path in sorted(set(before) | set(after)):
        if path not in after:
            messages.append(f"{path}: recorded in the committed NOTICE but no "
                            f"longer inventoried")
        elif path not in before:
            messages.append(f"{path}: newly inventoried, not in the committed "
                            f"NOTICE")
        elif before[path] != after[path]:
            messages.append(f"{path}: CONTENT CHANGED — attributed "
                            f"sha256 {before[path]}, on disk {after[path]}")
    return messages


def generate(lock_path: Union[str, Path, None] = None) -> str:
    """Read the lock and render its NOTICE body — the one function both the
    CLI and the tests call, so neither can read the lock a different way."""
    return render_notice(read_lock_vars(lock_path or DEFAULT_LOCK_PATH))


def main(argv: Union[list, None] = None) -> int:
    ap = argparse.ArgumentParser(description="cad runtime NOTICE generator")
    ap.add_argument("--check", action="store_true",
                    help="Write nothing; exit 1 on a gate violation or on "
                         "drift between the committed NOTICE.md and a fresh "
                         "generation.")
    ap.add_argument("--lock", default=None,
                    help="Override the lock path (default: "
                         "cad/scripts/runtime-bundle.lock).")
    ap.add_argument("--out", default=None,
                    help="Override the output path (default: cad/NOTICE.md).")
    args = ap.parse_args(argv)

    lock_path = Path(args.lock) if args.lock else DEFAULT_LOCK_PATH
    out_path = Path(args.out) if args.out else DEFAULT_NOTICE_PATH

    try:
        body = generate(lock_path)
    except NoticeGateError as exc:
        print(f"gen_notice: GATE REFUSED\n{exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # lock missing/unreadable
        print(f"gen_notice: cannot read lock {lock_path}: {exc}",
              file=sys.stderr)
        return 1

    if args.check:
        if not out_path.is_file():
            print(f"gen_notice --check: {out_path} does not exist; run "
                  f"`{REGEN_COMMAND}`", file=sys.stderr)
            return 1
        committed = out_path.read_text(encoding="utf-8")
        if committed != body:
            print(f"gen_notice --check: {out_path} is stale (drift detected); "
                  f"regenerate with `{REGEN_COMMAND}` and commit the result",
                  file=sys.stderr)
            for message in hash_differences(committed, body):
                print(f"  {message}", file=sys.stderr)
            return 1
        print(f"gen_notice --check: {out_path} is up to date "
              f"({len(RUNTIME_COMPONENTS)} components).")
        return 0

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)
    print(f"gen_notice: wrote {out_path} "
          f"({len(RUNTIME_COMPONENTS)} components).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

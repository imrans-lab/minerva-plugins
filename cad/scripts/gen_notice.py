#!/usr/bin/env python3
"""Generate cad/NOTICE.md — the licence/attribution inventory for everything
third-party that ships inside the cad plugin's embedded Python runtime bundle.

THE THREE INPUTS AND WHY THERE ARE THREE
-----------------------------------------
``cad/scripts/runtime-bundle.lock``
    What the build is TOLD to install (``build123d``, ``python-fcl``).

``cad/scripts/runtime-bundle.manifest``
    What actually LANDS in the built bundle's site-packages — the census. pip
    resolves the transitive tree, so the lock names two distributions and the
    bundle contains forty-seven. Generating the inventory from the lock would
    attribute two of them.

``cad/scripts/notice_inventory.py``
    One entry per thing that ships, with its licence text. A wheel vendors
    projects its metadata never mentions (python-fcl's contains FCL, libccd,
    OctoMap and Eigen; cadquery-ocp's contains the whole of OCCT and ships no
    licence text at all), so this is maintained by hand and this script is
    what stops it and the bundle from drifting apart.

WHY THE CENSUS IS A COMMITTED FILE RATHER THAN A LIVE READ
-----------------------------------------------------------
The NOTICE gate runs in CI on a runner that builds no bundle — that is what
makes it a cheap, platform-independent, always-run gate rather than something
that only happens on a release leg. So the gate reads the committed census,
and the build legs, which DO have a bundle, run ``--verify-bundle`` against
the real site-packages. Drift therefore surfaces on the build leg (a
transitive dependency appeared, disappeared or changed version) and is fixed
by re-running ``--census`` and inventorying whatever is new.

The census is produced by reading ``*.dist-info/METADATA`` out of one
directory, NOT by running ``pip list`` inside the staged interpreter: that
interpreter's sys.path picks up the developer's ``~/.local`` site-packages, so
pip reports distributions the bundle does not contain and the developer's
version where both are installed.

GATE SEMANTICS (fail-closed)
-----------------------------
Generation REFUSES, naming every violation at once, when:

* a census distribution has neither an inventory entry nor a
  ``DISTRIBUTION_EXCLUSIONS`` reason — the load-bearing rule: a wheel that
  reaches site-packages without being attributed fails here rather than
  shipping;
* an inventory entry names a distribution the census does not contain, or
  gives a version the census disagrees with — a stale entry attributes
  something that no longer ships, or the wrong version of what does;
* an exclusion names a distribution that is not in the census;
* a lock pin is missing from the census — the census would then be describing
  a different bundle from the one the build produces;
* an inventory entry is missing any field, or names a licence text file that
  does not exist or is empty — deleting a licence text must fail the build,
  not silently ship a NOTICE pointing at nothing;
* a licence text file exists in ``cad/licenses/runtime/`` that no entry
  references (the other direction: a stale text left behind by a removed
  dependency claims an attribution we no longer make);
* an entry's licence is outside ``ALLOWED_LICENCES`` — an unrecognised
  licence is refused rather than guessed at, and plain GPL is a stop;
* an entry whose licence is in ``SOURCE_OBLIGATION_LICENCES`` carries no
  ``obligation`` statement. MPL-2.0 must say where the covered source is;
  OCCT's LGPL-2.1-with-exception must additionally say how a recipient
  relinks. Shipping the text alone discharges neither.

MODES
-----
``python3 cad/scripts/gen_notice.py``
    Writes ``cad/NOTICE.md``. Paths resolve relative to this script, never the
    caller's cwd.

``python3 cad/scripts/gen_notice.py --check``
    Writes nothing; exits 1 on a gate violation or on any drift between the
    committed ``cad/NOTICE.md`` and a fresh generation. This is what CI runs.

``python3 cad/scripts/gen_notice.py --census <site-packages>``
    Rewrites the census from a built bundle's site-packages directory.

``python3 cad/scripts/gen_notice.py --verify-bundle <site-packages>``
    Writes nothing; exits 1 if the committed census and that directory
    disagree. This is what the build legs run.

The output is a pure function of the lock, the census, the inventory and the
licence files — nothing here reads the clock or the environment, so two runs
over an unchanged tree are byte-identical.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import re
import sys
from pathlib import Path
from typing import Union

# cad/scripts/this.py -> cad/
CAD = Path(__file__).resolve().parents[1]

DEFAULT_LOCK_PATH = CAD / "scripts" / "runtime-bundle.lock"
DEFAULT_MANIFEST_PATH = CAD / "scripts" / "runtime-bundle.manifest"
DEFAULT_NOTICE_PATH = CAD / "NOTICE.md"
#: The whole directory that ships (into the bundle and beside the binary).
#: Everything under it is inventoried — see DECLARED_SUPPORT_FILES.
LICENCE_ROOT = CAD / "licenses"
LICENCE_DIR = LICENCE_ROOT / "runtime"
REGEN_COMMAND = "python3 cad/scripts/gen_notice.py"


def _load_inventory():
    """Load the sibling inventory module by path.

    Imported by path rather than by name because this file is run as a script
    from any cwd and is also loaded by path from the test suite; neither route
    puts cad/scripts on sys.path.
    """
    path = Path(__file__).resolve().parent / "notice_inventory.py"
    spec = importlib.util.spec_from_file_location("cad_notice_inventory", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


_inv = _load_inventory()

RuntimeComponent = _inv.RuntimeComponent
RUNTIME_COMPONENTS = _inv.RUNTIME_COMPONENTS
DISTRIBUTION_EXCLUSIONS = _inv.DISTRIBUTION_EXCLUSIONS
DECLARED_SUPPORT_FILES = _inv.DECLARED_SUPPORT_FILES
PERMISSIVE_LICENCES = _inv.PERMISSIVE_LICENCES
SOURCE_OBLIGATION_LICENCES = _inv.SOURCE_OBLIGATION_LICENCES
ALLOWED_LICENCES = _inv.ALLOWED_LICENCES


class NoticeGateError(Exception):
    """Raised when the inventory, the lock or the census fails the gate.

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


def canonical_name(name: str) -> str:
    """PEP 503 normalisation, so ``python_fcl`` and ``Python-FCL`` are one key."""
    return re.sub(r"[-_.]+", "-", name).lower()


def lock_pins(lock_vars: dict) -> list:
    """Every pinned distribution name in the lock, sorted, de-duplicated.

    Both install lists count: ``PIP_NO_DEPS_PKGS`` is not a lesser pin, it is
    the same wheel installed without its declared dependencies, and it ships
    exactly the same bytes.
    """
    specs = f"{lock_vars.get('PIP_PKGS', '')} {lock_vars.get('PIP_NO_DEPS_PKGS', '')}"
    names = set()
    for spec in specs.split():
        names.add(canonical_name(re.split(r"[<>=!~\[]", spec, 1)[0].strip()))
    names.discard("")
    return sorted(names)


# ---------------------------------------------------------------------------
# census
# ---------------------------------------------------------------------------


def read_manifest(manifest_path: Union[str, Path, None] = None) -> dict:
    """The committed census as ``{canonical name: version}``.

    One ``name version`` per line; ``#`` comments and blanks ignored.
    """
    path = Path(manifest_path or DEFAULT_MANIFEST_PATH)
    census: dict = {}
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2:
            raise ValueError(f"{path}:{lineno}: expected `name version`, got {line!r}")
        census[canonical_name(parts[0])] = parts[1]
    return census


_METADATA_NAME = re.compile(r"^Name: (.+)$", re.M)
_METADATA_VERSION = re.compile(r"^Version: (.+)$", re.M)


def census_site_packages(site_packages: Union[str, Path]) -> dict:
    """Census a built bundle's site-packages: ``{canonical name: version}``.

    Reads ``*.dist-info/METADATA`` directly. No interpreter is executed and
    nothing is imported, which is the whole point: running ``pip list`` inside
    the staged interpreter reports the developer's ``~/.local`` packages too,
    and a directory scan cannot.
    """
    root = Path(site_packages)
    if not root.is_dir():
        raise NotADirectoryError(f"{root} is not a directory")
    found: dict = {}
    for dist_info in sorted(root.glob("*.dist-info")):
        metadata = dist_info / "METADATA"
        if not metadata.is_file():
            continue
        text = metadata.read_text(encoding="utf-8", errors="replace")
        name = _METADATA_NAME.search(text)
        version = _METADATA_VERSION.search(text)
        if name and version:
            found[canonical_name(name.group(1).strip())] = version.group(1).strip()
    return found


def census_differences(committed: dict, actual: dict) -> list:
    """``(severity, message)`` for every disagreement with a real bundle.

    The two directions are NOT symmetric, and the asymmetry is what lets one
    census cover three platforms:

    * a distribution in the bundle that the census does not name is an
      ERROR — it ships with no attribution, which is the whole defect this
      gate exists to prevent;
    * a census entry absent from this platform's bundle is a WARNING —
      pexpect and ptyprocess are POSIX-only, so the linux census legitimately
      names things a Windows bundle does not contain. The licence text still
      ships on every platform, which attributes something absent rather than
      failing to attribute something present;
    * a version disagreement is an ERROR: the inventoried licence text may be
      for a different release.
    """
    messages: list = []
    for name in sorted(set(committed) | set(actual)):
        if name not in actual:
            messages.append(("warning",
                             f"{name}: in the census but NOT in this "
                             f"platform's bundle (census says "
                             f"{committed[name]}) — platform-specific, or a "
                             f"dependency that has gone away"))
        elif name not in committed:
            messages.append(("error",
                             f"{name} {actual[name]}: in the bundle but NOT "
                             f"in the census — it ships unattributed"))
        elif committed[name] != actual[name]:
            messages.append(("error",
                             f"{name}: census says {committed[name]}, bundle "
                             f"has {actual[name]}"))
    return messages


def render_manifest(census: dict,
                    manifest_path: Union[str, Path, None] = None) -> str:
    """The census file body for a freshly measured site-packages.

    The header is carried over from the file being rewritten so ``--census``
    keeps the explanation of what the file is; only the entries change.
    """
    header_lines = []
    path = Path(manifest_path or DEFAULT_MANIFEST_PATH)
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            header_lines.append(line)
        else:
            break
    entries = [f"{name} {census[name]}" for name in sorted(census)]
    return "\n".join(header_lines + entries) + "\n"


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
        if comp.license and comp.license not in ALLOWED_LICENCES:
            violations.append(
                f"{who}: licence {comp.license!r} is not in ALLOWED_LICENCES "
                f"({sorted(ALLOWED_LICENCES)}) — copyleft without a discharged "
                f"obligation is a stop, and an unrecognised licence is refused "
                f"rather than guessed")
        if comp.license in SOURCE_OBLIGATION_LICENCES and not comp.obligation:
            violations.append(
                f"{who}: licence {comp.license!r} needs an obligation "
                f"statement — {SOURCE_OBLIGATION_LICENCES[comp.license]} "
                f"Shipping the text alone does not discharge it")
        if comp.license in SOURCE_OBLIGATION_LICENCES and not comp.source_url:
            violations.append(
                f"{who}: licence {comp.license!r} requires a source_url")
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


def _census_violations(census: dict, components: tuple, exclusions: dict) -> list:
    """Both directions between the census and the inventory.

    The census is the list of distributions that reach the built bundle's
    site-packages. Every one of them must be attributed or dismissed with a
    reason; and every attribution must be of something that actually ships,
    at the version that ships.
    """
    violations: list = []
    by_distribution: dict = {}
    for comp in components:
        if comp.distribution:
            by_distribution.setdefault(canonical_name(comp.distribution),
                                       []).append(comp)

    for name in sorted(census):
        if name not in by_distribution and name not in exclusions:
            violations.append(
                f"{name}: distribution in the bundle's site-packages with no "
                f"inventory entry and no DISTRIBUTION_EXCLUSIONS reason — it "
                f"would ship unattributed")

    for name in sorted(exclusions):
        if name not in census:
            violations.append(
                f"{name}: excluded but not in the census — a stale exclusion "
                f"hides the next distribution that takes the same name")
        if name in by_distribution:
            violations.append(
                f"{name}: both inventoried and excluded — one of the two is "
                f"wrong")

    for name in sorted(by_distribution):
        if name not in census:
            violations.append(
                f"{name}: inventoried but not in the census — the entry "
                f"attributes something the bundle no longer contains")
            continue
        # An entry whose component IS the distribution must agree with the
        # census version. Entries for things vendored INSIDE a wheel (OCCT
        # inside cadquery-ocp, FCL inside python-fcl) carry their own version
        # and are exempt: the wheel's version says nothing about them.
        for comp in by_distribution[name]:
            if canonical_name(comp.component) != name:
                continue
            if comp.version != census[name]:
                violations.append(
                    f"{name}: inventoried at version {comp.version}, census "
                    f"says {census[name]} — the licence text may be for the "
                    f"wrong release")
    return violations


def _pin_violations(pins: list, census: dict) -> list:
    """A lock pin that the census does not know about.

    The census describes what a build produces; if something the build is told
    to install is not in it, the census was taken from a different bundle and
    every completeness claim below it is void.
    """
    return [
        f"{pin}: lock pin missing from the census — re-run "
        f"`{REGEN_COMMAND} --census <site-packages>` against a bundle built "
        f"from this lock"
        for pin in pins if pin not in census
    ]


# ---------------------------------------------------------------------------
# render
# ---------------------------------------------------------------------------


def render_notice(lock_vars: dict,
                  components: tuple = RUNTIME_COMPONENTS,
                  licence_dir: Path = LICENCE_DIR,
                  licence_root: Union[Path, None] = None,
                  census: Union[dict, None] = None,
                  exclusions: Union[dict, None] = None) -> str:
    """Render the NOTICE body, or raise :class:`NoticeGateError`.

    The gate runs before any output is built, so a refused run never
    half-renders a NOTICE around the components that did pass.
    """
    # The root defaults to the licence directory's parent so a test (or a
    # future second licence subdirectory) can point the whole check at a copy.
    licence_root = licence_root if licence_root is not None else licence_dir.parent
    census = read_manifest() if census is None else census
    exclusions = DISTRIBUTION_EXCLUSIONS if exclusions is None else exclusions
    pins = lock_pins(lock_vars)
    violations = (_pin_violations(pins, census)
                  + _census_violations(census, components, exclusions)
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
        "ships inside the cad plugin's embedded Python runtime bundle. The "
        "full text of every licence below is in `cad/licenses/runtime/`, "
        "which is copied into the bundle (as `licenses/`) and into the "
        "release tarball beside the plugin binary — BSD and MIT terms require "
        "the notice, conditions and disclaimer to be provided with a binary "
        "distribution, so naming the licence here is not on its own enough.",
        "",
        "The inventory is checked against a census of the built bundle's "
        "site-packages (`cad/scripts/runtime-bundle.manifest`), not against "
        "the two pins in `cad/scripts/runtime-bundle.lock`: pip resolves the "
        f"transitive tree, so the lock names {len(pins)} distributions and "
        f"the bundle contains {len(census)}. Wheel metadata cannot see what a "
        "wheel vendors either — python-fcl's contains compiled FCL, libccd, "
        "OctoMap and Eigen while shipping only python-fcl's LICENSE, and "
        "cadquery-ocp's contains the whole of OCCT while shipping no licence "
        "text at all — so the inventory is maintained by hand in "
        "`cad/scripts/notice_inventory.py` and `gen_notice.py --check` is the "
        "gate that keeps it honest.",
        "",
        f"Lock pins: {', '.join(pins) if pins else '(none)'}",
        "",
        f"Census: {len(census)} distributions in the built bundle's "
        f"site-packages, {len(components)} inventoried components "
        f"(a distribution yields more than one entry when its wheel vendors "
        f"other projects), {len(exclusions)} excluded.",
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
        if comp.obligation:
            lines.append("")
            lines.append(f"**Source availability and relinking.** "
                         f"{comp.obligation}")
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

    lines.append("## Excluded from the inventory")
    lines.append("")
    lines.append(
        "Census distributions deliberately not attributed, each with the "
        "reason. The gate refuses any OTHER census distribution that is "
        "neither inventoried above nor listed here.")
    lines.append("")
    if exclusions:
        for name in sorted(exclusions):
            lines.append(f"- `{name}` — {exclusions[name]}")
    else:
        lines.append("**None.** Every distribution in the census is "
                     "inventoried above.")
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


def generate(lock_path: Union[str, Path, None] = None,
             manifest_path: Union[str, Path, None] = None) -> str:
    """Read the lock and the census and render the NOTICE body — the one
    function both the CLI and the tests call, so neither can read the inputs a
    different way."""
    return render_notice(read_lock_vars(lock_path or DEFAULT_LOCK_PATH),
                         census=read_manifest(manifest_path))


def main(argv: Union[list, None] = None) -> int:
    ap = argparse.ArgumentParser(description="cad runtime NOTICE generator")
    ap.add_argument("--check", action="store_true",
                    help="Write nothing; exit 1 on a gate violation or on "
                         "drift between the committed NOTICE.md and a fresh "
                         "generation.")
    ap.add_argument("--census", metavar="SITE_PACKAGES", default=None,
                    help="Rewrite the census from a built bundle's "
                         "site-packages directory.")
    ap.add_argument("--verify-bundle", metavar="SITE_PACKAGES", default=None,
                    help="Write nothing; exit 1 if the committed census and "
                         "that site-packages disagree.")
    ap.add_argument("--lock", default=None,
                    help="Override the lock path (default: "
                         "cad/scripts/runtime-bundle.lock).")
    ap.add_argument("--manifest", default=None,
                    help="Override the census path (default: "
                         "cad/scripts/runtime-bundle.manifest).")
    ap.add_argument("--out", default=None,
                    help="Override the output path (default: cad/NOTICE.md).")
    args = ap.parse_args(argv)

    lock_path = Path(args.lock) if args.lock else DEFAULT_LOCK_PATH
    manifest_path = Path(args.manifest) if args.manifest else DEFAULT_MANIFEST_PATH
    out_path = Path(args.out) if args.out else DEFAULT_NOTICE_PATH

    # `is not None`, not truthiness: the build leg passes a path expanded from
    # a shell glob, and a glob that matched nothing expands to an empty string.
    # Under a truthiness test that empty argument falls through to the GENERATE
    # branch, which rewrites NOTICE.md and exits 0 — the verification step
    # passes precisely when there is no bundle to verify.
    if args.verify_bundle is not None:
        if not args.verify_bundle.strip():
            print("gen_notice --verify-bundle: empty site-packages path "
                  "(the caller's glob matched no bundle)", file=sys.stderr)
            return 1
        try:
            actual = census_site_packages(args.verify_bundle)
        except OSError as exc:
            print(f"gen_notice --verify-bundle: {exc}", file=sys.stderr)
            return 1
        differences = census_differences(read_manifest(manifest_path), actual)
        errors = [m for severity, m in differences if severity == "error"]
        for severity, message in differences:
            print(f"  {severity}: {message}", file=sys.stderr)
        if errors:
            print(f"gen_notice --verify-bundle: {manifest_path} does not "
                  f"describe {args.verify_bundle} — {len(errors)} error(s). "
                  f"Re-census with `{REGEN_COMMAND} --census "
                  f"{args.verify_bundle}` and inventory whatever is new",
                  file=sys.stderr)
            return 1
        print(f"gen_notice --verify-bundle: census covers "
              f"{len(actual)} distributions with no unattributed ones.")
        return 0

    if args.census is not None:
        if not args.census.strip():
            print("gen_notice --census: empty site-packages path",
                  file=sys.stderr)
            return 1
        try:
            found = census_site_packages(args.census)
        except OSError as exc:
            print(f"gen_notice --census: {exc}", file=sys.stderr)
            return 1
        # Rendered BEFORE the file is opened: `open(..., "w")` truncates, and
        # render_manifest reads the existing header back out of that same file.
        body = render_manifest(found, manifest_path)
        with open(manifest_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(body)
        print(f"gen_notice --census: wrote {manifest_path} "
              f"({len(found)} distributions).")
        return 0

    try:
        body = generate(lock_path, manifest_path)
    except NoticeGateError as exc:
        print(f"gen_notice: GATE REFUSED\n{exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # lock or census missing/unreadable
        print(f"gen_notice: cannot read {lock_path} / {manifest_path}: {exc}",
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

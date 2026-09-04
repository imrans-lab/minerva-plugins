"""The contract between the runtime-bundle lock, the build script and CI.

These three files have to agree about one dependency in four places — how it
is pinned, which wheel platform tags can resolve it, which stage gets import
probed, and how the Windows leg makes it loadable on a machine that is not a
CI runner. Nothing at run time notices when they stop agreeing: a bundle built
from a lock the build script cannot satisfy fails at BUILD time on a good day,
and on a bad day builds a bundle whose extension only imports on the machine
that made it.

Everything here is read from the files themselves. There is no fixture copy of
the lock to drift out of date, and no mock: the subject IS the text of the
three files.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import zipfile
from pathlib import Path

CAD = Path(__file__).resolve().parents[2]
REPO = CAD.parent
LOCK_PATH = CAD / "scripts" / "runtime-bundle.lock"
BUILD_SCRIPT = REPO / "scripts" / "build-python-runtime-bundle.sh"
PROBE_SCRIPT = REPO / "scripts" / "probe-python-runtime-bundle.sh"
WORKFLOW = REPO / ".github" / "workflows" / "cad.yml"

#: Distribution name -> the module its wheel actually provides. A --no-deps
#: install is only safe if something imports the result, and the import name
#: is not derivable from the pin (`python-fcl` provides `fcl`).
DIST_IMPORT_NAME = {"python-fcl": "fcl"}


def _load_gen_notice():
    path = CAD / "scripts" / "gen_notice.py"
    spec = importlib.util.spec_from_file_location("cad_gen_notice", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


gn = _load_gen_notice()
LOCK = gn.read_lock_vars(LOCK_PATH)
LOCK_TEXT = LOCK_PATH.read_text(encoding="utf-8")
BUILD_TEXT = BUILD_SCRIPT.read_text(encoding="utf-8")
WORKFLOW_TEXT = WORKFLOW.read_text(encoding="utf-8")


def _wheel_plats(triple: str) -> list:
    """The WHEEL_PLATS list the build script uses for *triple*."""
    block = re.search(
        rf"^  {re.escape(triple)}\)\n(.*?)^    ;;",
        BUILD_TEXT, re.S | re.M)
    assert block, f"{triple} has no case arm in {BUILD_SCRIPT}"
    plats = re.search(r'WHEEL_PLATS="([^"]*)"', block.group(1))
    assert plats, f"{triple} declares no WHEEL_PLATS"
    return plats.group(1).split()


# ---------------------------------------------------------------------------
# The pin
# ---------------------------------------------------------------------------


def test_every_no_deps_pin_is_import_probed():
    """--no-deps is a claim that the omitted dependencies are unused.

    LAYER1_IMPORTS is the only thing that tests the claim, so a pin installed
    without its dependencies and never imported is an unproven assertion that
    ships.
    """
    for spec in LOCK.get("PIP_NO_DEPS_PKGS", "").split():
        dist = re.split(r"[<>=!~\[]", spec, 1)[0]
        assert dist in DIST_IMPORT_NAME, (
            f"{dist} is installed --no-deps but this test does not know which "
            f"module it provides; add it to DIST_IMPORT_NAME")
        module = DIST_IMPORT_NAME[dist]
        assert re.search(rf"\bimport {re.escape(module)}\b",
                         LOCK.get("LAYER1_IMPORTS", "")), (
            f"{dist} is installed --no-deps but `import {module}` is not in "
            f"LAYER1_IMPORTS")


def test_pins_are_exact_versions():
    """A range would let two builds of the same commit ship different bytes."""
    for spec in (LOCK.get("PIP_PKGS", "") + " "
                 + LOCK.get("PIP_NO_DEPS_PKGS", "")).split():
        assert "==" in spec, f"{spec} is not pinned to an exact version"


def test_python_fcl_is_installed_without_its_declared_dependencies():
    """Its Requires-Dist names Cython, which only the BUILD needs.

    Installing with dependencies would put a compiler front-end in a runtime
    bundle; the import probe above is what proves leaving it out is safe.
    """
    assert "python-fcl==" in LOCK.get("PIP_NO_DEPS_PKGS", "")
    assert "python-fcl" not in LOCK.get("PIP_PKGS", "")


# ---------------------------------------------------------------------------
# The wheels
# ---------------------------------------------------------------------------


def test_recorded_wheel_filenames_are_resolvable_on_their_target():
    """Every wheel filename the lock records has a matching platform tag.

    The macos-amd64 slice is the reason this exists: it is a CROSS install, so
    a platform tag missing from WHEEL_PLATS does not fail the build with "no
    wheel found" — pip is asked for a platform it cannot match, and the half
    of the universal binary that ships to Intel Macs comes out missing the
    library entirely.
    """
    recorded = re.findall(r"^#\s+(\S+\.whl)\s", LOCK_TEXT, re.M)
    assert recorded, "the lock records no wheel filenames"

    # filename tail -> the triple whose WHEEL_PLATS must accept it
    expectations = {
        "manylinux_2_28_x86_64": "linux-x86_64",
        "macosx_11_0_arm64": "macos-arm64",
        "macosx_10_13_x86_64": "macos-amd64",
        "win_amd64": "windows-x86_64",
    }
    covered = set()
    for filename in recorded:
        stem = filename[:-len(".whl")]
        # A wheel may carry several platform tags ("manylinux_2_24_x86_64.
        # manylinux_2_28_x86_64"); any one of them resolving is enough.
        for tag, triple in expectations.items():
            if tag in stem:
                assert tag in _wheel_plats(triple), (
                    f"{filename} needs platform tag {tag}, which is not in "
                    f"WHEEL_PLATS for {triple}")
                covered.add(triple)
    assert covered == set(expectations.values()), (
        f"the lock records no wheel for {set(expectations.values()) - covered} "
        f"— every release target needs one")


def test_no_pip_install_can_fall_back_to_a_source_build():
    """--only-binary=:all: on every install path.

    An sdist fallback runs the package's build backend — arbitrary code — on
    the build machine, and the bundle would then contain something no wheel
    hash covers.
    """
    # Join shell line-continuations first: an install is one command spread
    # over several lines, and checking line by line would pass by accident.
    commands = re.sub(r"\\\n\s*", " ", BUILD_TEXT).splitlines()
    installs = [c for c in commands if "-m pip install" in c]
    assert installs, "no pip install found in the build script"
    for command in installs:
        assert "--only-binary=:all:" in command or "--no-index" in command, (
            f"pip install without --only-binary or --no-index: {command.strip()}")


# ---------------------------------------------------------------------------
# The Windows C++ runtime
# ---------------------------------------------------------------------------


def test_windows_repaired_packages_are_also_no_deps_pins():
    """The repaired local wheel must be the only way the package can arrive.

    If a repaired spec were also in PIP_PKGS, the PyPI copy would install
    afterwards and silently replace the repaired one — the bundle would look
    repaired and behave like an unrepaired one.
    """
    repair = LOCK.get("WHEEL_REPAIR_PKGS", "").split()
    no_deps = LOCK.get("PIP_NO_DEPS_PKGS", "").split()
    for spec in repair:
        assert spec in no_deps, (
            f"{spec} is repaired but not listed verbatim in PIP_NO_DEPS_PKGS")
    if repair:
        assert "==" in LOCK.get("WHEEL_REPAIR_TOOL", ""), \
            "WHEEL_REPAIR_TOOL must be pinned when wheels are repaired"


def test_repair_args_are_declared_and_actually_passed():
    """The flags a wheel needs to be repairable are lock data, not folklore.

    python-fcl keeps ccd.dll, octomap.dll and octomath.dll inside
    its package directory, and delvewheel only consults the wheel's own files
    when --ignore-existing is given — without it the repair dies with "Unable
    to find library: ccd.dll" before it can vendor anything. --analyze-existing
    is the second half: octomap.dll imports MSVCP140.dll as well as the .pyd
    does, and only that flag follows an in-wheel DLL's own dependencies.
    """
    if not LOCK.get("WHEEL_REPAIR_PKGS", "").strip():
        return
    args = LOCK.get("WHEEL_REPAIR_ARGS", "")
    assert "--ignore-existing" in args
    assert "--analyze-existing" in args
    assert "$WHEEL_REPAIR_ARGS" in BUILD_TEXT, \
        "the build script must pass the declared repair arguments"


def _repair_proof_snippet() -> str:
    """The python the build script runs to prove a repaired wheel."""
    snippet = re.search(
        r'-c "\n(import sys, zipfile, re\n.*?)"\s*"\$whl"',
        BUILD_TEXT, re.S)
    assert snippet, "the build script no longer proves the repair in python"
    return snippet.group(1)


def _plant_wheel(path, names):
    with zipfile.ZipFile(path, "w") as archive:
        for name in names:
            archive.writestr(name, b"")
    return path


def test_the_repair_proof_accepts_a_vendored_runtime_and_rejects_a_bare_wheel(
        tmp_path):
    """Run the build script's own post-condition against two planted wheels.

    delvewheel writes an output wheel even when it vendored nothing, so a
    repair that silently did nothing is indistinguishable by exit code. The
    proof reads the wheel's member names, and what it looks for is lock data
    (WHEEL_REPAIR_PROOF), because which runtime a wheel is missing belongs to
    the wheel. Both directions are exercised: a wheel carrying the vendored
    DLL passes, and the same wheel without it fails.
    """
    if not LOCK.get("WHEEL_REPAIR_PKGS", "").strip():
        return
    pattern = LOCK.get("WHEEL_REPAIR_PROOF", "")
    assert pattern, "a repaired wheel needs a proof pattern in the lock"
    snippet = _repair_proof_snippet()

    repaired = _plant_wheel(tmp_path / "repaired.whl", [
        "fcl/__init__.py",
        "fcl.libs/msvcp140-1a2b3c4d.dll",
    ])
    bare = _plant_wheel(tmp_path / "bare.whl", [
        "fcl/__init__.py",
        "fcl.libs/vcruntime140.dll",
    ])
    passed = subprocess.run(
        [sys.executable, "-c", snippet, str(repaired), pattern], check=False)
    failed = subprocess.run(
        [sys.executable, "-c", snippet, str(bare), pattern], check=False)
    assert passed.returncode == 0, "a wheel with the vendored runtime was rejected"
    assert failed.returncode != 0, "a wheel that vendored nothing was accepted"


def test_a_bundle_without_the_runtime_names_the_dll_rather_than_the_module(
        capsys):
    """The diagnosis a user can act on, produced by the code that writes it.

    "DLL load failed while importing fcl" names the module, not the thing that
    is missing. The dispatcher's own diagnosis is run here against the error
    Windows actually raises, and the stderr line is read back: the Go parent
    matches stderr on the RAW line prefix, so a line the logging module has
    prefixed with "[mcad_worker]" never becomes a toast.
    """
    spec = importlib.util.spec_from_file_location(
        "cad_dispatcher", CAD / "worker" / "mcad_worker" / "dispatcher.py")
    dispatcher = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(dispatcher)

    windows_error = ImportError(
        "DLL load failed while importing fcl: The specified module could "
        "not be found.")
    diagnosis = dispatcher._backend_diagnosis("fcl", windows_error)
    assert "MSVCP140.dll" in diagnosis
    assert "fcl" in diagnosis

    # A backend that cannot possibly import, so the failure path runs on any
    # machine: the report says UNAVAILABLE and the stderr line the Go parent
    # matches on is written raw, not through the logger.
    dispatcher.GEOMETRY_BACKENDS = ("mcad_worker_no_such_backend",)
    report = dispatcher._probe_geometry_backends()
    line = capsys.readouterr().err
    assert report["mcad_worker_no_such_backend"].startswith("UNAVAILABLE")
    assert line.startswith("ERROR: cad geometry backend unavailable")


# ---------------------------------------------------------------------------
# The probe reaches every shipped stage
# ---------------------------------------------------------------------------


def test_ci_probes_every_release_slice_including_the_cross_installed_one():
    """The macos-amd64 slice is the one nothing else executes.

    The build script skips it (a foreign binary), and `go test` compiles only
    the runner's own embed_darwin_* tag, so the embed test covers the arm64
    half twice and the amd64 half never.
    """
    assert "probe-python-runtime-bundle.sh . macos-arm64" in WORKFLOW_TEXT
    assert 'RUNTIME_PROBE_PREFIX="arch -x86_64"' in WORKFLOW_TEXT
    assert "probe-python-runtime-bundle.sh . macos-amd64" in WORKFLOW_TEXT
    assert "probe-python-runtime-bundle.sh . ${{ matrix.target }}" in WORKFLOW_TEXT


def test_probe_and_build_share_one_import_list():
    """Both read LAYER1_IMPORTS from the lock; neither restates a pin."""
    probe_text = PROBE_SCRIPT.read_text(encoding="utf-8")
    assert "LAYER1_IMPORTS" in probe_text
    assert "probe-python-runtime-bundle.sh" in BUILD_TEXT
    # The workflow must not restate a VERSION: the lock is the single source
    # of pins, so bumping one there cannot leave a stale copy in CI. (A bare
    # package NAME in a comment is fine — cad.yml explains the dropped
    # linux-arm64 target by naming build123d.)
    for spec in (LOCK.get("PIP_PKGS", "") + " "
                 + LOCK.get("PIP_NO_DEPS_PKGS", "")).split():
        assert spec not in WORKFLOW_TEXT, (
            f"{spec} is pinned in cad.yml — pins belong only in the lock file")


# ---------------------------------------------------------------------------
# The licence texts travel with the bytes
# ---------------------------------------------------------------------------


def test_licence_directory_is_bundled_and_packed():
    licence_dir = LOCK.get("BUNDLE_LICENSE_DIR", "")
    assert licence_dir, "BUNDLE_LICENSE_DIR is not declared"
    assert (CAD / licence_dir).is_dir()
    assert "BUNDLE_LICENSE_DIR" in BUILD_TEXT
    assert 'cp -r licenses "$PACKDIR/"' in WORKFLOW_TEXT
    assert 'cp NOTICE.md "$PACKDIR/"' in WORKFLOW_TEXT

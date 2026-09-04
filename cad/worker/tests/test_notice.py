"""The cad runtime licence inventory and the gate that keeps it honest.

WHAT THESE TESTS ARE FOR. ``cad/NOTICE.md`` is generated, so nothing here
checks its prose. What matters is that the GATE refuses in every direction it
claims to: the failure this suite exists to catch is a release that ships a
BSD-licensed library with its licence text quietly missing, which looks
identical to a correct release from the outside.

The generator is a script, not an importable package member, so it is loaded
by file path — the same way pcb's NOTICE test loads its own.
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

CAD = Path(__file__).resolve().parents[2]
REPO = CAD.parent
GEN_NOTICE = CAD / "scripts" / "gen_notice.py"


def _load_gen_notice():
    spec = importlib.util.spec_from_file_location("cad_gen_notice", GEN_NOTICE)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


gn = _load_gen_notice()


@pytest.fixture()
def lock_vars() -> dict:
    return gn.read_lock_vars(gn.DEFAULT_LOCK_PATH)


@pytest.fixture()
def licence_copy(tmp_path: Path) -> Path:
    """A writable copy of the WHOLE cad/licenses tree, returning its runtime/.

    The whole tree, not just runtime/: the gate walks everything that ships,
    and a fixture that copied only the licence texts could not express the
    mutation that exposed the hole — moving cad/licenses/README.md away.
    """
    dest = tmp_path / "licenses"
    shutil.copytree(gn.LICENCE_ROOT, dest)
    return dest / "runtime"


# ---------------------------------------------------------------------------
# The committed state
# ---------------------------------------------------------------------------


def test_committed_notice_passes_the_gate_and_is_not_stale():
    """`--check` is what CI runs; it must pass on the committed tree.

    Failing here means either the inventory refuses the lock, or NOTICE.md was
    not regenerated after the inventory changed.
    """
    proc = subprocess.run(
        [sys.executable, str(GEN_NOTICE), "--check"],
        capture_output=True, text=True, cwd=str(REPO),
    )
    assert proc.returncode == 0, (
        f"gen_notice --check failed:\n{proc.stdout}\n{proc.stderr}")


def test_every_inventoried_component_has_a_real_licence_text():
    """The obligation itself: a BSD/MIT component ships its full text.

    Checked directly against the tree rather than through the gate, so a bug
    in the gate cannot make this pass.
    """
    for comp in gn.RUNTIME_COMPONENTS:
        assert comp.license_files, f"{comp.component} declares no licence text"
        for name in comp.license_files:
            path = gn.LICENCE_DIR / name
            assert path.is_file(), f"{comp.component}: {path} is missing"
            assert path.read_text(encoding="utf-8").strip(), \
                f"{comp.component}: {path} is empty"


def test_the_wheel_and_its_vendored_libraries_are_all_inventoried():
    """python-fcl's wheel carries four other projects; all five are declared.

    This is the fact the whole inventory exists for — wheel metadata reports
    only python-fcl, so an inventory built from metadata would attribute one
    project and ship five.
    """
    components = {c.component for c in gn.RUNTIME_COMPONENTS}
    for expected in ("python-fcl", "FCL (Flexible Collision Library)",
                     "libccd", "OctoMap (octomap + octomath)", "Eigen"):
        assert expected in components, f"{expected} is not inventoried"


def test_eigen_is_the_only_copyleft_and_carries_its_source_url():
    """MPL-2.0 §3.2(a) is discharged by naming where the source is."""
    eigen = [c for c in gn.RUNTIME_COMPONENTS if c.component == "Eigen"]
    assert len(eigen) == 1
    assert eigen[0].license == "MPL-2.0"
    assert eigen[0].source_url.startswith("https://")
    for comp in gn.RUNTIME_COMPONENTS:
        assert "GPL" not in comp.license.upper(), \
            f"{comp.component}: GPL/LGPL in the shipped tree is a stop"


def test_rendered_notice_names_every_component_and_its_text_file(lock_vars):
    body = gn.render_notice(lock_vars)
    for comp in gn.RUNTIME_COMPONENTS:
        assert comp.component in body
        assert comp.copyright in body
        for name in comp.license_files:
            assert name in body


def test_generation_depends_only_on_the_lock_and_the_licence_texts(lock_vars,
                                                                  licence_copy):
    """Two renders agree only because the same inputs produced them.

    The gate compares a stored NOTICE.md against a fresh render, so anything
    in the output that comes from the run rather than from the inputs — a
    timestamp, a path, a dict order — makes every release refuse. Changing an
    input has to change the output, or the comparison proves nothing.
    """
    first = gn.render_notice(lock_vars, licence_dir=licence_copy)
    assert gn.render_notice(lock_vars, licence_dir=licence_copy) == first

    # And the output really does follow its inputs: the NOTICE records the
    # hash of every licence text it attributes, so a changed text is a
    # changed NOTICE and the gate makes someone look at it.
    text = licence_copy / "fcl-0.7.0.LICENSE.txt"
    text.write_text(text.read_text(encoding="utf-8") + "\n(amended upstream)\n", encoding="utf-8")
    assert gn.render_notice(lock_vars, licence_dir=licence_copy) != first


# ---------------------------------------------------------------------------
# The gate refuses — one test per direction it claims to catch
# ---------------------------------------------------------------------------


def test_gate_refuses_when_a_licence_text_is_removed(lock_vars, licence_copy):
    """The load-bearing mutation: delete a text, the release must refuse."""
    (licence_copy / "fcl-0.7.0.LICENSE.txt").unlink()
    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(lock_vars, licence_dir=licence_copy)
    assert "fcl-0.7.0.LICENSE.txt" in str(exc.value)


def test_gate_refuses_an_empty_licence_text(lock_vars, licence_copy):
    (licence_copy / "libccd-2.1.BSD-LICENSE.txt").write_text("   \n")
    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(lock_vars, licence_dir=licence_copy)
    assert "libccd-2.1.BSD-LICENSE.txt" in str(exc.value)


def test_gate_refuses_a_licence_text_nothing_references(lock_vars, licence_copy):
    """The other direction: a stale text is an attribution we no longer make."""
    (licence_copy / "leftover-dependency.LICENSE.txt").write_text("whatever")
    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(lock_vars, licence_dir=licence_copy)
    assert "leftover-dependency.LICENSE.txt" in str(exc.value)


def test_gate_refuses_when_a_declared_support_file_is_removed(lock_vars,
                                                              licence_copy):
    """The directory ships more than licence texts, and all of it is declared.

    With only runtime/ inventoried, removing cad/licenses/README.md leaves
    `--check` reporting "up to date": a directory listing cannot notice a file
    that is gone. The declared inventory can, and names it.
    """
    (licence_copy.parent / "README.md").unlink()
    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(lock_vars, licence_dir=licence_copy)
    assert "README.md" in str(exc.value)


def test_gate_refuses_a_file_the_inventory_does_not_declare(lock_vars,
                                                            licence_copy):
    """Anywhere under cad/licenses, not only in runtime/."""
    (licence_copy.parent / "unexpected.txt").write_text("whatever")
    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(lock_vars, licence_dir=licence_copy)
    assert "unexpected.txt" in str(exc.value)


def test_an_altered_licence_text_is_named_by_its_content_hash(lock_vars,
                                                              licence_copy):
    """Presence is not enough — the bytes must be the bytes attributed.

    A licence text stripped of its disclaimer, or swapped for another
    project's, exists and is non-empty: only the hash recorded in NOTICE.md
    catches it, and `--check` then names the file rather than reporting
    unexplained drift.
    """
    committed = gn.DEFAULT_NOTICE_PATH.read_text(encoding="utf-8")
    target = licence_copy / "libccd-2.1.BSD-LICENSE.txt"
    target.write_text(target.read_text(encoding="utf-8").split("\n")[0],
                      encoding="utf-8")

    fresh = gn.render_notice(lock_vars, licence_dir=licence_copy)
    assert fresh != committed, "an altered licence text must produce drift"

    differences = gn.hash_differences(committed, fresh)
    assert any("libccd-2.1.BSD-LICENSE.txt" in d and "CONTENT CHANGED" in d
               for d in differences), differences


def test_notice_records_a_hash_for_every_shipped_file(lock_vars):
    """The record the drift check compares against."""
    hashed = gn.hashed_files(gn.render_notice(lock_vars))
    expected = {f"cad/licenses/runtime/{name}"
                for comp in gn.RUNTIME_COMPONENTS
                for name in comp.license_files}
    expected |= {f"cad/licenses/{name}" for name in gn.DECLARED_SUPPORT_FILES}
    assert set(hashed) == expected
    for path, digest in hashed.items():
        assert len(digest) == 64, f"{path} has no usable sha256"


def test_gate_refuses_a_lock_pin_nobody_inventoried(lock_vars):
    """Adding a dependency without attributing it fails before it ships."""
    mutated = dict(lock_vars)
    mutated["PIP_PKGS"] = lock_vars.get("PIP_PKGS", "") + " some-new-dep==1.0.0"
    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(mutated)
    assert "some-new-dep" in str(exc.value)


def test_gate_refuses_a_copyleft_licence(lock_vars):
    """A GPL component is a stop, not a NOTICE line."""
    poisoned = gn.RUNTIME_COMPONENTS + (
        gn.RuntimeComponent(
            distribution="python-fcl",
            component="something-gpl",
            version="1.0",
            license="GPL-3.0-only",
            copyright="Copyright (c) someone",
            source_url="https://example.invalid/",
            license_files=("python-fcl-0.7.0.11.LICENSE.txt",),
            note="hypothetical",
        ),
    )
    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(lock_vars, components=poisoned)
    assert "GPL-3.0-only" in str(exc.value)


def test_gate_reports_every_violation_at_once(lock_vars, licence_copy):
    """A release engineer sees the whole problem, not the first line of it."""
    (licence_copy / "fcl-0.7.0.LICENSE.txt").unlink()
    (licence_copy / "octomap-1.9.8.LICENSE.txt").unlink()
    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(lock_vars, licence_dir=licence_copy)
    message = str(exc.value)
    assert "fcl-0.7.0.LICENSE.txt" in message
    assert "octomap-1.9.8.LICENSE.txt" in message


def test_lock_is_parsed_without_executing_it(tmp_path: Path):
    """The lock is read as data. A `rm -rf` in it must not run.

    The parser exists instead of `bash -c source` precisely because CI reads
    this file from whatever branch is being built.
    """
    booby_trapped = tmp_path / "runtime-bundle.lock"
    sentinel = tmp_path / "should-not-exist"
    booby_trapped.write_text(
        f'PIP_PKGS="build123d==0.10.0"\n'
        f'touch {sentinel}\n'
        f'PIP_NO_DEPS_PKGS="python-fcl==0.7.0.11"\n',
        encoding="utf-8")
    values = gn.read_lock_vars(booby_trapped)
    assert not sentinel.exists()
    assert values["PIP_PKGS"] == "build123d==0.10.0"
    assert gn.lock_pins(values) == ["build123d", "python-fcl"]

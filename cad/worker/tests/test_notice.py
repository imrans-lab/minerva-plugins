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


def test_every_copyleft_component_discharges_its_extra_obligation():
    """Carrying the text is not enough for either copyleft licence we ship.

    Two components are not plain-permissive: Eigen (MPL-2.0, whose §3.2(a)
    obliges us to say where the covered source is) and OCCT (LGPL-2.1 with the
    Open CASCADE exception, whose §6 obliges us to make relinking possible).
    Both are allowed only because the NOTICE says how; an entry that lost its
    statement would still render a plausible-looking NOTICE, and that is the
    failure this test names.

    Any OTHER component whose licence mentions GPL is a stop — the allowed
    set is a list, not a pattern, so a new LGPL dependency cannot slip in by
    resembling this one.
    """
    obliged = {c.component: c for c in gn.RUNTIME_COMPONENTS
               if c.license in gn.SOURCE_OBLIGATION_LICENCES}
    assert set(obliged) == {"Eigen", "Open CASCADE Technology (OCCT)"}
    for comp in obliged.values():
        assert comp.source_url.startswith("https://"), comp.component
        assert comp.obligation.strip(), comp.component

    for comp in gn.RUNTIME_COMPONENTS:
        if "GPL" in comp.license.upper():
            assert comp.license in gn.SOURCE_OBLIGATION_LICENCES, \
                f"{comp.component}: {comp.license} is not a reviewed exception"


def test_occt_says_it_is_dynamically_linked_and_how_to_relink():
    """The LGPL §6 statement, checked for the facts it has to contain.

    A statement that omits where the source is, or that it is the shared
    libraries in the wheel that are replaceable, does not put a recipient in a
    position to exercise the right the licence grants — and no amount of
    licence text makes up for it.
    """
    occt = [c for c in gn.RUNTIME_COMPONENTS
            if c.component == "Open CASCADE Technology (OCCT)"]
    assert len(occt) == 1
    statement = occt[0].obligation
    for fact in ("DYNAMICALLY LINKED", "cadquery_ocp.libs",
                 "Open-Cascade-SAS/OCCT/tree/V7_8_1", "relink"):
        assert fact in statement, f"the relinking statement omits {fact!r}"
    rendered = gn.render_notice(gn.read_lock_vars(gn.DEFAULT_LOCK_PATH))
    assert statement in rendered, "the statement never reaches the NOTICE"


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


def test_gate_refuses_a_lock_pin_the_census_does_not_know(lock_vars):
    """A pin the census has never seen means the census describes another
    bundle, and every completeness claim under it is void."""
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


# ---------------------------------------------------------------------------
# The census: what actually lands in the built bundle's site-packages
# ---------------------------------------------------------------------------


def _fake_site_packages(root: Path, distributions: dict) -> Path:
    """A directory shaped like a built bundle's site-packages.

    Only the parts the census reads exist: one ``<name>-<version>.dist-info``
    per distribution, each holding a METADATA file with Name and Version.
    That is deliberate — the census must work off files, because the one thing
    it may not do is run the staged interpreter.
    """
    site_packages = root / "site-packages"
    site_packages.mkdir(parents=True, exist_ok=True)
    for name, version in distributions.items():
        info = site_packages / f"{name.replace('-', '_')}-{version}.dist-info"
        info.mkdir()
        (info / "METADATA").write_text(
            f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n",
            encoding="utf-8")
    return site_packages


def test_the_committed_census_is_what_a_site_packages_scan_produces(tmp_path):
    """The census reader and the census file agree on shape and content.

    Round-tripping the committed census through a directory that contains
    exactly those distributions proves the reader is the same function that
    produced the file — otherwise a census generated on one machine and
    verified on another can disagree for reasons nobody can see.
    """
    census = gn.read_manifest()
    assert census, "the committed census is empty"
    site_packages = _fake_site_packages(tmp_path, census)
    assert gn.census_site_packages(site_packages) == census


def test_gate_refuses_a_site_packages_distribution_with_no_inventory_entry(
        tmp_path, lock_vars):
    """THE mutation this whole census exists for.

    A wheel arrives in the bundle — pulled in transitively, or added to the
    lock — and nobody attributes it. Planting a dist-info in a copy of the
    census input and feeding the resulting census to the gate is the closest
    thing to that happening for real, and it must refuse.

    Oracle: unzip a release tarball's site-packages and diff its dist-info
    names against the `## ` headings in NOTICE.md. Anything in the first list
    and not the second is a library shipping unattributed, which is what this
    test claims cannot happen.
    """
    census = dict(gn.read_manifest())
    census["totally-unattributed"] = "1.0.0"
    site_packages = _fake_site_packages(tmp_path, census)
    measured = gn.census_site_packages(site_packages)
    assert "totally-unattributed" in measured

    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(lock_vars, census=measured)
    message = str(exc.value)
    assert "totally-unattributed" in message
    assert "unattributed" in message


def test_gate_accepts_a_census_distribution_that_is_excluded_with_a_reason(
        tmp_path, lock_vars):
    """The escape hatch, and its limit.

    An exclusion is a claim a reader can argue with, so it makes the gate
    pass; a stale exclusion — one naming something no longer in the census —
    hides the next distribution to take that name, so it does not.
    """
    census = dict(gn.read_manifest())
    census["something-first-party"] = "0.1.0"
    excused = {"something-first-party": "our own worker package, not third-party"}
    gn.render_notice(lock_vars, census=census, exclusions=excused)

    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(lock_vars, exclusions={"long-gone": "removed"})
    assert "long-gone" in str(exc.value)


def test_gate_refuses_an_inventory_version_the_census_disagrees_with(lock_vars):
    """A transitive upgrade leaves the shipped text describing the old release.

    numpy 2.5.2's text is not automatically numpy 2.6's, so an entry whose
    version has drifted away from the census is refused rather than rendered.
    """
    census = dict(gn.read_manifest())
    census["numpy"] = "99.0.0"
    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(lock_vars, census=census)
    assert "numpy" in str(exc.value)


def test_gate_refuses_an_entry_for_something_the_census_no_longer_has(lock_vars):
    """The other direction: attributing a library that stopped shipping."""
    census = {k: v for k, v in gn.read_manifest().items() if k != "sympy"}
    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(lock_vars, census=census)
    assert "sympy" in str(exc.value)


def test_gate_refuses_a_copyleft_entry_whose_obligation_statement_is_gone():
    """Deleting the relinking statement must fail, not render a shorter NOTICE.

    The statement is prose, so nothing but this check stands between "OCCT
    ships with its LGPL text" and "OCCT ships with the text AND the terms that
    make dynamic linking lawful".
    """
    stripped = tuple(
        c._replace(obligation="")
        if c.component == "Open CASCADE Technology (OCCT)" else c
        for c in gn.RUNTIME_COMPONENTS)
    with pytest.raises(gn.NoticeGateError) as exc:
        gn.render_notice(gn.read_lock_vars(gn.DEFAULT_LOCK_PATH),
                         components=stripped)
    assert "obligation" in str(exc.value)


def test_verify_bundle_errors_on_an_extra_and_only_warns_on_a_missing_one():
    """One census covers three platforms because the directions differ.

    pexpect is POSIX-only, so a Windows bundle legitimately lacks a census
    entry; a bundle that CONTAINS something the census does not name is the
    unattributed-shipping defect and has to be an error. Collapsing the two
    into one severity makes the gate either useless on Windows or useless
    everywhere.

    Oracle: run `--verify-bundle` against a real Windows bundle's
    Lib/site-packages. It must exit 0 while reporting pexpect and ptyprocess
    as warnings.
    """
    census = gn.read_manifest()

    missing = {k: v for k, v in census.items() if k != "pexpect"}
    severities = {s for s, _ in gn.census_differences(census, missing)}
    assert severities == {"warning"}

    extra = dict(census)
    extra["stowaway"] = "1.0"
    errors = [m for s, m in gn.census_differences(census, extra) if s == "error"]
    assert any("stowaway" in m for m in errors)

    bumped = dict(census)
    bumped["numpy"] = "99.0.0"
    errors = [m for s, m in gn.census_differences(census, bumped) if s == "error"]
    assert any("numpy" in m for m in errors)


def test_every_census_distribution_reaches_the_rendered_notice():
    """The completeness claim itself, checked against the rendered document.

    The gate reasons over the inventory; this reasons over the OUTPUT, so a
    render that silently dropped a section — or an entry whose distribution
    key and heading disagree — is caught by the thing a reader would actually
    look at.
    """
    body = gn.render_notice(gn.read_lock_vars(gn.DEFAULT_LOCK_PATH))
    for name in gn.read_manifest():
        assert f"`{name}` wheel" in body or f"- `{name}` —" in body, \
            f"{name} is in the census but nothing in NOTICE.md accounts for it"


def test_census_rewrite_keeps_the_header_and_lists_what_it_measured(tmp_path):
    """`--census` rewrites the entries and keeps the explanation above them.

    The bug this catches is not hypothetical: rendering the new body INSIDE
    the `open(..., "w")` that truncates the file reads the header back out of
    an already-empty file and silently drops it, and the result is still a
    valid census that the gate accepts. Only re-reading the written file
    notices.
    """
    manifest = tmp_path / "runtime-bundle.manifest"
    shutil.copyfile(gn.DEFAULT_MANIFEST_PATH, manifest)
    site_packages = _fake_site_packages(tmp_path, {"alpha": "1.0", "beta": "2.0"})

    assert gn.main(["--census", str(site_packages),
                    "--manifest", str(manifest)]) == 0

    written = manifest.read_text(encoding="utf-8")
    assert written.startswith("# cad/scripts/runtime-bundle.manifest")
    assert gn.read_manifest(manifest) == {"alpha": "1.0", "beta": "2.0"}

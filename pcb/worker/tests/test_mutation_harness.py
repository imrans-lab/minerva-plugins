"""Gate-integrity tests for the mutation harness itself (tools/mutants/).

WHY THESE EXIST
---------------
``run_sweep.py`` is the phase-boundary gate: a round proves it did not weaken the
suite by showing the set of killed mutant ids is IDENTICAL before and after. That
proof is only worth something if the CORPUS is the same corpus. ``corpus.py``
lives under neither directory hashed by ``source_digest()``, so before
``corpus_digest()`` existed an entry's ``find``/``replace``/``file``/``kind``
could be edited while its ``id`` stayed put — the id-set comparison still matched,
the kill count was preserved by making the mutant EASIER to kill, and the gate
returned clean. Worse, ``sync_corpus_fields`` actively rewrote ``file``/``kind``
in an older results file from the current corpus, laundering the swap.

These tests pin the fix. They test ``corpus_digest``, ``compare`` and
``sync_corpus_fields`` DIRECTLY against synthetic results JSON, because that is
the unit under test — a real sweep is ~30 minutes of wall clock at 48 entries.

WHY THIS FILE LIVES UNDER tests/ AND NOT BESIDE run_sweep.py
------------------------------------------------------------
``pyproject.toml`` sets ``testpaths = ["tests"]``, so a file anywhere else is not
run by the project gate, and an ungated test is not a pin. Living here costs one
thing: ``tools/`` must be copied into the sweep's scratch tree, or every sweep run
errors at collection here. That is why ``run_sweep.WORKER_ENTRIES`` carries
``"tools"`` — and there is a test below that says so, because the alternative
(skip when ``tools/`` is absent) is the silent-gate-retirement the harness
docstring warns about twice.
"""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[1] / "tools" / "mutants"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import corpus  # noqa: E402
import run_sweep  # noqa: E402

CORPUS_PY = TOOLS / "corpus.py"


# ---------------------------------------------------------------------------
# Fixtures — synthetic corpora and synthetic results files
# ---------------------------------------------------------------------------


def entry(mid: str, *, file: str = "pcb_worker/drc.py", find: str = "if a and b:",
          replace: str = "if a:", kind: str = "half", **extra) -> dict:
    m = {"id": mid, "file": file, "find": find, "replace": replace, "kind": kind,
         "rationale": "synthetic"}
    m.update(extra)
    return m


def use_corpus(monkeypatch, mutants) -> None:
    monkeypatch.setattr(corpus, "MUTANTS", tuple(mutants))


def results(tmp_path: Path, name: str, mutants, *, corpus_digest: str | None,
            source_digest: str = "SRC", base_sha: str | None = None,
            **env_extra) -> Path:
    """A minimal but structurally faithful results file.

    ``base_sha`` defaults to None so ``compare`` skips the git-diff probe; the
    test that exercises that probe supplies one explicitly.
    """
    env = {"python": "3.12.4", "kicad_cli": {"present": True, "version": "9.0.9"},
           "pytest": "9.1.1", "pygerber": "2.4.3", "gerbonara": "1.6.3",
           "gerber-writer": "0.4.3.3", "base_sha": base_sha,
           "source_digest": source_digest}
    if corpus_digest is not None:
        env["corpus_digest"] = corpus_digest
    env.update(env_extra)
    payload = {
        "corpus_size": len(mutants),
        "killed_ids": sorted(m["id"] for m in mutants if m.get("killed", True)),
        "survived_ids": sorted(m["id"] for m in mutants if not m.get("killed", True)),
        "mutants": [
            {"id": m["id"], "file": m["file"], "kind": m["kind"],
             "equivalent": bool(m.get("equivalent", False)),
             "killed": bool(m.get("killed", True)), "killed_by": "assertion",
             "returncode": 1, "n_failing": 1, "n_passed": 10, "n_skipped": 0,
             "failing": ["tests/test_x.py::test_y"], "problems": []}
            for m in sorted(mutants, key=lambda e: e["id"])
        ],
    }
    path = tmp_path / name
    path.write_text(json.dumps(
        {"run_metadata": {"generated_at": "2026-01-01T00:00:00+0000",
                          "environment": env,
                          "control": {"n_passed": 10, "n_skipped": 0, "returncode": 0}},
         "payload": payload}, indent=2) + "\n")
    return path


# ---------------------------------------------------------------------------
# corpus_digest — what it covers
# ---------------------------------------------------------------------------


def test_editing_a_find_string_under_a_stable_id_changes_the_digest(monkeypatch):
    """ACCEPTANCE 1, the simple half: a retargeted `find`, same id."""
    use_corpus(monkeypatch, [entry("m1"), entry("m2", find="return x > 0")])
    before = run_sweep.corpus_digest()
    use_corpus(monkeypatch, [entry("m1"), entry("m2", find="return x >= 0")])
    assert run_sweep.corpus_digest() != before


def test_weakening_a_replace_under_a_stable_id_changes_the_digest(monkeypatch):
    """The defanging move: keep the id, make the mutant easier to kill."""
    use_corpus(monkeypatch, [entry("m1", replace="pass")])
    before = run_sweep.corpus_digest()
    use_corpus(monkeypatch, [entry("m1", replace="raise AssertionError('boom')")])
    assert run_sweep.corpus_digest() != before


def test_editing_file_or_kind_under_a_stable_id_changes_the_digest(monkeypatch):
    use_corpus(monkeypatch, [entry("m1")])
    before = run_sweep.corpus_digest()
    use_corpus(monkeypatch, [entry("m1", file="pcb_worker/gerber.py")])
    assert run_sweep.corpus_digest() != before
    use_corpus(monkeypatch, [entry("m1", kind="full")])
    assert run_sweep.corpus_digest() != before


def test_swapping_two_entries_semantics_under_stable_ids_changes_the_digest(monkeypatch):
    """THE DISCRIMINATING FIXTURE for acceptance 1.

    Two entries EXCHANGE their file/find/replace/kind while both ids stay put.
    Nothing is added, nothing is removed, and the multiset of semantics present in
    the corpus is bit-for-bit the SAME — only the id each one is bound to moved.

    A digest that hashes the sorted semantics WITHOUT binding each tuple to its
    own id is identical across this swap, and so is one that hashes entries in
    file order rather than id order. Both pass every single-field-edit test above.
    This is the case that separates them.
    """
    a = dict(file="pcb_worker/drc.py", find="if a and b:", replace="if a:", kind="half")
    b = dict(file="pcb_worker/gerber.py", find="return n", replace="return 0", kind="full")

    use_corpus(monkeypatch, [entry("m1", **a), entry("m2", **b)])
    before = run_sweep.corpus_digest()
    use_corpus(monkeypatch, [entry("m1", **b), entry("m2", **a)])
    after = run_sweep.corpus_digest()

    assert after != before, (
        "two entries exchanged semantics under stable ids and the digest did not "
        "move — the digest is not binding semantics to the id that owns them")


def test_renaming_an_id_alone_changes_the_digest(monkeypatch):
    """The id is hashed INSIDE each entry's tuple, not merely used as the sort key.

    Measured, not assumed: with entries sorted by id, dropping the id from the
    hashed tuple still catches the swap above (the byte stream reorders), so the
    swap test alone leaves that weakening alive. This fixture is what kills it.

    At the gate this is belt AND braces — a renamed id is already refused by the
    id-set comparison in ``compare()``. It is kept because the digest's claim is
    "these semantics under THESE ids", and because the moment somebody changes the
    sort key to anything content-derived, the id in the tuple becomes the only
    thing standing between the digest and a semantics swap it cannot see.
    """
    use_corpus(monkeypatch, [entry("aaa"), entry("bbb", find="return x > 0")])
    before = run_sweep.corpus_digest()
    # Same semantics, same sorted position, one id renamed.
    use_corpus(monkeypatch, [entry("aaa"), entry("ccc", find="return x > 0")])
    assert run_sweep.corpus_digest() != before


def test_reordering_the_corpus_does_not_change_the_digest(monkeypatch):
    """Entry order in the file is cosmetic (build_payload sorts by id anyway), so
    it must not void a comparison. This is what forces the sort-by-id, which the
    swap test above then makes non-negotiable."""
    a, b = entry("m1"), entry("m2", find="return x > 0")
    use_corpus(monkeypatch, [a, b])
    before = run_sweep.corpus_digest()
    use_corpus(monkeypatch, [b, a])
    assert run_sweep.corpus_digest() == before


def test_text_moved_across_a_field_boundary_changes_the_digest(monkeypatch):
    """Concatenating fields without framing lets the tail of `find` migrate into
    the head of `replace` for free. Length prefixes forbid it."""
    use_corpus(monkeypatch, [entry("m1", find="abc", replace="def")])
    before = run_sweep.corpus_digest()
    use_corpus(monkeypatch, [entry("m1", find="ab", replace="cdef")])
    assert run_sweep.corpus_digest() != before


def test_an_unknown_field_is_refused_rather_than_silently_unhashed(monkeypatch):
    """The digest is an ALLOW-LIST, so a field added later is invisible to it —
    which would reopen the fail-open silently. It must refuse instead."""
    use_corpus(monkeypatch, [entry("m1", second_replace="if False:")])
    with pytest.raises(run_sweep.HarnessError) as exc:
        run_sweep.corpus_digest()
    assert "second_replace" in str(exc.value)
    assert "m1" in str(exc.value)


def test_a_non_string_semantic_field_is_refused(monkeypatch):
    use_corpus(monkeypatch, [entry("m1", kind=("half",))])
    with pytest.raises(run_sweep.HarnessError):
        run_sweep.corpus_digest()


# ---------------------------------------------------------------------------
# corpus_digest — what it deliberately does NOT cover
# ---------------------------------------------------------------------------


def test_marking_an_entry_equivalent_does_not_change_the_digest(monkeypatch):
    """ACCEPTANCE 2. Equivalence is established AFTER a mutant survives, by
    probing it. If annotating a survivor voided every comparison, the annotation
    workflow would break and somebody would delete the check."""
    use_corpus(monkeypatch, [entry("m1"), entry("m2")])
    before = run_sweep.corpus_digest()
    use_corpus(monkeypatch, [
        entry("m1"),
        entry("m2", equivalent=True, equivalent_reason="both branches are no-ops")])
    assert run_sweep.corpus_digest() == before


def test_absent_and_explicit_false_equivalent_digest_identically(monkeypatch):
    """`equivalent` is optional (`bool(src.get("equivalent", False))`), so writing
    it out explicitly as False must not void anything."""
    use_corpus(monkeypatch, [entry("m1")])
    before = run_sweep.corpus_digest()
    use_corpus(monkeypatch, [entry("m1", equivalent=False)])
    assert run_sweep.corpus_digest() == before


def test_editing_rationale_prose_does_not_change_the_digest(monkeypatch):
    use_corpus(monkeypatch, [entry("m1", rationale="one sentence")])
    before = run_sweep.corpus_digest()
    use_corpus(monkeypatch, [entry("m1", rationale="a much longer explanation")])
    assert run_sweep.corpus_digest() == before


def test_editing_only_comments_in_the_real_corpus_py_does_not_change_the_digest():
    """ACCEPTANCE 4, against the REAL corpus.py rather than a synthetic stand-in.

    This is the test the lazy fix fails: hashing ``corpus.py``'s bytes makes a
    docstring or comment edit void every comparison, and a check that cries wolf
    on harmless edits is a check somebody disables.
    """
    src = CORPUS_PY.read_text()
    edited = src.replace('"""The FIXED mutant corpus',
                         '"""EDITED PROSE, NO SEMANTIC CHANGE. The FIXED mutant corpus',
                         1)
    edited += "\n# a trailing comment added by test_mutation_harness.py\n"
    assert edited != src, "the prose edit did not apply; this test would be vacuous"
    assert edited.encode() != src.encode()

    namespace: dict = {"__name__": "corpus_prose_edited", "__file__": str(CORPUS_PY)}
    exec(compile(edited, str(CORPUS_PY), "exec"), namespace)  # noqa: S102

    class Shim:
        MUTANTS = tuple(namespace["MUTANTS"])

    real = run_sweep.corpus_digest()
    saved = run_sweep.corpus
    try:
        run_sweep.corpus = Shim  # type: ignore[assignment]
        assert run_sweep.corpus_digest() == real
    finally:
        run_sweep.corpus = saved

    # And the same machinery DOES move when a real entry's semantics change,
    # so the equality above is not equality-by-doing-nothing.
    class Tampered:
        MUTANTS = tuple(
            {**m, "replace": m["replace"] + "  # defanged"} if i == 0 else m
            for i, m in enumerate(namespace["MUTANTS"]))

    try:
        run_sweep.corpus = Tampered  # type: ignore[assignment]
        assert run_sweep.corpus_digest() != real
    finally:
        run_sweep.corpus = saved


def test_the_real_corpus_digests_deterministically():
    assert run_sweep.corpus_digest() == run_sweep.corpus_digest()
    assert len(run_sweep.corpus_digest()) == 64


# ---------------------------------------------------------------------------
# environment() records it
# ---------------------------------------------------------------------------


def test_environment_records_the_corpus_digest(monkeypatch):
    """Computing the digest and never recording it is a no-op fix."""
    monkeypatch.setattr(run_sweep, "VENV_PYTHON", Path(sys.executable))
    monkeypatch.setattr(run_sweep, "_pkg_version", lambda name: "0")
    monkeypatch.setattr(run_sweep, "_kicad_cli", lambda: {"present": False, "version": None})
    monkeypatch.setattr(run_sweep, "repo_head", lambda: "deadbeef")
    monkeypatch.setattr(run_sweep, "source_digest", lambda: "SRC")
    env = run_sweep.environment()
    assert env["corpus_digest"] == run_sweep.corpus_digest()


# ---------------------------------------------------------------------------
# compare() — the gate
# ---------------------------------------------------------------------------


def test_compare_passes_on_two_identical_runs(tmp_path, monkeypatch):
    """The control for every refusal test below: without this, a compare() that
    refused unconditionally would satisfy all of them."""
    use_corpus(monkeypatch, [entry("m1"), entry("m2")])
    d = run_sweep.corpus_digest()
    mutants = [entry("m1"), entry("m2")]
    before = results(tmp_path, "before.json", mutants, corpus_digest=d)
    after = results(tmp_path, "after.json", mutants, corpus_digest=d)
    assert run_sweep.compare(before, after) == 0


def test_compare_refuses_when_the_corpus_digest_differs(tmp_path, monkeypatch, capsys):
    """ACCEPTANCE 1, end to end: the tampered corpus reaches the gate and the gate
    refuses, loudly, naming the corpus."""
    use_corpus(monkeypatch, [entry("m1"), entry("m2")])
    mutants = [entry("m1"), entry("m2")]
    before = results(tmp_path, "before.json", mutants, corpus_digest="DIGEST-OF-THE-HONEST-CORPUS")
    after = results(tmp_path, "after.json", mutants, corpus_digest="DIGEST-OF-THE-TAMPERED-CORPUS")

    assert run_sweep.compare(before, after) == 2
    out = capsys.readouterr().out
    assert "COMPARISON REFUSED" in out
    assert "corpus_digest" in out
    assert "void" in out


def test_compare_refuses_when_a_results_file_records_no_corpus_digest(tmp_path, monkeypatch, capsys):
    """Fail CLOSED on absence. Treating "absent" as "fine" is the same fail-open
    one level up: every pre-fix results file would sail through."""
    use_corpus(monkeypatch, [entry("m1")])
    d = run_sweep.corpus_digest()
    mutants = [entry("m1")]
    old = results(tmp_path, "old.json", mutants, corpus_digest=None)
    new = results(tmp_path, "new.json", mutants, corpus_digest=d)

    assert run_sweep.compare(old, new) == 2
    assert "corpus_digest" in capsys.readouterr().out
    # ...in EITHER position.
    assert run_sweep.compare(new, old) == 2
    assert "corpus_digest" in capsys.readouterr().out


def test_compare_refuses_when_an_empty_corpus_digest_is_recorded(tmp_path, monkeypatch):
    """An empty string is absence wearing a hat."""
    use_corpus(monkeypatch, [entry("m1")])
    mutants = [entry("m1")]
    a = results(tmp_path, "a.json", mutants, corpus_digest="")
    b = results(tmp_path, "b.json", mutants, corpus_digest="")
    assert run_sweep.compare(a, b) == 2


def test_compare_ignores_an_equivalence_flip(tmp_path, monkeypatch, capsys):
    """ACCEPTANCE 2, end to end. Marking a survivor equivalent must NOT void the
    comparison — the digest excludes it and the payload field is not a kill."""
    use_corpus(monkeypatch, [entry("m1"), entry("m2")])
    d = run_sweep.corpus_digest()
    before = results(tmp_path, "before.json",
                     [entry("m1"), entry("m2", killed=False)], corpus_digest=d)
    after = results(tmp_path, "after.json",
                    [entry("m1"), entry("m2", killed=False, equivalent=True)],
                    corpus_digest=d)
    assert run_sweep.compare(before, after) == 0
    assert "PASS" in capsys.readouterr().out


def test_compare_still_refuses_on_differing_id_sets(tmp_path, monkeypatch, capsys):
    """ACCEPTANCE 5 — the pre-existing guard for added/removed entries."""
    use_corpus(monkeypatch, [entry("m1")])
    d = run_sweep.corpus_digest()
    before = results(tmp_path, "before.json", [entry("m1")], corpus_digest=d)
    after = results(tmp_path, "after.json", [entry("m1"), entry("m2")], corpus_digest=d)
    assert run_sweep.compare(before, after) == 2
    assert "different mutant ids" in capsys.readouterr().out


def test_compare_still_refuses_on_a_differing_source_digest(tmp_path, monkeypatch, capsys):
    """ACCEPTANCE 5."""
    use_corpus(monkeypatch, [entry("m1")])
    d = run_sweep.corpus_digest()
    mutants = [entry("m1")]
    before = results(tmp_path, "before.json", mutants, corpus_digest=d, source_digest="AAA")
    after = results(tmp_path, "after.json", mutants, corpus_digest=d, source_digest="BBB")
    assert run_sweep.compare(before, after) == 2
    assert "source_digest" in capsys.readouterr().out


def test_compare_still_refuses_on_environment_drift(tmp_path, monkeypatch, capsys):
    """ACCEPTANCE 5. ~15 oracle tests are skipif(kicad-cli); a skipped test kills
    nothing, so the same corpus scores differently on a machine without it."""
    use_corpus(monkeypatch, [entry("m1")])
    d = run_sweep.corpus_digest()
    mutants = [entry("m1")]
    before = results(tmp_path, "before.json", mutants, corpus_digest=d)
    after = results(tmp_path, "after.json", mutants, corpus_digest=d,
                    kicad_cli={"present": False, "version": None})
    assert run_sweep.compare(before, after) == 2
    assert "kicad_cli" in capsys.readouterr().out


def test_compare_still_refuses_on_a_bad_base_sha_git_probe(tmp_path, monkeypatch, capsys):
    """ACCEPTANCE 5. The git-diff probe against the recorded base SHA still runs
    and still fatals — the corpus checks are additive, not a replacement."""
    use_corpus(monkeypatch, [entry("m1")])
    d = run_sweep.corpus_digest()
    mutants = [entry("m1")]
    sha = "0" * 40
    before = results(tmp_path, "before.json", mutants, corpus_digest=d, base_sha=sha)
    after = results(tmp_path, "after.json", mutants, corpus_digest=d, base_sha=sha)
    assert run_sweep.compare(before, after) == 2
    assert "baseline SHA" in capsys.readouterr().out


def test_compare_still_reports_a_changed_kill_set_as_one_not_two(tmp_path, monkeypatch, capsys):
    """The exit codes are a contract: 2 = refusal, 1 = the kill set moved, 0 = pass.
    Callers branch on them."""
    use_corpus(monkeypatch, [entry("m1")])
    d = run_sweep.corpus_digest()
    before = results(tmp_path, "before.json", [entry("m1", killed=True)], corpus_digest=d)
    after = results(tmp_path, "after.json", [entry("m1", killed=False)], corpus_digest=d)
    assert run_sweep.compare(before, after) == 1
    assert "LOST KILL" in capsys.readouterr().out


# ---------------------------------------------------------------------------
# sync_corpus_fields() — may only touch what the digest excludes
# ---------------------------------------------------------------------------


def test_sync_refuses_a_kind_mismatch_and_names_the_entry(tmp_path, monkeypatch):
    """ACCEPTANCE 3. `kind` is inside the digest, so correcting it here would
    launder a same-id semantic swap into a clean comparison. Note the sharpest
    case: canary -> full would excuse a canary that stopped being killed, and the
    surviving canary is the signal that the whole matrix is void."""
    use_corpus(monkeypatch, [entry("m1", kind="full")])
    path = results(tmp_path, "r.json", [entry("m1", kind="half")],
                   corpus_digest=run_sweep.corpus_digest())
    original = path.read_text()

    with pytest.raises(run_sweep.HarnessError) as exc:
        run_sweep.sync_corpus_fields(path)
    message = str(exc.value)
    assert "m1" in message
    assert "kind" in message
    assert path.read_text() == original, "refusal must not have rewritten the file"


def test_sync_refuses_a_file_mismatch_and_names_the_entry(tmp_path, monkeypatch):
    """ACCEPTANCE 3."""
    use_corpus(monkeypatch, [entry("m1", file="pcb_worker/gerber.py")])
    path = results(tmp_path, "r.json", [entry("m1", file="pcb_worker/drc.py")],
                   corpus_digest=run_sweep.corpus_digest())
    original = path.read_text()

    with pytest.raises(run_sweep.HarnessError) as exc:
        run_sweep.sync_corpus_fields(path)
    message = str(exc.value)
    assert "m1" in message
    assert "file" in message
    assert "drc.py" in message and "gerber.py" in message
    assert path.read_text() == original


def test_sync_refuses_when_the_recorded_corpus_digest_no_longer_matches(tmp_path, monkeypatch):
    """A `find`/`replace` edit is invisible to the per-entry check — results files
    do not carry those fields — so the recorded digest is the layer that catches
    it. Without this, sync would happily rewrite a file the corpus can no longer
    reproduce."""
    use_corpus(monkeypatch, [entry("m1")])
    path = results(tmp_path, "r.json", [entry("m1")], corpus_digest="STALE-DIGEST")
    original = path.read_text()

    with pytest.raises(run_sweep.HarnessError) as exc:
        run_sweep.sync_corpus_fields(path)
    assert "corpus_digest" in str(exc.value)
    assert path.read_text() == original


def test_sync_applies_an_equivalence_flip_and_reports_it_distinctly(tmp_path, monkeypatch, capsys):
    """The legitimate workflow, preserved — and made VISIBLE, because flipping
    `equivalent` to true EXCUSES a survivor and that is a claim a reader must see
    rather than have buried in a generic "synced N static field(s)" line."""
    use_corpus(monkeypatch, [
        entry("m1"),
        entry("m2", equivalent=True, equivalent_reason="both branches are no-ops")])
    path = results(tmp_path, "r.json",
                   [entry("m1"), entry("m2", killed=False)],
                   corpus_digest=run_sweep.corpus_digest())

    assert run_sweep.sync_corpus_fields(path) == 0
    out = capsys.readouterr().out
    assert "EQUIVALENCE ANNOTATION CHANGED" in out
    assert "m2" in out
    assert "EXCUSED" in out
    assert "m1" not in out.split("EQUIVALENCE ANNOTATION CHANGED")[1]

    data = json.loads(path.read_text())
    by_id = {m["id"]: m for m in data["payload"]["mutants"]}
    assert by_id["m2"]["equivalent"] is True
    assert by_id["m1"]["equivalent"] is False
    assert data["payload"]["equivalent_ids"] == ["m2"]


def test_sync_reports_a_re_armed_entry_distinctly_from_an_excused_one(tmp_path, monkeypatch, capsys):
    """true -> false is the SAFE direction (a survivor starts counting again), so
    it is allowed — but it is still a change of meaning and still gets a line."""
    use_corpus(monkeypatch, [entry("m1")])
    path = results(tmp_path, "r.json", [entry("m1", killed=False, equivalent=True)],
                   corpus_digest=run_sweep.corpus_digest())
    assert run_sweep.sync_corpus_fields(path) == 0
    out = capsys.readouterr().out
    assert "RE-ARMED" in out
    assert "EXCUSED" not in out


def test_sync_never_touches_run_results(tmp_path, monkeypatch):
    use_corpus(monkeypatch, [entry("m1", equivalent=True)])
    path = results(tmp_path, "r.json", [entry("m1", killed=False)],
                   corpus_digest=run_sweep.corpus_digest())
    before = copy.deepcopy(json.loads(path.read_text())["payload"]["mutants"][0])

    run_sweep.sync_corpus_fields(path)
    after = json.loads(path.read_text())["payload"]["mutants"][0]
    for key in ("killed", "killed_by", "failing", "returncode", "n_failing",
                "n_passed", "n_skipped"):
        assert after[key] == before[key]


def test_sync_warns_but_proceeds_on_a_file_that_predates_fingerprinting(tmp_path, monkeypatch, capsys):
    """compare() is the GATE and fail-closes on a missing digest. sync is a
    maintenance action, not a gate, so refusing here would buy no safety and would
    strand the annotation workflow on every pre-fix results file. It says what it
    cannot check instead of implying it checked."""
    use_corpus(monkeypatch, [entry("m1", equivalent=True)])
    path = results(tmp_path, "r.json", [entry("m1", killed=False)], corpus_digest=None)
    assert run_sweep.sync_corpus_fields(path) == 0
    out = capsys.readouterr().out
    assert "predates corpus fingerprinting" in out
    assert json.loads(path.read_text())["payload"]["mutants"][0]["equivalent"] is True


def test_sync_never_stamps_a_digest_into_a_file_that_lacks_one(tmp_path, monkeypatch):
    """Backfilling the digest would manufacture evidence: it would assert the old
    run used today's corpus, which is exactly what nobody can know."""
    use_corpus(monkeypatch, [entry("m1")])
    path = results(tmp_path, "r.json", [entry("m1")], corpus_digest=None)
    run_sweep.sync_corpus_fields(path)
    env = json.loads(path.read_text())["run_metadata"]["environment"]
    assert "corpus_digest" not in env


def test_sync_still_refuses_an_unknown_mutant_id(tmp_path, monkeypatch):
    use_corpus(monkeypatch, [entry("m1")])
    path = results(tmp_path, "r.json", [entry("m1"), entry("ghost")],
                   corpus_digest=run_sweep.corpus_digest())
    with pytest.raises(run_sweep.HarnessError) as exc:
        run_sweep.sync_corpus_fields(path)
    assert "ghost" in str(exc.value)


# ---------------------------------------------------------------------------
# attribution() — prose derived, not typed
# ---------------------------------------------------------------------------


def test_attribution_derives_its_corpus_summary_from_the_results_file(tmp_path, monkeypatch, capsys):
    """That sentence read "30 defect shapes across 9 modules" long after the corpus
    reached 48 across 11 target files. Prose is the one artifact with no gate, so
    this is the gate."""
    use_corpus(monkeypatch, [entry("m1"), entry("m2"), entry("m3")])
    path = results(tmp_path, "r.json", [
        entry("m1", file="pcb_worker/drc.py"),
        entry("m2", file="pcb_worker/gerber.py"),
        entry("m3", file="pcb_worker/gerber.py")],
        corpus_digest=run_sweep.corpus_digest())
    assert run_sweep.attribution(path) == 0
    out = capsys.readouterr().out
    assert "3 defect shapes" in out
    assert "2 target file(s)" in out
    assert "30 defect shapes" not in out
    assert "9 modules" not in out


# ---------------------------------------------------------------------------
# The scratch-tree contract this file depends on
# ---------------------------------------------------------------------------


def test_the_sweep_copies_tools_into_the_scratch_tree():
    """This file imports tools/mutants/, and the sweep runs the whole suite from a
    scratch COPY. Drop "tools" from WORKER_ENTRIES and every sweep run — control
    included — errors at collection here; a red control makes every mutant look
    killed, and you find out half an hour into a sweep. Cheap early detection."""
    assert "tools" in run_sweep.WORKER_ENTRIES

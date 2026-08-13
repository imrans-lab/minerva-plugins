"""The BOARD's own library lock (acceptance check K20, DCR 019ffc52c358).

WHAT THIS IS FOR, and why the layer chain's existing sha check does not cover
it. resolve_footprint_layered already verifies that a footprint FILE matches
its own layer's lockfile — that is integrity of a library against itself. K20
asks a different question: is this the content THIS BOARD consumed? Since the
library became layered, a user layer may legitimately override a seed part
under the same name. That is a feature. It also means a board rebuilt months
later can resolve the same names to different copper with nothing saying so,
and closing that is what board-level pinning is for.

Each test names the mutation it is designed to fail against.
"""

from __future__ import annotations

from pcb_worker.compile_board import compile_board
from pcb_worker.methods import handle_request
from pcb_worker.footprints import (DEFAULT_LOCKFILE, SEED_LAYER,
                                   load_lockfile)
from pcb_worker.resolved_board import DiagnosticSeverity

SEEDED_REF = "Package_DIP:DIP-6_W7.62mm_Socket"


def _board(ref: str, lock: dict | None = None) -> dict:
    board = {
        "version": 1, "name": "lock", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "X1", "footprint": ref, "x_mm": 10, "y_mm": 10,
                        "rotation_deg": 0, "layer": "top"}],
    }
    if lock is not None:
        board["library_lock"] = lock
    return board


def _codes(result) -> list:
    return [d.code for d in result.diagnostics
            if d.severity is DiagnosticSeverity.ERROR]


def _seed_sha(ref: str) -> str:
    return str(load_lockfile(DEFAULT_LOCKFILE)[ref]["sha256"])


def test_an_unlocked_board_compiles_exactly_as_before():
    """MUTATION THIS CATCHES: making the lock a precondition rather than
    something a board GAINS. Every board in existence predates this field; if
    its absence started refusing compiles, the feature would have broken the
    entire corpus to guard against a hypothetical."""
    result = compile_board(_board(SEEDED_REF))
    assert "library_lock_mismatch" not in _codes(result)
    assert "footprint_pinned_but_missing" not in _codes(result)


def test_a_matching_pin_compiles():
    """MUTATION THIS CATCHES: comparing the wrong pair of values (for instance
    the board's sha against the FILE's path, or against a re-hashed parse). A
    lock that refuses the very content it recorded is worse than no lock —
    it would train users to delete the block."""
    board = _board(SEEDED_REF, {SEEDED_REF: {"sha256": _seed_sha(SEEDED_REF)}})
    result = compile_board(board)
    assert "library_lock_mismatch" not in _codes(result)


def test_a_mismatched_pin_REFUSES():
    """MUTATION THIS CATCHES: dropping the comparison, or downgrading it to a
    warning. This is the whole check: a board pinned to content A, resolving to
    content B, must STOP. Resolving anyway with a note is the false-clean K20
    exists to forbid — fabrication would proceed on copper the board never
    approved."""
    board = _board(SEEDED_REF, {SEEDED_REF: {"sha256": "0" * 64}})
    result = compile_board(board)
    assert "library_lock_mismatch" in _codes(result)


def test_the_refusal_names_both_shas_and_the_supplying_layer():
    """MUTATION THIS CATCHES: refusing without saying what happened. "Lock
    mismatch" alone is unactionable; the user cannot tell which part moved, what
    it was pinned to, or which layer is now winning."""
    board = _board(SEEDED_REF, {SEEDED_REF: {"sha256": "0" * 64}})
    result = compile_board(board)
    msg = " ".join(d.message for d in result.diagnostics
                   if d.code == "library_lock_mismatch")
    assert "0000" in msg                      # what it was pinned to
    assert _seed_sha(SEEDED_REF)[:8] in msg   # what it actually got
    assert SEED_LAYER in msg                  # which layer supplied it


def test_a_pinned_but_missing_ref_says_what_it_was_pinned_to():
    """MUTATION THIS CATCHES: falling through to the generic
    footprint_unresolved path when a pin exists. The board knows exactly which
    bytes it wants; reporting only "name not found" throws that away and leaves
    the user guessing which of several same-named parts was meant."""
    board = _board("No_Such_Lib:No_Such_Part",
                   {"No_Such_Lib:No_Such_Part": {"sha256": "a" * 64,
                                                 "source": "acme-parts-v3.zip"}})
    result = compile_board(board)
    codes = _codes(result)
    assert "footprint_pinned_but_missing" in codes
    assert "footprint_unresolved" not in codes
    msg = " ".join(d.message for d in result.diagnostics
                   if d.code == "footprint_pinned_but_missing")
    assert "acme-parts-v3.zip" in msg


def test_a_pin_for_an_UNUSED_ref_cannot_invalidate_the_board():
    """MUTATION THIS CATCHES: verifying the whole lock block instead of the
    refs the board actually resolves. That is the whole-chain-digest failure
    mode: the board goes red when anything anywhere moves, and everyone learns
    to regenerate the lock without reading it."""
    board = _board(SEEDED_REF, {
        SEEDED_REF: {"sha256": _seed_sha(SEEDED_REF)},
        "Some_Other:Part_This_Board_Does_Not_Use": {"sha256": "b" * 64},
    })
    result = compile_board(board)
    assert "library_lock_mismatch" not in _codes(result)
    assert "footprint_pinned_but_missing" not in _codes(result)


def test_a_malformed_lock_block_does_not_brick_the_board():
    """MUTATION THIS CATCHES: refusing to compile when the optional provenance
    block is unreadable. Turning a bad edit to metadata into an unbuildable
    board is a worse failure than the one the lock guards against, so an
    unreadable block yields NO pins rather than a refusal."""
    for bad in ("not a dict", ["also", "not"], {SEEDED_REF: "not an entry"}):
        result = compile_board(_board(SEEDED_REF, bad))  # type: ignore[arg-type]
        assert "library_lock_mismatch" not in _codes(result), bad


# ── the verb that WRITES a lock (minerva_pcb_lock_libraries) ─────────────────

def _lock(board: dict) -> dict:
    resp = handle_request({"id": "lk", "method": "lock_libraries",
                           "params": {"board": board}})
    assert resp["ok"] is True, resp
    return resp["result"]


def test_locking_pins_the_footprints_the_board_actually_uses():
    """MUTATION THIS CATCHES: pinning nothing, or pinning a value that is not
    the resolved content's sha. A lock block that does not match what resolution
    returns is worse than absent — the very next compile refuses a board nobody
    changed."""
    result = _lock(_board(SEEDED_REF))
    assert result["locked"] == [SEEDED_REF]
    assert result["board"]["library_lock"][SEEDED_REF]["sha256"] == _seed_sha(SEEDED_REF)
    assert result["board"]["library_lock"][SEEDED_REF]["layer"] == SEED_LAYER


def test_a_freshly_locked_board_compiles_without_a_mismatch():
    """THE END-TO-END PROPERTY, and the one worth most: lock, then build. If the
    writer and the verifier disagree about ANYTHING — which sha, which layer,
    which refs — this fails, and no amount of agreement between either half and
    a fixture would save it. MUTATION THIS CATCHES: any drift between the two
    halves of the feature."""
    locked = _lock(_board(SEEDED_REF))["board"]
    result = compile_board(locked)
    assert "library_lock_mismatch" not in _codes(result)
    assert "footprint_pinned_but_missing" not in _codes(result)


def test_relocking_REPLACES_rather_than_merging():
    """MUTATION THIS CATCHES: merging the new pins into the old block. A pin for
    a part the board no longer uses would then survive forever, and the block
    would slowly stop describing this board at all — which is the only thing it
    is for."""
    stale = _board(SEEDED_REF, {
        SEEDED_REF: {"sha256": _seed_sha(SEEDED_REF)},
        "Ghost_Lib:Part_Long_Since_Removed": {"sha256": "c" * 64},
    })
    relocked = _lock(stale)["board"]["library_lock"]
    assert SEEDED_REF in relocked
    assert "Ghost_Lib:Part_Long_Since_Removed" not in relocked


def test_an_unpinnable_footprint_is_NAMED_not_silently_skipped():
    """MUTATION THIS CATCHES: dropping refs no layer supplies. A caller reading
    only `locked` would believe the board fully pinned when part of it is not —
    the same partial-honesty failure the fab preview's `unrendered` list exists
    to prevent."""
    result = _lock(_board("No_Such_Lib:No_Such_Part"))
    assert result["locked"] == []
    assert [u["ref"] for u in result["unresolved"]] == ["No_Such_Lib:No_Such_Part"]
    assert result["unresolved"][0]["reason"].strip()


def test_locking_does_not_mutate_the_caller_s_board():
    """MUTATION THIS CATCHES: writing the lock into the input dict. The method
    advertises itself as PURE, and a caller that passed a board it still holds
    would find it silently changed underneath — the kind of aliasing bug that
    surfaces three layers away from its cause."""
    original = _board(SEEDED_REF)
    _lock(original)
    assert "library_lock" not in original

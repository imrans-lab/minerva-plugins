"""Shared canonical-board validation boundary — Python side.

Mirror of ``internal/board/validate.go``. Enforces the schema-level rules the Go
codec and this validator must agree on (item 019f802ca3af, comment 629 — "K3 must
not consume a v2 board through independently drifting validators"): schema-version
dispatch, v2 persistent-id validity, and typed pin-override field types (which the
Go codec enforces structurally at unmarshal, and this validator — parsing an
untyped dict — re-checks explicitly).

It operates on a PARSED board dict and does NOT resolve footprints or geometry —
that is the full compiler (compile_board.py). The committed vectors in
``pcb/spec/vectors/`` are loaded and asserted identically on both sides; the error
codes here match ``internal/board.Validate`` verbatim. The minted-id predicate is
shared with the compiler (``_is_minted_id``) so the two Python paths cannot drift.
"""
from __future__ import annotations

# Reuse the compiler's shared predicates AND the override-key list so the two
# Python paths cannot drift (the minted-id definition and the override field set
# have exactly one source of truth).
from .compile_board import _OVERRIDE_NUM_KEYS, _is_minted_id, _is_number

_V2_ENTITIES = (("trace", "traces"), ("via", "vias"), ("hole", "mounting_holes"))


def validate_board_v2(board: dict) -> list[str]:
    """Return a list of shared-boundary error codes; an empty list means the board
    is valid at this boundary. Codes are identical to ``internal/board.Validate``:
    ``unsupported_schema_version``, ``unminted_persistent_id``, ``invalid_pin_override``,
    ``invalid_board_structure``.
    """
    if not isinstance(board, dict):
        return ["invalid_board_structure"]
    version = board.get("version")
    # bool is a subclass of int — exclude it explicitly (as _is_number does).
    if type(version) is not int or version not in (1, 2):
        return ["unsupported_schema_version"]

    codes: list[str] = []
    if version >= 2:
        if not _is_minted_id("board", board.get("id")):
            codes.append("unminted_persistent_id")
        for entity, key in _V2_ENTITIES:
            items, ok = _as_list(board.get(key))
            if not ok:
                codes.append("invalid_board_structure")
                continue
            for item in items:
                if item is None:
                    continue  # yaml.v3 drops a null list item before Go sees it;
                    # skip here too so the two codecs agree (Fable Round D, D2)
                if not isinstance(item, dict) or not _is_minted_id(entity, item.get("id")):
                    codes.append("unminted_persistent_id")
                    break

    comps, ok = _as_list(board.get("components"))
    if not ok:
        codes.append("invalid_board_structure")
        comps = []
    for comp in comps:
        if not isinstance(comp, dict):
            continue
        pins, ok = _as_list(comp.get("pins"))
        if not ok:
            codes.append("invalid_board_structure")
            continue
        for pin in pins:
            if isinstance(pin, dict):
                codes.extend(_override_problems(pin.get("override")))
    return codes


def _as_list(value):
    """Return (items, ok). An absent/null container is an empty list (ok). A present
    NON-list container — a mapping (``traces: {}``) or scalar (``traces: 5``) — is a
    structural violation the Go codec rejects at unmarshal (a mapping/scalar cannot
    decode into a slice), and iterating it would crash this validator; return
    ([], False) so the caller records it. Keeps the two codecs aligned on container
    shape (Fable Round D confirmation)."""
    if value is None:
        return [], True
    if isinstance(value, list):
        return value, True
    return [], False


def _override_problems(override) -> list[str]:
    if override is None:
        return []
    if not isinstance(override, dict):
        return ["invalid_pin_override"]
    problems: list[str] = []
    for key in _OVERRIDE_NUM_KEYS:
        val = override.get(key)
        if val is not None and not _is_number(val):
            problems.append("invalid_pin_override")
    plated = override.get("plated")
    if plated is not None and not isinstance(plated, bool):
        problems.append("invalid_pin_override")
    return problems

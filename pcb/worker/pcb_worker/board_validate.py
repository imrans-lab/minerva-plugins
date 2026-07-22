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

from .compile_board import _is_minted_id, _is_number

# Numeric keys of a typed pin override; ``plated`` is a separate boolean. Mirrors
# compile_board._OVERRIDE_NUM_KEYS and the Go PinOverride *float64 fields.
_OVERRIDE_NUM_KEYS = ("drill_mm", "annulus_diameter_mm", "pad_width_mm", "pad_height_mm")

_V2_ENTITIES = (("trace", "traces"), ("via", "vias"), ("hole", "mounting_holes"))


def validate_board_v2(board: dict) -> list[str]:
    """Return a list of shared-boundary error codes; an empty list means the board
    is valid at this boundary. Codes are identical to ``internal/board.Validate``:
    ``unsupported_schema_version``, ``unminted_persistent_id``, ``invalid_pin_override``.
    """
    version = board.get("version")
    # bool is a subclass of int — exclude it explicitly (as _is_number does).
    if type(version) is not int or version not in (1, 2):
        return ["unsupported_schema_version"]

    codes: list[str] = []
    if version >= 2:
        if not _is_minted_id("board", board.get("id")):
            codes.append("unminted_persistent_id")
        for entity, key in _V2_ENTITIES:
            for item in board.get(key) or []:
                if not isinstance(item, dict) or not _is_minted_id(entity, item.get("id")):
                    codes.append("unminted_persistent_id")
                    break

    for comp in board.get("components") or []:
        if not isinstance(comp, dict):
            continue
        for pin in comp.get("pins") or []:
            if isinstance(pin, dict):
                codes.extend(_override_problems(pin.get("override")))
    return codes


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

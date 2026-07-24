"""Neutral schema-boundary primitives shared by the canonical-board validator
(:mod:`board_validate`) and the full compiler (:mod:`compile_board`).

These are the definitions the Go codec (``internal/board``) and BOTH Python paths
must agree on: the minted-id shape, the finite-number predicate, the typed
pin-override numeric field set, and the shared diagnostic code→message table.

Housed in a dependency-free module so the validator and the compiler each import
it NORMALLY — no import cycle, no lazy in-function import (finding 019f88bac172,
Codex checkpoint @ aa2ef0f: "one authority, no lazy circular import"). Previously
``board_validate`` imported these privates from ``compile_board`` and the compiler
lazily imported ``board_validate`` back to survive the cycle; the neutral module
inverts nothing and both dependents point here.
"""
from __future__ import annotations

import math

_MINTED_HEX_LEN = 32  # 128-bit mint → 32 lowercase hex chars


def _is_number(value) -> bool:
    return (not isinstance(value, bool) and isinstance(value, (int, float))
            and math.isfinite(value))


def _is_minted_id(entity: str, value) -> bool:
    """True iff ``value`` is a well-formed minted id ``"<entity>:<32 lc hex>"`` —
    byte-for-byte the shape the Go v1→v2 migration writes (migrate.go
    ``isMintedID``).  Anything else (absent, a legacy ordinal-shaped ``trace_1``,
    a foreign shape) is UNMINTED, which for a v2 board is fatal."""
    if not isinstance(value, str):
        return False
    prefix = entity + ":"
    if len(value) != len(prefix) + _MINTED_HEX_LEN:
        return False
    if not value.startswith(prefix):
        return False
    return all(c in "0123456789abcdef" for c in value[len(prefix):])


# Numeric keys of a typed pin `override` (schema-v2 sanctioned deviation); `plated`
# is a separate boolean.  Type-checked at the shared boundary — matching the Go
# PinOverride codec, which rejects wrong types at unmarshal.  Value-range semantics
# belong to the shared board-v2 spec (Round D), enforced identically on both sides
# to avoid validator drift (comment 629).
_OVERRIDE_NUM_KEYS = ("drill_mm", "annulus_diameter_mm", "pad_width_mm", "pad_height_mm")


# Human messages for the shared-boundary codes :func:`board_validate.validate_board_v2`
# returns as bare strings; the CODE is the contract (matched by the committed
# vectors + Go), the message is operator context.
_BOUNDARY_MESSAGES = {
    "unsupported_schema_version": "canonical board schema requires an integer version 1 or 2 (present)",
    "unminted_persistent_id": "a v2 board and every trace/via/hole require a minted \"<kind>:<32hex>\" id",
    "duplicate_persistent_id": "a persistent id is duplicated within its entity domain",
    "invalid_board_structure": "a top-level entity collection is malformed or carries a null item",
    "invalid_pin_override": "a pin override field has the wrong type",
}

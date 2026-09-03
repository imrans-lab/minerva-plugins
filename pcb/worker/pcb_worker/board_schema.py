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

def component_value_refusal(board) -> "str | None":
    """Why a board cannot be loaded because a component states its value twice,
    or ``None`` when none does.

    ONE HOME FOR THE COMPONENT VALUE: the top-level ``value`` key. A second
    spelling under ``properties`` makes the loaded value depend on which home a
    reader consults, and the next save writes that reader's choice over the
    other home — losing a hand edit silently. Both Python boundaries refuse on
    it: the file parse (:mod:`board_model`) raises this message, and
    :func:`board_validate.validate_board_v2` returns the shared
    ``invalid_board_structure`` code that Go's ``probeNodeTree`` returns for the
    same document.
    """
    if not isinstance(board, dict):
        return None
    components = board.get("components")
    if not isinstance(components, list):
        return None
    for comp in components:
        if not isinstance(comp, dict):
            continue
        props = comp.get("properties")
        if isinstance(props, dict) and "value" in props:
            ref = comp.get("ref") or comp.get("id") or "?"
            return (f"component {ref!r}: properties.value is not a home for the "
                    f"component value; delete it and author the top-level "
                    f"'value' key")
    return None


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
    "invalid_design_rule": ("a design_rules value is out of range or the wrong type "
                            "(zone_min_thickness_mm must be positive; "
                            "zone_min_island_area_mm2 must be non-negative)"),
}


# ---------------------------------------------------------------------------
# The ordered appearance (`fabrication`)
# ---------------------------------------------------------------------------

#: The complete sub-key set the `fabrication` block admits — an ALLOW-LIST, and
#: the Python HALF of the boundary the Go codec reads reflectively off the
#: `board.Fabrication` struct tags (schema.go). Go needs no list because a field
#: IS the declaration; Python has no such mechanism, so this is hand-written and
#: has to be kept in step with the struct. An authored key with no reader is a
#: choice that lies about having been made.
FABRICATION_KEYS: tuple[str, ...] = ("mask_colour", "finish", "thickness_mm")

#: What we order today. A board that states nothing gets these, and they are
#: applied at COMPILE time only — never written back into the document, so a
#: board with no `fabrication` block stays byte-identical on disk and its source
#: digest does not move.
DEFAULT_MASK_COLOUR = "green"
DEFAULT_FINISH = "HASL"
DEFAULT_THICKNESS_MM = 1.6


def fabrication_refusal(board) -> "str | None":
    """Why a board's ``fabrication`` block cannot be loaded, or ``None``.

    Shape only — WHICH colours and finishes are legal is the selected
    manufacturer profile's business, not the schema's (a board house publishes a
    menu; a schema cannot). What this refuses is a malformed block: a
    non-mapping, an unknown sub-key, or a value of the wrong type. The message
    names the entity and the key, the way every other block's refusal does.

    Both Python boundaries use it: the file parse (:mod:`board_model`) raises
    this message, and :func:`board_validate.validate_board_v2` returns the
    shared ``invalid_board_structure`` code Go's positive-schema walk returns
    for the same document.
    """
    if not isinstance(board, dict):
        return None
    if "fabrication" not in board:
        return None
    block = board.get("fabrication")
    if block is None:
        return None
    if not isinstance(block, dict):
        return (f"board fabrication must be a mapping of "
                f"{'/'.join(FABRICATION_KEYS)}; got {type(block).__name__}")
    unknown = sorted(set(block) - set(FABRICATION_KEYS))
    if unknown:
        return (f"board fabrication declares unknown key(s) "
                f"{'/'.join(unknown)}; the block accepts only "
                f"{'/'.join(FABRICATION_KEYS)}")
    for key in ("mask_colour", "finish"):
        value = block.get(key)
        if value is None:
            continue
        if not isinstance(value, str) or not value.strip():
            return (f"board fabrication.{key} must be a non-empty string naming "
                    f"the choice as the vendor spells it; got {value!r}")
    thickness = block.get("thickness_mm")
    if thickness is not None and not (_is_number(thickness) and thickness > 0):
        return (f"board fabrication.thickness_mm must be a positive number of "
                f"millimetres; got {thickness!r}")
    return None

"""Neutral KiCad-pad type semantics shared by legacy and resolved paths.

The old resolver keeps its compatibility behavior (unknown tokens render as
SMD); the strict FootprintDefinition adapter additionally records an attributed
unsupported feature before K2 can use that fallback for fabrication.
"""

from __future__ import annotations

from typing import Any


PAD_TYPE_MAP: dict[str, str] = {
    "smd": "smd",
    "thru_hole": "thru_hole",
    "np_thru_hole": "np_thru_hole",
    "connect": "smd",
}
KNOWN_PAD_TYPES = frozenset(PAD_TYPE_MAP)


def normalize_pad_type(raw: Any) -> str:
    """Legacy panel token; deliberately preserves unknown→SMD compatibility."""
    return PAD_TYPE_MAP.get(raw, "smd")


def semantic_pad_type(raw: Any) -> str:
    """Schema token, preserving the recognized ``connect`` electrical kind."""
    return raw if raw in KNOWN_PAD_TYPES else "smd"


def is_known_pad_type(raw: Any) -> bool:
    return raw in KNOWN_PAD_TYPES

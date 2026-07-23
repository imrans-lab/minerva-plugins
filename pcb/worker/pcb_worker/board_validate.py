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

def _check_entity_ids(entity: str, item_lists: "list[list]", codes: list) -> None:
    """Append the first persistent-id violation across one entity DOMAIN (one or more
    collections that share an id namespace, e.g. the three hole alias keys). Every
    item must be a dict carrying a minted ``<entity>:<32hex>`` id, unique across the
    combined domain. Shared codes with Go's board.Validate."""
    seen: set = set()
    for items in item_lists:
        for item in items:
            if item is None:
                # A null item is already flagged invalid_board_structure upstream;
                # skip it here so it is not double-coded.
                continue
            if not isinstance(item, dict) or not _is_minted_id(entity, item.get("id")):
                codes.append("unminted_persistent_id")
                return
            item_id = item.get("id")
            if item_id in seen:
                codes.append("duplicate_persistent_id")
                return
            seen.add(item_id)


def validate_board_v2(board: dict) -> list[str]:
    """Return a list of shared-boundary error codes; an empty list means the board
    is valid at this boundary. Codes are identical to ``internal/board.Validate``:
    ``unsupported_schema_version``, ``unminted_persistent_id``,
    ``duplicate_persistent_id``, ``invalid_pin_override``, ``invalid_board_structure``.
    """
    if not isinstance(board, dict):
        return ["invalid_board_structure"]
    version = board.get("version")
    # bool is a subclass of int — exclude it explicitly (as _is_number does).
    if type(version) is not int or version not in (1, 2):
        return ["unsupported_schema_version"]

    codes: list[str] = []

    # Top-level entity collections are shared-shape containers: a present non-list
    # is invalid_board_structure on both sides — the Go codec rejects a mapping or
    # scalar where it expects a slice — even for a collection this validator does
    # not otherwise inspect (nets carry no persistent id, but `nets: {}` must still
    # fail closed on both sides). A NULL item inside any of the five collections is
    # ALSO invalid_board_structure: yaml.v3 silently drops a null list item, so a
    # canonical source entity would vanish to make the two parsers agree — rejected
    # on both sides instead (finding 019f8b7fb07e, part 3; the Go codec probes the
    # raw node tree for the same). Nested / auxiliary containers (points, layers,
    # annotations, route_hints, design_rules) are the documented Go-codec superset,
    # enforced by the codec and the full compiler, not re-checked here.
    lists: dict[str, list] = {}
    for key in ("components", "nets", "traces", "vias",
                "mounting_holes", "pth_holes", "npth_holes"):
        items, ok = _as_list(board.get(key))
        lists[key] = items
        if not ok:
            codes.append("invalid_board_structure")
        elif any(item is None for item in items):
            codes.append("invalid_board_structure")

    if version >= 2:
        if not _is_minted_id("board", board.get("id")):
            codes.append("unminted_persistent_id")
        # trace / via each own one collection. HOLES span three: the Go codec folds
        # pth_holes / npth_holes into mounting_holes (NormalizeHoles), so every hole
        # id must be minted AND unique across ALL THREE alias keys — the SAME "hole"
        # domain (finding 019f8b7fb07e comment 689). A raw board that reaches this
        # validator without the Go fold is checked identically here.
        _check_entity_ids("trace", [lists["traces"]], codes)
        _check_entity_ids("via", [lists["vias"]], codes)
        _check_entity_ids(
            "hole",
            # mounting → npth → pth: the SAME order Go's NormalizeHoles folds into
            # MountingHoles, so a multi-violation board emits the identical first code
            # on both sides (Fable D2 parity note).
            [lists["mounting_holes"], lists["npth_holes"], lists["pth_holes"]],
            codes)

    for comp in lists["components"]:
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

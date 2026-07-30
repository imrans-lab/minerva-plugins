"""Shared canonical-board validation boundary — Python side.

Mirror of ``internal/board/validate.go``. Enforces the schema-level rules the Go
codec and this validator must agree on (item 019f802ca3af, comment 629 — "K3 must
not consume a v2 board through independently drifting validators"): schema-version
dispatch, v2 persistent-id validity, typed pin-override field types (which the
Go codec enforces structurally at unmarshal, and this validator — parsing an
untyped dict — re-checks explicitly), and zone structure (:func:`_check_zones`,
added in epoch 4 with docket 019f9a73e5a2 / bug 019fb0a7aea7 item 4, when the
compiler stopped refusing the ``zones`` key outright).

It operates on a PARSED board dict and does NOT resolve footprints or geometry —
that is the full compiler (compile_board.py). The committed vectors in
``pcb/spec/vectors/`` are loaded and asserted identically on both sides; the error
codes here match ``internal/board.Validate`` verbatim. The minted-id predicate and
override-key set live in the neutral :mod:`board_schema` module (imported by both
this validator and the compiler) so the two Python paths cannot drift.
"""
from __future__ import annotations

# The shared predicates AND the override-key list live in the neutral
# board_schema module so the two Python paths cannot drift (the minted-id
# definition and the override field set have exactly one source of truth) — and
# so this validator no longer depends on the compiler (finding 019f88bac172).
from .board_schema import _OVERRIDE_NUM_KEYS, _is_minted_id, _is_number

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
    ``duplicate_persistent_id``, ``invalid_pin_override``, ``invalid_board_structure``,
    and — for zones — ``invalid_zone_outline``, ``zone_unknown_net``,
    ``zone_unknown_layer``.
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
    # fail closed on both sides). A NULL item inside ANY of these collections is
    # ALSO invalid_board_structure: yaml.v3 silently drops a null list item, so a
    # canonical source entity would vanish to make the two parsers agree — rejected
    # on both sides instead (finding 019f8b7fb07e, part 3; the Go codec probes the
    # raw node tree for the same). The list is deliberately not described by a COUNT:
    # a stated count goes stale the next time an entity is modelled, which is exactly
    # how bug 019fb0a7aea7 happened. Nested / auxiliary containers (points, layers,
    # annotations, route_hints, design_rules) are the documented Go-codec superset,
    # enforced by the codec and the full compiler, not re-checked here.
    lists: dict[str, list] = {}
    for key in ("components", "nets", "traces", "vias",
                "mounting_holes", "pth_holes", "npth_holes", "zones"):
        items, ok = _as_list(board.get(key))
        lists[key] = items
        if not ok:
            codes.append("invalid_board_structure")
        elif any(item is None for item in items):
            codes.append("invalid_board_structure")

    # Zone STRUCTURE is checked on v1 boards too — Go's Validate calls
    # validateZones before its version gate, because an outline that is not a
    # polygon or a net/layer that does not exist is wrong regardless of which
    # identity era the board is from. Identity is the version-gated part, below.
    _check_zones(lists["zones"], board, codes)

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
        # Zones own one collection, checked LAST — the same order Go's Validate
        # walks (trace, via, hole, zone), so a board violating two domains yields
        # the same first code on both sides. Adding this closes the asymmetry
        # recorded in bug 019fb0a7aea7 item 4, where Go validated zone ids and
        # Python did not.
        _check_entity_ids("zone", [lists["zones"]], codes)

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


def _check_zones(zones: list, board: dict, codes: list) -> None:
    """Mirror of Go's ``validateZones`` (internal/board/validate.go): append the FIRST
    zone-structural violation, using Go's own code strings.

    The three rules are Go's, verbatim in intent: an ``outline`` with fewer than 3
    points is not a polygon (``invalid_zone_outline``); a ``net`` that is empty or
    names no declared net is ``zone_unknown_net``; a ``layer`` that is empty, or —
    when the board declares a ``layers`` list at all — outside it, is
    ``zone_unknown_layer``.  Only the FIRST violation is appended, matching Go's
    return-on-first-error, so a board breaking two rules reports the same code on
    both sides.

    Version-independent, exactly as in Go: these are content rules, not identity
    rules.  A non-dict zone item is skipped here — the compiler's own ``_dict_items``
    rejects it as ``invalid_zone``, and a ``None`` item is already
    ``invalid_board_structure`` upstream, so skipping avoids double-coding.

    This checks the same fields the full compiler re-checks in ``_build_zones``; the
    compiler goes further (v1 copper-layer membership, thermal/clearance values,
    degenerate segments), which this boundary deliberately does not, because Go does
    not either and this file's job is Go parity."""
    if not zones:
        return
    raw_nets, _ = _as_list(board.get("nets"))
    net_names = {net.get("name") for net in raw_nets if isinstance(net, dict)}
    raw_layers, _ = _as_list(board.get("layers"))
    declared_layers = [str(item) for item in raw_layers]
    for zone in zones:
        if not isinstance(zone, dict):
            continue
        outline = zone.get("outline")
        if not isinstance(outline, list) or len(outline) < 3:
            codes.append("invalid_zone_outline")
            return
        net = zone.get("net")
        if not isinstance(net, str) or not net or net not in net_names:
            codes.append("zone_unknown_net")
            return
        layer = zone.get("layer")
        if not isinstance(layer, str) or not layer:
            codes.append("zone_unknown_layer")
            return
        # Only checked against the declared stack when the board declares one at all
        # (`layers` is optional) — a board with no explicit layer list has nothing to
        # validate a zone's layer name against. Same condition as Go.
        if declared_layers and layer not in declared_layers:
            codes.append("zone_unknown_layer")
            return


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

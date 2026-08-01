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

Layer-stack structure (:func:`_check_layers`, epoch 6 unit 3a) went in on BOTH sides
in one change, so unlike the zone codes it is exact parity from the start: the
canonical stack is ``top``, ``in1``..``inN``, ``bottom`` in stack order, and the
canonical inner-name parser is imported from :mod:`agent_router.layers` rather than
re-derived here.
"""
from __future__ import annotations

# The shared predicates AND the override-key list live in the neutral
# board_schema module so the two Python paths cannot drift (the minted-id
# definition and the override field set have exactly one source of truth) — and
# so this validator no longer depends on the compiler (finding 019f88bac172).
from .board_schema import _OVERRIDE_NUM_KEYS, _is_minted_id, _is_number

# The canonical inner-layer name parser is the SAME one the canon<->KiCad mapping
# uses (agent_router.layers is the lower, standalone package pcb_worker is allowed
# to import upward from). Re-deriving "what is a valid in<k>" here would be a
# second definition of the layer contract, which is exactly how the layer map
# drifted before T1.5 — Go's innerLayerIndex is the third, unavoidable, copy.
from agent_router.layers import inner_layer_index

# The canonical zone kinds, mirroring ZoneKindCopperPour / ZoneKindKeepout in
# internal/board/validate.go. An empty (or absent) kind IS a copper pour — the
# shape every board authored before the field existed has — so "" is a member of
# the accepted set rather than a fourth spelling to reject. Kept as literals here,
# not imported from resolved_board.ZoneKind, because this module is the Go-PARITY
# boundary: what it accepts must track Go's constants, and an enum defined for the
# compiler's IR could drift from them independently.
_ZONE_KIND_COPPER_POUR = "copper_pour"
_ZONE_KIND_KEEPOUT = "keepout"
_ZONE_KINDS = frozenset({"", _ZONE_KIND_COPPER_POUR, _ZONE_KIND_KEEPOUT})


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
    for the layer stack — ``invalid_layer_name``, ``duplicate_layer``,
    ``incomplete_layer_stack``, ``invalid_layer_stack_order`` — for zones —
    ``invalid_zone_outline``, ``invalid_zone_kind``, ``zone_unknown_net``,
    ``zone_unknown_layer`` — and for cutouts, ``invalid_cutout_outline``.
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
                "mounting_holes", "pth_holes", "npth_holes", "zones", "cutouts"):
        items, ok = _as_list(board.get(key))
        lists[key] = items
        if not ok:
            codes.append("invalid_board_structure")
        elif any(item is None for item in items):
            codes.append("invalid_board_structure")

    # Layers BEFORE zones, exactly as Go's Validate orders them: a zone's layer
    # is checked for MEMBERSHIP in the declared stack, so a board with a broken
    # stack must report the stack code, not a zone code derived from it. Both are
    # version-independent for the same reason — a malformed stack or a non-polygon
    # outline is wrong regardless of which identity era the board is from.
    _check_layers(board, codes)
    _check_zones(lists["zones"], board, codes)
    _check_cutouts(lists["cutouts"], codes)

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
        # Cutouts own one collection and are checked LAST, the same order Go's
        # Validate walks (trace, via, hole, zone, cutout) and the same order
        # MigrateV1toV2 mints in, so a board violating two domains yields the
        # same first code on both sides.
        _check_entity_ids("cutout", [lists["cutouts"]], codes)

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


def _check_layers(board: dict, codes: list) -> None:
    """Mirror of Go's ``validateLayers`` (internal/board/validate.go): append the FIRST
    layer-stack violation, using Go's own code strings.

    The declared ``layers`` list is OPTIONAL, and its ORDER *IS* the physical stack
    order — "top" first, "bottom" last, inner layers ``in1``..``inN`` (N capped by
    :data:`agent_router.layers.MAX_INNER_LAYERS`, KiCad's 30) in index
    order between them. Nothing sorts or dedupes it on either side, so the four rules
    are: canonical names only (``invalid_layer_name``), no repeats
    (``duplicate_layer``), both outer layers present (``incomplete_layer_stack``), and
    stack order with inners CONTIGUOUS from ``in1`` (``invalid_layer_stack_order``).
    Only the FIRST violation is appended, matching Go's return-on-first-error, so a
    board breaking two rules reports the same code on both sides.

    A ``layers`` value that is not a list at all is NOT coded here: Go's codec rejects
    it at unmarshal, so Go's Validate never sees one, and this file mirrors Go's
    *Validate*, not its codec (the same division of labour that leaves the other
    auxiliary containers to the codec — see the ``lists`` comment above).

    Inner layers are AUTHORABLE, NOT FABRICABLE: a 4-layer stack passes this boundary
    on both sides, and ``compile_board._require_two_layer`` still refuses to build
    anything but exactly ``["top", "bottom"]`` — the same shape as zones, which
    validate here and are refused by every output consumer."""
    raw_layers, ok = _as_list(board.get("layers"))
    if not ok or not raw_layers:
        return
    layers = [str(item) for item in raw_layers]
    seen: dict[str, int] = {}
    for i, layer in enumerate(layers):
        if layer not in ("top", "bottom"):
            # A DECLARED stack entry must be the exact canonical spelling. The
            # mapping helpers in agent_router.layers case-fold on purpose (they
            # translate whatever a producer hands them), but Go's validator
            # compares raw bytes, so "In1" must fail identically on both sides —
            # hence the round-trip check against the canonical form, not just a
            # non-zero index.
            k = inner_layer_index(layer)
            if k == 0 or layer != f"in{k}":
                codes.append("invalid_layer_name")
                return
        if layer in seen:
            codes.append("duplicate_layer")
            return
        seen[layer] = i
    if "top" not in seen or "bottom" not in seen:
        codes.append("incomplete_layer_stack")
        return
    # Both outer layers are present and unique, so the list is at least 2 long.
    if layers[0] != "top" or layers[-1] != "bottom":
        codes.append("invalid_layer_stack_order")
        return
    for i, layer in enumerate(layers[1:-1]):
        if layer != f"in{i + 1}":
            codes.append("invalid_layer_stack_order")
            return


def _check_zones(zones: list, board: dict, codes: list) -> None:
    """Mirror of Go's ``validateZones`` (internal/board/validate.go): append the FIRST
    zone-structural violation, using Go's own code strings.

    The four rules are Go's, verbatim in intent and IN GO'S ORDER: an ``outline``
    with fewer than 3 points is not a polygon (``invalid_zone_outline``); a ``kind``
    outside ``{"", "copper_pour", "keepout"}`` is ``invalid_zone_kind``; a ``net``
    that is empty or names no declared net is ``zone_unknown_net`` — EXCEPT on a
    keepout; a ``layer`` that is empty, or — when the board declares a ``layers``
    list at all — outside it, is ``zone_unknown_layer``.  Only the FIRST violation
    is appended, matching Go's return-on-first-error, so a board breaking two rules
    reports the same code on both sides.

    The keepout exemption is the owner boundary ruling of 2026-07-30 (docket
    019fb5ad6d20, "Keepouts don't need net connections"): a ``copper_pour`` is
    copper and copper belongs to a net, but a keepout is a KiCad-style rule area —
    a prohibition on copper, not copper — so it may name no net.  A keepout that
    DOES name a net is still checked against the declared nets, so a net-scoped
    keepout naming an undeclared net is still ``zone_unknown_net``.  ``kind`` is
    checked BEFORE ``net`` on both sides because kind decides which net rule
    applies; an unrecognized kind cannot be resolved to pour-or-keepout.  ``kind``
    is matched case-sensitively against canonical lowercase, exactly as Go does —
    the UI normalises case upstream (``PCBData.zone_kind()``), so a stray
    ``"Keepout"`` in hand-written source is a typo worth reporting.  An ABSENT or
    empty ``kind`` is ``copper_pour``, the pre-ruling shape, so every board
    authored before this field existed keeps its meaning on both sides.  A
    non-string ``kind`` is ``invalid_zone_kind`` too: Go's typed decode cannot even
    load one into ``Zone.Kind`` (it fails at unmarshal), so accepting it here would
    be Python being LOOSER than Go, the wrong direction for a fail-closed gate.

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
        kind = zone.get("kind")
        if kind is not None and (not isinstance(kind, str) or kind not in _ZONE_KINDS):
            codes.append("invalid_zone_kind")
            return
        net = zone.get("net")
        if kind == _ZONE_KIND_KEEPOUT:
            # Netless is the KiCad-parity case and is fine; a NAMED net must still be
            # one the board declares. `net: null` is "no net", same as absent.
            if net is not None and (not isinstance(net, str) or (net and net not in net_names)):
                codes.append("zone_unknown_net")
                return
        elif not isinstance(net, str) or not net or net not in net_names:
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


def _check_cutouts(cutouts: list, codes: list) -> None:
    """Mirror of Go's ``validateCutouts`` (internal/board/validate.go): append the
    FIRST cutout-structural violation, using Go's own code string.

    A cutout has exactly ONE content rule, because it has exactly one authored
    field besides its id: an ``outline`` with fewer than 3 points is not a polygon
    (``invalid_cutout_outline``).  There is no kind, no net and no layer to check —
    a cutout goes through the WHOLE board, which is what makes it a cutout rather
    than a third zone kind.  Only the first violation is appended, matching Go's
    return-on-first-error.

    Version-independent, exactly as in Go: a two-point "polygon" is wrong on a v1
    board too.  A non-dict item is skipped (a ``None`` item is already
    ``invalid_board_structure`` upstream, so skipping avoids double-coding).

    Unlike zones, there is no fuller re-check downstream: ``compile_board`` REFUSES
    any board declaring a non-empty ``cutouts`` (``unsupported_board_feature``), so
    a cutout is authorable and NOT compilable, and this boundary is the only place
    that ever inspects one.  Containment in the board outline, self-intersection and
    overlap with other entities are deliberately NOT checked on either side — see
    the Cutout type's comment in board.go for why that asymmetry would be worse
    than the gap."""
    if not cutouts:
        return
    for cutout in cutouts:
        if not isinstance(cutout, dict):
            continue
        outline = cutout.get("outline")
        if not isinstance(outline, list) or len(outline) < 3:
            codes.append("invalid_cutout_outline")
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

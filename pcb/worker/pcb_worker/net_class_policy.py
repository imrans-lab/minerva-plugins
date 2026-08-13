"""THE one owner of the referenced-net-class minima admission policy.

Chore 019fa20b11 (epoch GA-6). Two consumers read the SAME two ``NetClass``
fields — ``methods._net_class_overrides`` (routing; keys by net NAME, the
identity the router speaks) and ``drc_geometric._net_class_minima`` (GC1/GC2;
keys by ``net_id``, the identity a projected ``CopperPrimitive`` carries) —
and until this module existed each carried its own copy of the loop, the
referenced-only rule, the defensive class lookup, and the two per-dimension
fail-closed raises. They DIVERGED inside the very round that created the
second copy (C4a guarded the width leg and not the clearance leg while its
docstring claimed both), which is the failure mode this extraction removes:
relax the admission here and BOTH the routing and DRC suites go red.

DEPENDENCY-FREE ON PURPOSE, the ``board_schema.py`` precedent: ``methods``
already imports ``drc_geometric``, so the shared body could live in neither —
it needs this third module, and a third module that imported the engine or
the IR would just be a new cycle waiting. The caller therefore supplies the
pieces that belong to ITS side:

* ``key_of``          — which net attribute keys the result (name vs id).
* ``width_admit`` / ``clearance_admit`` — the SAME predicates both callers
  already share (``ir_candidates.positive_mm``, the engine's
  ``nonnegative_mm``); passed in rather than imported so this module stays
  import-free. The PREDICATE difference between the two dimensions is policy
  (zero-width copper is not copper; a 0.0 clearance is a legitimate rule
  that no-ops under ``max``) and lives with the callers' choice of
  functions, not here.
* ``fail``            — the exception class (both pass UnsupportedGeometry).
* ``context``         — the one phrase the two raise messages differed by
  ("routing" / "geometric DRC").

What is OWNED here, and can no longer drift: only referenced classes count;
a dimension the class says nothing about contributes ``None`` (the net falls
through to the next floor for that dimension); a class that DOES state a
value is admitted or the whole run fails closed naming the class and the
field — never silently reinterpreted; a net whose class reference cannot
resolve is skipped (unreachable on a valid ResolvedBoard, whose
``__post_init__`` rejects unknown class references — defensive, not a path).
"""

from __future__ import annotations


def referenced_class_minima(rb, *, key_of, width_admit, clearance_admit,
                            fail, context):
    """``key_of(net) -> (min_trace_width_mm, min_clearance_mm)`` for every net
    referencing a class that names at least one of them. See module doc."""
    classes = {nc.id: nc for nc in rb.design_rules.net_classes}
    out: dict = {}
    for net in rb.nets:
        if not net.net_class_id:
            continue
        nc = classes.get(net.net_class_id)
        if nc is None:
            continue  # unreachable on a valid ResolvedBoard; see module doc

        width = None
        if nc.min_trace_width_mm is not None:
            width = width_admit(nc.min_trace_width_mm)
            if width is None:
                raise fail(
                    f"net {net.name!r} belongs to net class {nc.id!r} whose "
                    f"min_trace_width_mm={nc.min_trace_width_mm!r} is not a "
                    f"positive, finite width in mm — {context} fails closed "
                    f"rather than reinterpret the class's own rule")

        clearance = None
        if nc.min_clearance_mm is not None:
            clearance = clearance_admit(nc.min_clearance_mm)
            if clearance is None:
                raise fail(
                    f"net {net.name!r} belongs to net class {nc.id!r} whose "
                    f"min_clearance_mm={nc.min_clearance_mm!r} is not a "
                    f"non-negative, finite clearance in mm — {context} fails "
                    f"closed rather than reinterpret the class's own rule")

        if width is not None or clearance is not None:
            out[key_of(net)] = (width, clearance)
    return out

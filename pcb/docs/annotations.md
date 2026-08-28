# Annotating a board

Board annotations are Minerva's **core** kinds, not a pcb invention. This is the
measured contract behind the annotation steps in the `minerva_pcb_design` skill.

## Kinds, by intent

| Kind | Use it for | Geometry that matters |
| --- | --- | --- |
| `2d_arrow` | pointing AT one thing | `primitives[].to` is the **tip/target**; `from` is empty space 5–8 mm behind it |
| `2d_text` | labelling a spot | `primitives[].at` |
| `2d_region` | calling out an area | `primitives[].points` (closed polygon; a rect is the 4-point case) |
| `2d_polyline` | tracing a path | `primitives[].points` (open) |
| `pcb_route_hint` | steering the router | workflow, not commentary — see `routing.md` |

A `2d_arrow` carries its caption in `kind_payload.label` (with optional
`label_offset` / `label_font_size`). One arrow plus its caption is **one**
annotation; never add a separate `2d_text` beside it.

## Coordinates

Board millimetres, y-down — the same frame every `minerva_pcb_*` verb speaks.
Never screen pixels. Get a pad's exact mm from `minerva_pcb_pin_info`
(`position.x_mm` / `position.y_mm`), never by eye off a rendered image.

## Anchors

`PcbAnnotationHost` resolves five anchor types — `pcb/board.point`, `pcb/pad`,
`pcb/component`, `pcb/net`, `pcb/trace` — plus `core/canvas.point`.

**But the kind decides which of those it will accept.** The core generic kinds
(`2d_arrow`, `2d_text`, `2d_region`, `2d_polyline`) accept `core/*` only; a
`pcb/pad` anchor on one is rejected as `kind_anchor_incompatible` and the add
returns no id. `pcb_route_hint` accepts `pcb/board.point` and `pcb/pad`. Only
`callout` accepts every anchor type.

So for the generic kinds, the domain entity is resolved **geometrically, not by
the anchor**: `minerva_annotations_list` calls the kind's own
`primary_anchor_point` (an arrow's tip, a text's `at`, otherwise the bounds
centre) and hit-tests it against the live board, in the precedence order
pad → via → component → trace. Putting the tip on the pad is exactly what makes
`anchor_detail` read `{kind: "pad", id: "R8A.1", distance_mm: 0.0}`.
`minerva_pcb_describe_region` returns the annotations whose anchor point lies
inside a rectangle as its `notes`.

## Verify by render

After every add:

1. `minerva_annotations_list` — `anchor_detail` must name the entity you meant,
   and the arrow's `to` must be within 0.5 mm of `anchor_detail.position`.
2. `minerva_pcb_get_image` with `save_to_path`, then read the PNG. The list can
   agree with itself and still be pointing at the wrong part of the board.

## Known trap: a dragged annotation keeps its old anchor block

Filed against Minerva as *"transform-tool drag updates primitives but not the
annotation's anchor block"*. Dragging with the transform tool sends the whole
new envelope through `update_annotation`, which re-stamps `anchored_to` and
leaves `anchor.id` / `anchor.snapshot.position` at the values authored. For a
`2d_arrow` that is cosmetic — `anchor_detail` is derived from the primitives, so
it still tracks — but the stored anchor coordinates no longer describe where the
arrow points. **Re-add rather than drag** when the anchor block matters.

## Eval

`tests/eval/annotate_arrow_eval.py` is the falsifier for the skill's annotation
claim: it spawns a worker with the skill, asks in plain language for an arrow at
a named pad, and grades the result against the board (`anchor_detail` names the
pad; the tip is within 0.5 mm of it). Three armed runs, 3/3 to pass, plus one
recorded control run without the skill. Its header documents how to run it.

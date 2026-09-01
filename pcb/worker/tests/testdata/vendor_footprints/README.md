# Vendor package drawings — committed reference for orientation measurement

`pcb_worker.part_orientation` compares one of our seed footprints against the
**vendor's** canonical drawing of the part we buy for it. That comparison is
what tells us whether a pick-and-place rotation, which the assembly house
interprets against the vendor's drawing and not against our `.kicad_mod`, will
put the part down the way we drew it.

The vendor side has to come from somewhere, and it must not come from the
network at test time: an assertion that depends on a live fetch is an assertion
that fails on a plane, passes differently after a supplier edits a package, and
cannot be bisected. So the payloads live here.

## What these files are

One file per LCSC part number, plus `index.json` pairing each part with the
seed footprint it is bought for. Each payload is the LCSC/EasyEDA component
document for that part, **trimmed to the subtree the measurement reads**:

    result.title, result.description
    result.lcsc.number
    result.packageDetail.{uuid,title,docType,updateTime,datastrid}
    result.packageDetail.dataStr.{head,shape,BBox}

`dataStr.head.x`/`.y` is the drawing origin and `dataStr.shape` is the record
list the parser scans for `PAD~` entries. **`shape` is kept verbatim**,
including the `TRACK`, `SOLIDREGION`, `CIRCLE`, `ARC` and `SVGNODE` records the
parser must skip — trimming those would leave the record filter untested
against anything real.

## What was dropped, and why

Prices, stock levels, image URLs, the schematic-symbol `dataStr`, and the
package `layers`/`objects`/`netColors` arrays. Two reasons, both about
determinism: the commerce fields change hourly, so a re-fetch would produce a
spurious diff on every refresh; and none of them is read by anything that could
turn them into a number. Keeping them would make the fixture bigger and its
diffs meaningless.

## Provenance and refresh

Fetched 2026-09-01 from the LCSC/EasyEDA component API, cached, then trimmed
into this directory. To refresh a part, re-fetch its component document and
apply the same trim; then **re-run the orientation suite before committing**.
A changed offset is not a fixture problem to be blessed away — it means either
the supplier redrew the package or our footprint changed, and both need a human
to look at the board before the next order goes out.

## Corpus policy

These are **parts**, not boards. `testdata/POLICY.md` bans real product board
designs — netlists, placements, routing — from this public corpus; a vendor's
package drawing of a purchasable component carries none of that, exactly as the
seed footprint library it is compared against carries none of it.

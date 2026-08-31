# The order package (`order_package`)

One action, one compilation, everything a house is sent — plus the two files a
person needs and the house never sees.

```
<board>-<profile>/
  gerbers.zip           fabrication files ONLY
  bom.csv               what to buy
  cpl.csv               where to put it
  assembly-preview.svg  what we claimed, drawn, for a person to disagree with
  ORDER-CHECKLIST.md    the order-form choices no uploaded file encodes
  preflight.json        what was checked, advised, and not looked at
  order-manifest.json   the audit record, with a digest per output
```

Emitter: `worker/pcb_worker/order_package.py`. The digest projection is
`order_provenance.py`; the write contract is `order_write.py`. The BOM/CPL
columns, the fabrication rule profile a board must have compiled against and the
checked/advisory/unchecked rule lists all come from the selected service profile
(`service-profiles.md`).

## One compilation

The worker method strict-compiles the board once and derives the archive, both
CSVs, the placement map and every manifest claim from that one `ResolvedBoard`.
Two compilations could describe two boards — a library layer or a blessed
footprint moving in between is enough — while every gate inside each one still
passed. This is also why a package is a single method rather than a caller
stitching `gerbers` and `assembly_package` together: those are two compilations.

## The archive is an allowlist

`gerbers.zip` may contain `.gbr`, `.drl` and `.gbrjob` and nothing else. A
house's uploader is entitled to reject an archive carrying anything else, and
entitled to do it after payment, so membership is CHECKED rather than assumed: a
file that does not belong refuses the package by name
(`order_package_archive_content`) instead of riding along inside it. The
manifest and the checklist sit BESIDE the archive — a house's ordering guidance
says non-Gerber statements inside a fabrication archive are ignored.

The archive is deterministic: members sorted, timestamps and permissions pinned,
host system pinned. Two builds of one board produce the same bytes.

## The digest projection

Silk carries an immutable design revision:

```
<board name> <rev> <digest-8>
```

authored as an ordinary `board_graphics` text entry. The digest is taken over
the board source, and that string is IN the board source, so hashing the file
verbatim would make the digest an input to itself. Before hashing, the eight
character digest slot in every provenance string is replaced by the sentinel
`________`. The projection is therefore invariant under any change to that slot,
so writing the computed digest into it cannot move the digest — a fixed point
reached in one step rather than by iterating.

Only those eight characters are normalized. The board name and the revision in
the same string are hashed as authored, so a revision bump DOES move the digest,
and so does adding the graphic at all (its layer, position and size are ordinary
board data). The authoring pass is therefore:

1. author the graphic with `________` in the slot;
2. export, and read the eight characters out of the advisory or the manifest;
3. write them into the slot.

The second export reports `state: verified` and the same digest.

A text entry is provenance only when it opens with the board's own `name`.
Anchoring on the name is what stops the projection firing on unrelated silk that
happens to end in eight hex characters.

**Absence is an advisory.** A board with no revision printed on it still
exports — a board is authored before it is stamped, and the stamping pass needs
a package first. Only a MISMATCH refuses (`assembly_provenance_mismatch`),
because that board's silkscreen names a design the files are not. A board
printing two different revisions refuses for the same reason.

The export timestamp is NOT on the board. It lives in the manifest, so
regenerating a package next month does not require editing the design.

## The assembly preview

`assembly-preview.svg` is the one artifact in the package nobody uploads. It is
the last point at which a wrongly-placed or wrongly-turned part costs nothing,
and it is rendered by `assembly_preview.py` from the SAME `AssemblyEmission`
`cpl.csv` is written from — not a second walk of the same board.

**Two layers, from two different places, on purpose.** The body outlines, the
lands and the pin-1 land come from the compiled board's own placed geometry —
the same ink the Gerbers carry. The crosshair, the designator, the rotation tick
and the side come from the CPL rows. They are not two computations of one
answer; they are answers to two different questions — "where did we draw this
part" and "where did we tell the house to put it" — plotted in one frame so the
gap between them is a distance a person can see.

**The frame is the CPL's frame**, through `assembly_outputs.cpl_frame_point`: X
verbatim, Y negated, bottom-side X unmirrored, both sides in one picture. Every
printed number is a string from `assembly_outputs.cpl_cells`, so the page and
the file cannot round differently. Inside the flipped drawing group SVG's own
`rotate()` turns counter-clockwise, which is the emitted convention, so the
rotation tick is drawn at the emitted angle with no sign arithmetic.

**What it shows, and what it deliberately does not.** Body outline (fab layer,
else silk, else the lands' box — whichever it was is named on the page), every
land, the pin-1 land, the claimed centroid, its rotation and its side, plus the
emitted rows as a text table to hold beside the house's parsed one. Not copper,
traces, zones, mask or silk legend: this is not a fabrication preview, and every
extra layer is ink competing with the four things a person is meant to check.
A part the order does not populate is drawn greyed and labelled `DNP`, carrying
no crosshair, because a deliberately empty spot and a part somebody dropped from
the order look identical otherwise.

**Pin 1 is marked on every part with more than one distinct pad number.** The
rule is not narrower because board data cannot tell a resistor from an LED: the
two sit on identical land patterns and differ only in a part number, and this
DCR puts no part-semantics database in scope. A part with one terminal, or with
unnumbered pads, or with no pad 1, is left unmarked AND SAID SO on the page —
an absent mark must never read as a part somebody checked and found symmetric.

**Two ways a wrong anchor becomes visible.** A crosshair that lands outside its
own drawing's ink is ringed with a leader back to the part it names. That is the
easy half. The harder half is a wrong anchor that lands INSIDE the drawing — the
shape the `anchor_mm` key exists for, where several parts inherit one anchor
measured off the whole drawing — which no ring should fire on because it is a
legal shape. The lands are drawn so a crosshair sitting between two pin rows
rather than on one can be seen, and every drawing that placed more than one part
without stating an anchor per placement is listed by name on the page. Neither
is a check with a code and neither raises an advisory: the DCR draws this
boundary at a person, not at a rule.

**Self-contained.** One SVG, no script, no external stylesheet, no web font, no
remote image. A person on a laptop opens it in a browser with no toolchain,
which is the only delivery that survives being the last check before payment.
The file is deterministic, because the manifest digests it.

## Readiness — three separate claims

| state | who can establish it |
|---|---|
| `package_generated` | the exporter. The files exist and agree with each other. This is all that serialization proves. |
| `preflight_status` | the exporter: `pass`, `advisories`, or `blocked`. |
| `order_page_verified` | **a person only.** |

`order_page_verified` leaves the exporter as `null`, every time. There is no
parameter that sets it and no code path that computes it; the only place it can
be recorded is the quote-page section of `ORDER-CHECKLIST.md`, which a human
fills in. An export that inferred it would be claiming an answer from a page it
never loaded.

A `blocked` board produces NO package. The refusal carries the preflight report
that would otherwise have been written, with `package_generated: false`.

## What the manifest records

Source digest and its projection, the git revision of the source file (or a
named reason there is none — a board handed over inline has no repository, and
a revision a caller could supply would be a claim rather than evidence); a
SHA-256 for every other output; the selected profile with its fabrication rule
profile, dialect parameters and pinned template artifacts; tool versions; the
logical-component-to-physical-placement map with each placement's anchor, anchor
basis, rotation and side; the not-populated list with its paste decisions;
declared footprint licences; surfaced IP questions; the check results including
what was explicitly not checked; and the export timestamp.

The manifest does NOT record its own digest — a file cannot contain its own
hash — and says so in place of the value. Every other artifact is deterministic,
so the recorded digests reproduce when the same inputs are built again.

## Writing is all-or-nothing

A half-written package is worse than none: its manifest describes files that are
not there, and somebody can still upload it. Artifacts are written into a
staging directory nobody else can see and the directory is then moved into place
with a single rename, so a reader of the destination sees the complete package
or no package.

An existing package directory is NOT replaced unless an overwrite is asked for —
it may already have been uploaded. On overwrite the previous directory is moved
aside first and removed only once the new one is in place.

The same module's loose-file writer backs the two-CSV `assembly_package` path,
which cannot use a directory rename: every byte is written to a temporary
neighbour before any destination name is touched, so a caller error or a full
disk leaves the directory holding neither CSV rather than a BOM with no CPL.

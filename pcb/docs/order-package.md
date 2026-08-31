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

## The two surfaces, and why they are one function

A person can only click; an agent can only call. If either reaches an exporter
the other cannot, the capability is invisible to half the people who need it —
and if one fault comes back with two names, it is two bugs to chase instead of
one to fix. So the export affordance is a CHOICE of exporter, offered
identically on every surface, and all of them run one function.

| surface | control | who uses it |
| --- | --- | --- |
| PCB panel toolbar | an **Export** menu, one row per exporter, the current one radio-checked | a person, at any width above narrow |
| PCB panel View menu | one **Export: …** row per exporter | a person, at narrow widths where the toolbar button is hidden |
| `minerva_pcb_board_export` | `{editor_name, exporter?, out_dir?, overwrite?}` | an agent, over the LIVE board |
| `minerva_pcb_order_package` | `{yaml\|board, profile?, out_dir?, overwrite?, source_path?}` | an agent, over a document |

`ui/pcb_export.gd` owns the exporter list, the run and the report; the toolbar
menu, the View-menu rows and the panel verb are three doorways onto its `run`.
Picking a row on either surface moves the selection on both, and
`get_layout_state().selected_exporter` reports it, so an agent can read the
human's control without a screenshot. The panel
sends on `minerva_pcb_order_package` itself as a panel-IPC channel — the same
arrangement `minerva_pcb_drc` already has — so there is ONE registry entry and
one handler behind a human's click and an agent's call. Nothing can be told to
name a refusal differently depending on who asked.

The exporters today: `yaml` (the canonical document, read out and written
nowhere — `minerva_pcb_promote` is still the only verb that writes the canonical
file), `jlc` (the package in JLCPCB's CSV dialect, claiming no assembly tier)
and `jlcpcb-economic` (the same package checked against the Economic tier).
Adding a service profile adds a row to `EXPORTERS` and nothing else.

The toolbar control is ONE menu rather than a chooser beside a button, and the
width is the reason: the strip's fit at 600 px is a pinned oracle, its budget is
tight enough that adding the Options menu once had to be paid for out of the
caption rule, and a chooser wide enough to read "Order package — JLCPCB
Economic" beside a button is far more than the button it replaces. A menu costs
one button of width whatever the list does — the same argument View and Options
are unconditional on.

### Where a panel export writes, and what it claims about the source

With no `out_dir` a package is written BESIDE the canonical YAML file the board
was adopted from — the same implicit target `promote()` resolves. A board that
was never loaded from one refuses `no_output_directory` rather than inventing a
path; that refusal is reached identically from the button and from the verb, and
neither reaches the worker.

The live board is sent to the worker INLINE, with no `source_path`, on purpose.
The manifest's git block is evidence about a FILE, and the board in an editor
may hold edits that file does not: naming the canonical path would stamp a
revision onto bytes it does not describe. Absent, the manifest records "the
board source was supplied inline, not as a file in a repository", which is
exactly true of a live editor board.

### What the panel shows, and the warnings nobody used to render

A refusal always opens a report; a package that generated opens one when it has
something to say about itself. Every finding is printed with the component and
field it is about — a blocker, a service advisory and a compile diagnostic all
render through one function, because a reader does not care which producer a
finding came from.

Compile warnings get their own section. The worker has carried them on every
assembly reply since the single-compilation cutover and no surface drew them, so
a warning about the very board in the envelope — captured geometry that was not
emitted, say — reached nobody who could act on it. They do NOT move
`preflight_status`: that is the service talking about the order, and these are
the compiler talking about the board. `minerva_pcb_export_assembly` forwards the
same list, which its own reply decoder used to discard silently along with the
`unchecked_rules` its description already promised.

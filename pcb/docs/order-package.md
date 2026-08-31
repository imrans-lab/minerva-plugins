# The order package (`order_package`)

One action, one compilation, everything a house is sent — plus the two files a
person needs and the house never sees.

```
<board>-<profile>/
  gerbers.zip           fabrication files ONLY
  bom.csv               what to buy
  cpl.csv               where to put it
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

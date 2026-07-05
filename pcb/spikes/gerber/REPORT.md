# Gerber-writer validation spike -- report

Docket: 019eb480415a (spike) -> feeds implementation child 019eb47ddebc.

## Verdict: gerber-writer viable, with caveats

`gerber-writer` produces structurally sound RS-274X/X2 Gerber output for
copper, mask, silkscreen and profile layers, including arcs and filled
regions. It has zero Excellon support (confirmed by reading its source --
there is no drill-related module in the package at all), so the
implementation child (019eb47ddebc) must own drill-file generation itself;
this spike hand-writes the two Excellon files to prove the format is trivial
enough to do so directly. All 20 validator checks passed or produced
documented, non-blocking WARNs; zero FAILs. The escalation rule was not
triggered.

The one open item is not a code problem: zero-warning visual confirmation
in a real Gerber viewer (gerbv/KiCad GerbView) is deferred to a
human-in-the-loop session, per the spike brief (no such viewer is available
in this environment). Structural checks plus two independent parser
round-trips stand in as this round acceptance gate.

## Library currency

| Library | Latest version | Released | Maintenance signal |
|---|---|---|---|
| gerber-writer | 0.4.3.3 | 2024-04-17 | Author is Karel Tavernier, Ucamco managing director and a principal author of the Gerber format spec itself. No PyPI release in the last 12 months; GitHub repo (karel-tavernier/gerber_writer) shows 36 commits, 2 releases, 0 open issues, not archived. Claims 100% compliance with spec revision 2023.08. Requires Python >=3.9; installed and imported cleanly on 3.12.4 with no compatibility shims needed. |
| pcb-tools (fallback candidate) | 0.1.6 | 2019-03-20 | Classified Alpha; no release in ~7 years. It is a reader, not a writer -- it never fit the writer role the task asked it to be evaluated for. Its main entry points (gerber.read, GerberParser.parse) call open(filename, "rU"); Python 3.11+ removed the U file mode, so both entry points raise ValueError: invalid mode: rU on Python 3.12 out of the box. Workaround used here: read the file manually and call the lower-level GerberParser.parse_raw(data, filename) directly (see validate.py:run_pcbtools_check), which bypasses the broken open() call. This is undocumented and could break on the next internal refactor. Even with the workaround, pcb-tools has no concept of Gerber X2 attributes -- it tokenizes G04 #@! TF.FileFunction,...* as an opaque .comments string, not as structured metadata (confirmed empirically, not just from docs). Usable as a coarse independent geometry/aperture-count sanity check; not usable for X2-attribute validation, and not a credible writer fallback. |
| pygerber (found during search, used instead of pcb-tools as the primary round-trip validator) | 2.4.3 | 2025-03-19 | Actively maintained (release 11 months more recent than gerber-writer own last release), Python 3.8-3.13, Gerber X3 parser/renderer/render-to-raster/render-to-SVG toolkit. Installed cleanly, no native deps beyond numpy/pillow/pydantic. Correctly parses gerber-writer G04 #@!-comment-style X2 attributes into a structured file_attributes dict, infers file type (COPPER/SOLDERMASK/LEGEND/PROFILE) from .FileFunction, computes an aperture-aware bounding box (accounts for pad/aperture extents, unlike pcb-tools flash-center-only bounds), and can raster-render a layer to PNG headlessly (used informally here as a non-blocking sanity image, not a substitute for the HITL viewer check). Recommend pygerber, not pcb-tools, as the project ongoing independent-validator dependency if one is wanted going forward. |

No other credible pure-Python Gerber writer surfaced in the search (gerbolyze,
gerber-renderer, python-gerber are rendering/reading tools, not
spec-compliant X2 writers; pygerber itself is read/render-only, confirmed by
its own docs).

## Format constraints discovered

- Coordinate format is NOT fixed at 4.6 (KiCad-equivalent). gerber-writer
  computes %FSLAX_Y_*% dynamically from the layer actual coordinate
  extents: integerdigits = max(1 + floor(log10(max_coord_mm)), 3). For this
  40mm x 30mm test board every layer emitted %FSLAX36Y36*% (3 integer +
  6 fractional digits), not 4.6. This is still fully spec-valid RS-274X (the
  format is self-declaring and any consumer must read the %FS line rather
  than assume 4.6), but it means byte-for-byte goldens are not portable
  across board sizes -- a board whose max extent crosses 1000mm would shift
  to %FSLAX46Y46*%. validate.py checks self-consistency of whatever %FS
  is declared rather than hard-requiring 4.6; the implementation child should
  do the same (read %FS, do not assume it).
- X2 attributes are emitted as backward-compatible G04 #@! comments, not
  %TF...*%/%TA...*% extended commands. e.g.
  G04 #@! TF.FileFunction,Copper,L1,Top,Signal* rather than
  %TF.FileFunction,Copper,L1,Top,Signal*%. Both forms are spec-legal (the
  comment form exists precisely so pre-X2 tooling safely ignores the line as
  a comment while X2-aware tooling still extracts it). Verified empirically
  that pygerber parses this form into a correct, structured attribute dict
  and infers the right file type from it. Still worth flagging: if a fab
  house intake tooling only scans for literal %TF., (some do, in the
  wild), gerber-writer output could be silently under-attributed on their
  end even though it is spec-compliant. Not a defect, but a real-world
  interop risk worth a note to whoever picks the fab house.
- Arcs: supported and round-trip clean. Path.arcto(end, center, orientation)
  emits proper G02/G03 with I/J offsets; spot-checked with an
  independent arc trace (not part of the main test board, since the task
  board spec did not call for one) and pygerber parsed it without error.
- Regions/polygons: supported and round-trip clean. DataLayer.add_region
  emits G36/G37 filled-region blocks; requires every subpath to be a
  closed contour (enforced by the library at the Python level, raises
  ValueError before any Gerber is written if a contour is not closed). Also
  spot-checked independently of the main test board; parsed cleanly.
- Plated/non-plated split: not modeled by gerber-writer at all -- it only
  emits Gerber layers (copper/mask/silk/profile), never drill data of any
  kind. The PTH/NPTH split is a pure Excellon-format concept and entirely the
  implementation child responsibility; see below.
- Precision: internal working unit is nanometers (TO_NM = 1_000_000,
  i.e. mm x 10^6), independent of the declared %FS digit count, so
  round-off inside the library is not a concern at PCB scale.
- Aperture identity / D-code reuse is automatic and correct: apertures are
  keyed by (shape, function, negative) and re-defined only once even when
  flashed many times (confirmed: board-F_Cu.gbr four SMD pads at
  different locations share one %ADD10...% definition).

## What the implementation child (019eb47ddebc) must own itself

1. Excellon drill generation, entirely. gerber-writer has no Excellon
   support of any kind. generate.py in this spike hand-writes a minimal but
   structurally valid Excellon file (M48 header / tool table / FMAT,2 /
   METRIC / G90 G05 / per-tool X..Y.. hits / M30), split into
   separate PTH and NPTH files (the traditional, still-widely-accepted way to
   express the plated/non-plated distinction, since neither the Excellon
   format classic header nor gerber-writer has a first-class per-hole
   plated flag). This is the same shape the implementation child should
   start from, but it is genuinely new code they own -- there is no library
   to lean on here.
2. A canonical-YAML -> gerber-writer compiler. This spike hard-codes the
   test board geometry directly against the gerber_writer API; it does not
   parse board.yaml. Writing a generic compiler that walks
   pcb/internal/board.Board (components/pins/nets/traces/vias) and emits
   the six Gerber layers + two Excellon files is implementation-child scope.
3. Two small schema gaps surfaced by trying to express this test board
   canonically (see board.yaml trailing comment block): the canonical
   Pin struct has no drill/annulus fields for through-hole pads, and there
   is no first-class non-plated-mounting-hole entity. Both were routed
   through the schema documented Extra-map passthrough for this spike;
   the implementation child should decide whether these deserve real fields
   or should stay opaque long-term.
4. Choosing + wiring an X2-attribute-aware fab convention (AperFunction
   coverage on mask/silk layers, component-pad-vs-via-pad attribution, etc.)
   -- this spike mask/silkscreen layers deliberately omit .AperFunction
   (flagged as WARN by validate.py, not FAIL) since the task only asked for
   FileFunction/FilePolarity coverage at the acceptance-gate level.

## Per-layer validation table (from validate.py, this run)

| Layer | FS spec | FileFunction | FilePolarity | Apertures | D0x | Coords in bounds | pygerber round-trip | pcb-tools round-trip |
|---|---|---|---|---|---|---|---|---|
| board-F_Cu.gbr | FSLAX36Y36 | Copper,L1,Top,Signal | Positive | OK 4/4 | D01=2 D02=2 D03=6 | OK | OK bbox 8.45-30.8 x 9.35-20.65 | OK (workaround; 8 primitives) |
| board-B_Cu.gbr | FSLAX36Y36 | Copper,L2,Bot,Signal | Positive | OK 3/3 | D01=1 D03=2 | OK | OK bbox 19.6-30.8 x 9.6-15.8 | OK (workaround; 3 primitives) |
| board-F_Mask.gbr | FSLAX36Y36 | Soldermask,Top | Positive | OK 2/2 | D03=5 | OK | OK bbox 8.35-30.9 x 9.25-20.75 | OK (workaround; 5 primitives) |
| board-B_Mask.gbr | FSLAX36Y36 | Soldermask,Bot | Positive | OK 1/1 | D03=1 | OK | OK bbox 29.1-30.9 x 14.1-15.9 | OK (workaround; 1 primitive) |
| board-F_SilkS.gbr | FSLAX36Y36 | Legend,Top | Positive | OK 1/1 | D01=9 D02=3 | OK | OK bbox 8.325-29.075 x 8.925-21.075 | OK (workaround; 9 primitives) |
| board-Edge_Cuts.gbr | FSLAX36Y36 | Profile,NP | Positive | OK 1/1 | D01=4 D02=1 | OK | OK bbox -0.05-40.05 x -0.05-30.05 | OK (workaround; 4 primitives) |
| board-PTH.drl | n/a (Excellon) | n/a | n/a | tools 1:0.8, 2:0.4 all referenced | n/a | OK (2 holes) | n/a (Gerber-only parsers) | n/a |
| board-NPTH.drl | n/a (Excellon) | n/a | n/a | tools 1:3.2 referenced | n/a | OK (1 hole) | n/a | n/a |

Full run: 8 checks OK-only, 12 WARN (all documented above), zero FAIL, out of
20 total per-file results. Exit code 0. Reproduced twice from a clean venv
install (pip install -r requirements.txt then generate.py then validate.py)
during this spike; byte-identical output both times.

pip freeze of the validation venv:
```
annotated-types==0.7.0
cairocffi==0.9.0
cffi==2.0.0
click==8.4.2
colorama==0.4.6
gerber_writer==0.4.3.3
numpy==2.5.1
pcb-tools==0.1.6
pillow==12.3.0
pycparser==3.0
pydantic==2.13.4
pydantic_core==2.46.4
pygerber==2.4.3
pyparsing==3.3.2
typing-inspection==0.4.2
typing_extensions==4.16.0
```

## Remaining HITL check (explicit, not automatable here)

Open pcb/spikes/gerber/golden/*.gbr + *.drl in gerbv or KiCad GerbView,
overlay all six Gerber layers plus both drill files, and confirm:

1. Zero parser warnings in the viewer for any layer (gerbv and KiCad both
   surface non-fatal spec-deviation warnings that this spike regex-based
   structural checks and the two Python parsers used here would not
   necessarily catch).
2. Visual match to intent: R1/C1 SMD pads sit under their courtyard
   silkscreen; U1 through-hole pad shows as a round pad with a drilled hole
   on both F.Cu and B.Cu; the VCC net F.Cu trace lands exactly on the via,
   the via aligns with the B.Cu trace, and that trace lands exactly on U1;
   the GND trace connects R1 pin 1 to C1 pin 1; the board outline is a clean
   closed 40mm x 30mm rectangle with no gaps; solder mask openings are
   centered on their copper pads with visible clearance; the NPTH mounting
   hole appears only in the drill layer (no unwanted copper/mask ring around
   it).
3. Drill-to-copper alignment: both PTH holes (U1, via) land inside their
   respective copper annuli with no viewer-flagged annular-ring violations.

This is the one item this spike could not close itself (no gerbv/KiCad
available in this environment) and is the explicit gate before the
implementation child treats gerber-writer output shape as final.

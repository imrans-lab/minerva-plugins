# jlc-coupon-1 — the public fabrication test coupon

`coupon_jlc1.yaml` is the **promoted design of record** for the Minerva PCB
plugin's fabrication test coupon (epoch CPN1, docket `019fe2fabba4`).
SYNTHETIC per `POLICY.md`: designed from scratch for this corpus, no product
geometry or naming.

**The file is machine-written.** It was produced by `minerva_pcb_promote` —
the K13 correctness-gated serialize-back — and YAML comments do not survive
that round trip, so this README carries the documentation the seed's header
used to hold. Do not hand-edit the YAML; drive changes through the panel and
re-promote.

## What the board is

A 24×18 mm 2-layer manufacturability coupon under the `jlcpcb-2layer`
manufacturer profile (`pcb/library/profiles/jlcpcb-2layer.json`). Every
bracketed value below marks a structure authored **at** that published JLCPCB
floor, so a fabricated coupon physically certifies the floors it names —
K18's "the golden certifies what a real fabricated board needs" and K21's
"output honours the profile" in one artifact. The tightening rows in
`tests/test_coupon_board.py` prove each witness sits ON its floor (move it
0.02 mm and exactly the right GC check fires).

### DFM furniture

- **Slot cutout** 3×6 mm mid-board — Edge.Cuts second contour; routing
  obstacle; copper-to-edge [0.2] measured against its edges by GC5's cutout
  branch.
- **TP1** (`Minerva_Fixture:TP_MinAnnular_0p6`) — the minimum-annular
  witness: library land 0.96 / drill 0.6 → the **fabricated** ring is the
  0.18 floor, not merely the checked one (bug `019fe3736334` is why an
  inline annulus override was the wrong vehicle). Also anchors NET_CHAIN,
  the via daisy chain (3 vias, drill 0.3 / land 0.66 [annular 0.18],
  2.0 mm pitch → 1.7 mm hole-to-hole [0.45 floor, pad figure]).
- **TP2/TP3** — anchor NET_LAD1/NET_LAD2: the trace-width ladder (0.10 /
  0.15 / 0.20 runs [min width 0.10]), the min-clearance pair (two 0.10 runs
  at 0.10 edge gap [0.10], authored at y 1.25/1.45 — **f32 note**: the pair's
  values are chosen so the panel's 32-bit coordinate truncation rounds the
  gap UP; floor-exact 1.2/1.4 truncated to 0.09999997 and the promote gate
  rightly refused), the copper-to-edge witness (copper edge exactly 0.20
  from the board edge [0.20]), and the slot-edge witness (copper edge
  exactly 0.20 from the cutout edge [0.20], terminated by a displaced via).
  Ladder stubs terminate on closing bars; NET_LAD2's finger closes as a
  loop — **no endpoint on this board dangles** (the promote gate's
  connectivity DRC lints dangling ends, and it is right to).
- **DAM1** (`Minerva_Fixture:DAM_MinWeb_2P`) — two 0.6×0.8 pads at 0.2
  copper gap; with the 0.05/side mask allowance the solder-mask dam is
  exactly 0.10 [min dam 0.10]. Pads netless by design.
- **FID1-3** (`Minerva_Fixture:FID_Circle_1mm`) — bare-copper fiducials
  (1.0 dot, 2.0 mask opening, no paste), assembly-alignment triangle.
- **LOGO1** (`Minerva_Fixture:LOGO_Owl_TestCoupon`) — silk furniture: a
  stroke-art owl exercising all four silk primitive classes + "TEST COUPON"
  stroke text at 0.15 [silk min 0.15].

### The co-designed copper (the S7 round)

NET_A and NET_B were **not authored in YAML** — they were designed through
the co-working draft loop (route intents + sculpted bends → workspace
candidates → candidate surgery → check → commit) and landed in this file by
the first real promote:

- **NET_A** (J1.1→C1.1, F.Cu): a four-column full-height serpentine through
  the west chamber, then a passage that outlines the slot's south and west
  faces into C1.1.
- **NET_B** (J1.2→C1.2): B.Cu from J1.2, running east through the channel
  between the slot's copper-to-edge band and the keepout's north face, then
  rising through its via to the top-only C1.2. The keepout (net-scoped to
  NET_A) and the NET_B return pour (south-west quadrant, ties to J1.2's
  barrel) entered as staged drafts and were batch-accepted.

  **Read the keepout's effect carefully** (bug `019fe381c526`): the router
  ignores a keepout's net scope and blocks every net, so this NET_A-scoped
  keepout *did* constrain the NET_B route — while zone fill *does* honour
  the scope, so the NET_B pour fills straight through the same region. Both
  behaviours are visible in the goldens. When the router is fixed, this
  route's shape becomes corridor-driven only; the promoted copper does not
  change, only the explanation.

## Assembly

Bare-board fab coupon: everything except J1/C1 carries `assembly: exclude`
(docket `019fe2fb07f8`); J1/C1 carry obviously-synthetic `TEST-*` mpns so
BOM/CPL generation is exercised without naming real orderable parts.

## Round-trip invariants (verified at promote)

- Promote is **idempotent**: consecutive promotes from a live board produce
  byte-identical files (digest-checked).
- Components carry ONLY design intent (the panel strips its render-detail
  keys at the promote seam; unknown canonical keys ride the model's
  Extra-style passthrough both ways).
- Compile is clean under `jlcpcb-2layer` and geometric + connectivity DRC
  are determinately clean (`tests/test_coupon_board.py`).

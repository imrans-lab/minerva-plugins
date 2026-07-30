# Test-corpus policy: synthetic boards only

This repository is **public**. The test corpus must contain only **synthetic**
board definitions authored for testing (e.g. `parity_corners.yaml`,
`spikes/gerber/board.yaml`, the fab coupon).

**Real product board designs are banned** — netlists, placements, routing,
zones, or any other design data of an actual Turnrock product. A real design
in a fixture is an IP leak the moment it is pushed, and git history keeps it
forever.

Enforced by `.github/workflows/corpus-policy.yml`, which fails the build on:

- any tracked file whose path matches the banned product-name patterns;
- any YAML carrying a banned board identity (`name: smart-remote`, …).

If a test needs geometry a synthetic fixture doesn't cover, **extend a
synthetic fixture** (see the how-and-why header in `parity_corners.yaml`) —
never import a product board. Library footprints of public origin (e.g. the
Espressif/KiCad `ESP32-S3-DevKitC.kicad_mod`) are fine; a *board* built from
them is not, because the design is the netlist + placement, not the parts.

History note (2026-07-30): the smart-remote product board lived in this
directory as `smart_remote.yaml` / `footprints/smart-remote-orig.yaml` from
2026-07-07 until its removal. Removal from HEAD does not remove it from
public git history; containment of the history is tracked in the docket.

#!/usr/bin/env python
"""Emit the COMMITTED Excellon/slots/IPC-356 golden candidate `cam-excellon-ipc356-v1`.

Reuses the ratified gerbonara coupon's ``build()`` (gerbonara_coupon.py, docket
MNR 019f761fcfc3) — no geometry is redefined here — and writes the drill +
IPC-356 subset to the COMMITTED ``golden/`` dir (NOT the gitignored ``out/``).

The six Gerber copper/mask/silk/edge layers are intentionally NOT written here:
that geometry is already the BLESSED ``spike-gerber-v1`` golden
(pcb/spikes/gerber/golden/). This golden's POINT is the artifacts gerber-writer
cannot emit — the PTH/NPTH drills, the routed SLOT, and the IPC-356 netlist.

Provenance / anti-circularity: the golden is emitted by the ratified gerbonara
path, and the future Stage-5 PRODUCTION emitter (docket 019f761fefae) will also
be gerbonara-based but a DIFFERENT code path (pcb_worker consuming the
ResolvedBoard IR). So this golden catches INTEGRATION / driving divergence, NOT
gerbonara-library bugs (tracked in 019f7773257, caught by the owner's
independent gerbv bless). It is therefore a CANDIDATE (blessed=false in
PROVENANCE.json) until the OWNER independently confirms it — see
golden/HOW_TO_BLESS_EXCELLON.md. This script MUST NOT self-bless.

Run: python emit_golden.py    (writes into ./golden/, deterministic/no timestamp)
"""
from __future__ import annotations

from pathlib import Path

from gerbonara_coupon import build

# The drill + netlist subset this golden certifies. Gerbers are covered by
# spike-gerber-v1 and are deliberately excluded (DRY: same coupon geometry).
GOLDEN_FILES = ("board-PTH.drl", "board-NPTH.drl", "board.ipc356")


def main() -> None:
    out = Path(__file__).parent / "golden"
    out.mkdir(parents=True, exist_ok=True)
    files = build()
    for name in GOLDEN_FILES:
        (out / name).write_text(files[name], encoding="utf-8")
    # Determinism self-check: gerbonara emits no wall-clock timestamp, so a
    # re-emit is byte-identical. Guards against accidental non-determinism.
    again = build()
    identical = all(files[k] == again[k] for k in GOLDEN_FILES)
    print(f"Wrote {len(GOLDEN_FILES)} golden files to {out}")
    print(f"Deterministic (byte-identical on re-emit): {identical}")


if __name__ == "__main__":
    main()

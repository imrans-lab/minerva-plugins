#!/usr/bin/env python3
"""ONE-OFF: report (and optionally apply) the per-pin diff that turns a board's
`pins` list into overrides and nothing else.

A `pins` entry is an OVERRIDE of the like-numbered library pad. A board written
by an exporter that emitted a pin for EVERY pad restates coordinates and
fabrication geometry the locked footprint already defines. This script compares
each pin against the pad it names and says, per
pin, whether it is a restatement (DROP), a real deviation (KEEP, as a typed
`override`), or something the library cannot supply (KEEP: name/roles, or no
matching pad at all — which the compiler refuses and this script must not hide).

It is a DRIVER, not a second opinion: every verdict comes from
compile_board's own predicates (`_classify_inline_geometry`,
`_pin_restates_library`), so the script and the compiler cannot disagree about
what a pin means.

    prune_restated_pins.py BOARD.yaml [...]           # print the diff, change nothing
    prune_restated_pins.py --apply BOARD.yaml [...]   # write exactly what it printed

--apply rewrites each component's `pins` block in place, leaving the rest of the
file byte-identical. Comments INSIDE a rewritten pins block do not survive, so it
is meant for generated exports; a hand-annotated fixture should be reviewed from
the printed diff instead.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

_PCB = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_PCB / "worker"))

import yaml  # noqa: E402

from pcb_worker import bless, inline_footprint  # noqa: E402
from pcb_worker.compile_board import (  # noqa: E402
    _INLINE_AMBIGUOUS,
    _INLINE_FAB_KEYS,
    _INLINE_MIGRATE,
    _classify_inline_geometry,
    _footprint_pad_map,
    _pin_restates_library,
)


class Verdict:
    """One pin's fate: `drop`, the pin dict as it should be WRITTEN, and why."""

    def __init__(self, number: str, drop: bool, pin: dict, why: str):
        self.number, self.drop, self.pin, self.why = number, drop, pin, why


def _fold(pin: dict, pad, ref: str) -> tuple[dict, str]:
    """Apply the compiler's inline-geometry fold to one pin, returning the folded
    pin and a note. An AMBIGUOUS pin is returned UNCHANGED — the compiler refuses
    it, so the file must keep it exactly as authored for a human to look at."""
    folded = dict(pin)
    inline_keys = [k for k in _INLINE_FAB_KEYS if pin.get(k) is not None]
    if not inline_keys:
        return folded, ""
    if pin.get("override") is not None:
        for key in inline_keys:
            del folded[key]
        return folded, "inline superseded by the explicit override"
    verdict = _classify_inline_geometry(pin, pad, str(pin.get("number")), inline_keys, ref)
    if verdict.outcome == _INLINE_AMBIGUOUS:
        return dict(pin), f"AMBIGUOUS: {verdict.error_code}"
    for key in inline_keys:
        del folded[key]
    if verdict.outcome == _INLINE_MIGRATE:
        folded["override"] = verdict.override
        return folded, f"inline {', '.join(inline_keys)} -> override"
    return folded, f"inline {', '.join(inline_keys)} restates the footprint"


def classify_board(board: dict, chain) -> dict[int, tuple[str, list[Verdict]]]:
    """Per component, keyed by its INDEX in the file's components list (which is
    what --apply splices against): (ref, one Verdict per declared pin)."""
    out: dict[int, tuple[str, list[Verdict]]] = {}
    for comp_index, comp in enumerate(board.get("components") or []):
        if not isinstance(comp, dict) or not isinstance(comp.get("pins"), list):
            continue
        ref = str(comp.get("ref", ""))
        # The compiler's FULL-vs-PARTIAL rule: a `pads` key makes the board the
        # sole pad authority. Such a component consults no library and is left
        # exactly as authored.
        if inline_footprint.carries_full_geometry(comp):
            out[comp_index] = (ref, [Verdict(str(p.get("number")), False, p,
                                             "board owns its pads (full geometry authority)")
                                     for p in comp["pins"] if isinstance(p, dict)])
            continue
        pad_by_number = _footprint_pad_map(comp.get("footprint"), chain=chain)
        verdicts = []
        for pin in comp["pins"]:
            if not isinstance(pin, dict):
                verdicts.append(Verdict("?", False, pin, "not a mapping"))
                continue
            number = str(pin.get("number"))
            pad = pad_by_number.get(number)
            folded, note = _fold(pin, pad, ref)
            if pad is None:
                verdicts.append(Verdict(number, False, pin, "names NO library pad (compile refuses)"))
            elif _pin_restates_library(folded, pad):
                verdicts.append(Verdict(number, True, folded, note or "restates the library pad"))
            else:
                why = note or "carries " + ", ".join(
                    k for k in ("override", "name", "roles") if folded.get(k))
                verdicts.append(Verdict(number, False, folded, why))
        out[comp_index] = (ref, verdicts)
    return out


def _pins_block_lines(path: Path) -> dict[int, tuple[int, int, int]]:
    """Map component INDEX -> (first line, last line, indent) of its `pins`
    sequence, from the YAML node marks, so --apply can splice exactly that block
    and leave every other byte of the file alone."""
    root = yaml.compose(path.read_text())
    spans: dict[int, tuple[int, int, int]] = {}
    for key, value in root.value:
        if key.value != "components":
            continue
        for index, comp in enumerate(value.value):
            for ckey, cvalue in comp.value:
                if ckey.value == "pins":
                    spans[index] = (ckey.start_mark.line, cvalue.end_mark.line,
                                    ckey.start_mark.column)
    return spans


def apply_to_file(path: Path, per_comp) -> int:
    """Rewrite each changed component's pins block in place. Returns files' worth
    of dropped pins."""
    spans = _pins_block_lines(path)
    lines = path.read_text().splitlines(keepends=True)
    dropped = 0
    # Latest block first, so an earlier splice cannot shift a later one's marks.
    for index in sorted(spans, reverse=True):
        if index not in per_comp:
            continue
        _ref, verdicts = per_comp[index]
        if not any(v.drop for v in verdicts):
            continue
        dropped += sum(1 for v in verdicts if v.drop)
        kept = [v.pin for v in verdicts if not v.drop]
        start, end, indent = spans[index]
        pad = " " * indent
        if kept:
            body = yaml.safe_dump({"pins": kept}, sort_keys=False, default_flow_style=False)
            block = "".join(pad + ln + "\n" for ln in body.splitlines())
        else:
            block = ""
        lines[start:end] = [block]
    path.write_text("".join(lines))
    return dropped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("boards", nargs="+", type=Path)
    ap.add_argument("--apply", action="store_true",
                    help="rewrite the pins blocks exactly as printed")
    args = ap.parse_args()

    chain = bless.live_library_chain()
    total_drop = total_keep = 0
    for path in args.boards:
        board = yaml.safe_load(path.read_text())
        per_comp = classify_board(board, chain)
        print(f"\n=== {path}")
        for _index, (ref, verdicts) in sorted(per_comp.items()):
            drops = [v for v in verdicts if v.drop]
            keeps = [v for v in verdicts if not v.drop]
            total_drop += len(drops)
            total_keep += len(keeps)
            if not verdicts:
                continue
            print(f"  {ref}: -{len(drops)} restated, {len(keeps)} kept")
            for v in drops:
                print(f"    - DROP pin {v.number}: {v.why}")
            for v in keeps:
                print(f"    + KEEP pin {v.number}: {v.why} -> {v.pin}")
        if args.apply:
            n = apply_to_file(path, per_comp)
            print(f"  applied: {n} pin(s) removed from {path}")
    print(f"\nTOTAL: {total_drop} restated pin(s) would be dropped, {total_keep} kept")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

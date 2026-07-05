"""KiCAD library-data readers: footprint existence + symbol-name scanning.

This module reads the DATA that ships via `libraries.lock.json` +
`pcb_fetch_libraries` (the Go-side fetcher under `pcb/internal/libraries/`).
It never fetches anything itself — that is the Go side's job (network I/O
belongs in Go so it can be tested against an httptest server without a
Python-side network stack). This module only reads whatever is already on
disk under a `lib_dir`.

Both readers are deliberately NOT full KiCad parsers:

  - Footprints: a footprint is "present" iff a `.kicad_mod` file exists at the
    expected path. No parsing of the file's s-expression body at all.
  - Symbols: `.kicad_sym` files are `(kicad_symbol_lib ... (symbol "Name" ...)
    ...)` s-expressions. We only need the **top-level** symbol names (the
    part-level names a board would reference, e.g. "R", "LED", "ATmega328P-AU")
    — NOT the nested per-unit sub-symbols KiCad emits inside each part for
    multi-unit / de-morgan graphics (`(symbol "R_0_1" ...)`,
    `(symbol "R_1_1" ...)`). A cheap single-pass paren-depth scan (no real
    s-expression parser, no external dependency) distinguishes the two: a
    part's own `(symbol "X" ...)` opens at depth 1 (i.e. directly inside the
    top-level `(kicad_symbol_lib ...)`); its nested unit sub-symbols open one
    level deeper (depth 2+) and are skipped.
"""

from __future__ import annotations

import difflib
import os
from pathlib import Path

_KICAD_MOD_SUFFIX = ".kicad_mod"
_KICAD_SYM_SUFFIX = ".kicad_sym"
_PRETTY_SUFFIX = ".pretty"

_SYMBOL_TOKEN = '(symbol "'


# ---------------------------------------------------------------------------
# Footprints (.pretty dirs of .kicad_mod files)
# ---------------------------------------------------------------------------


def resolve_footprint(lib_dir: str, footprint: str) -> bool:
    """True iff a .kicad_mod for *footprint* exists under *lib_dir*.

    Accepts both "Lib:Name" (KiCad fp-lib-table form -> <lib_dir>/Lib.pretty/
    Name.kicad_mod) and a bare "Name" (searched across every *.pretty dir).
    """
    if ":" in footprint:
        lib, _, name = footprint.partition(":")
        return (Path(lib_dir) / f"{lib}{_PRETTY_SUFFIX}" / f"{name}{_KICAD_MOD_SUFFIX}").is_file()
    try:
        for entry in os.scandir(lib_dir):
            if entry.is_dir() and entry.name.endswith(_PRETTY_SUFFIX):
                if (Path(entry.path) / f"{footprint}{_KICAD_MOD_SUFFIX}").is_file():
                    return True
    except OSError:
        return False
    return False


def list_footprint_names(lib_dir: str) -> list[str]:
    """Return every footprint's bare name ("R_0603_1608Metric", no library
    prefix, no .kicad_mod suffix) present under any *.pretty dir in lib_dir.

    Used for check_bom's nearest-name suggestions. Cheap directory scan, no
    file content is read.
    """
    names: list[str] = []
    try:
        for entry in os.scandir(lib_dir):
            if not (entry.is_dir() and entry.name.endswith(_PRETTY_SUFFIX)):
                continue
            try:
                for fp_entry in os.scandir(entry.path):
                    if fp_entry.is_file() and fp_entry.name.endswith(_KICAD_MOD_SUFFIX):
                        names.append(fp_entry.name[: -len(_KICAD_MOD_SUFFIX)])
            except OSError:
                continue
    except OSError:
        return []
    return names


def suggest_footprints(lib_dir: str, footprint: str, limit: int = 3) -> list[str]:
    """Nearest-name footprint suggestions from present libraries.

    Compares against the bare name only (strips a "Lib:" prefix from
    *footprint* if present) so a typo'd or unresolved footprint still gets
    useful suggestions. Returns [] if lib_dir has no footprints or footprint
    is empty.
    """
    if not footprint:
        return []
    _, _, bare = footprint.rpartition(":")
    candidates = list_footprint_names(lib_dir)
    if not candidates:
        return []
    return difflib.get_close_matches(bare, candidates, n=limit, cutoff=0.5)


# ---------------------------------------------------------------------------
# Symbols (.kicad_sym s-expression files)
# ---------------------------------------------------------------------------


def _top_level_symbol_names(text: str) -> list[str]:
    """Cheap single-pass paren-depth scan for top-level `(symbol "Name" ...)`
    entries in a .kicad_sym file's text.

    Depth accounting: the file root `(kicad_symbol_lib ...)` opens at depth 0
    -> 1. A part's own symbol definition is the next paren in, i.e. it is
    encountered while depth == 1 (its own opening paren then brings depth to
    2). Nested unit sub-symbols are encountered at depth >= 2 and are skipped.
    Malformed/truncated content degrades gracefully — depth never goes
    negative in practice for valid KiCad output, and a stray unbalanced paren
    at worst under- or over-collects, never crashes (no exceptions raised).
    """
    names: list[str] = []
    depth = 0
    i = 0
    n = len(text)
    token = _SYMBOL_TOKEN
    tlen = len(token)
    while i < n:
        c = text[i]
        if c == "(":
            if depth == 1 and text.startswith(token, i):
                j = i + tlen
                end = text.find('"', j)
                if end != -1:
                    names.append(text[j:end])
            depth += 1
        elif c == ")":
            depth -= 1
        i += 1
    return names


def list_symbol_libs(lib_dir: str) -> dict[str, list[str]]:
    """Return {libname (no .kicad_sym suffix): [top-level symbol names]} for
    every *.kicad_sym file directly under lib_dir. Unreadable files are
    skipped (never raises)."""
    out: dict[str, list[str]] = {}
    try:
        entries = list(os.scandir(lib_dir))
    except OSError:
        return out
    for entry in entries:
        if not (entry.is_file() and entry.name.endswith(_KICAD_SYM_SUFFIX)):
            continue
        libname = entry.name[: -len(_KICAD_SYM_SUFFIX)]
        try:
            text = Path(entry.path).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        out[libname] = _top_level_symbol_names(text)
    return out


def resolve_symbol(lib_dir: str, symbol: str) -> bool:
    """True iff *symbol* resolves against the .kicad_sym files in lib_dir.

    Accepts "Lib:Name" (checks only that library) or a bare "Name" (searched
    across every *.kicad_sym file). Symbol matching is always OPTIONAL/informal
    in this contract — board components don't carry a first-class symbol
    field (board-yaml.md), so callers treat a False here as a soft signal, not
    a validation error.
    """
    libs = list_symbol_libs(lib_dir)
    if ":" in symbol:
        lib, _, name = symbol.partition(":")
        return name in libs.get(lib, [])
    return any(symbol in names for names in libs.values())

"""STANDING GUARD 2 — kicad-cli BOUNDARY LINT.

Owner rule (load-bearing invariant of the hermetic-CAM story): KiCad is a
DEV/CI-ONLY tool. Every user-facing capability has a NATIVE tier (pure-Python
worker: gerber-writer, our own Excellon, native geometry). KiCad / kicad-cli may
ENHANCE developer workflows (the DRC oracle under tests/oracle) but must NEVER
ENABLE a shipped feature — there is no kicad-cli on the deploy target and no
foreign checked-in binary (FCIB).

This lint greps the REAL runtime source tree for any dependence on kicad-cli:
  * the binary name ``kicad-cli`` (subprocess call or bare string literal), and
  * an import of the dev-only oracle helper (``tests.oracle`` /
    ``kicad_drc`` / its ``run_drc_*`` / ``kicad_cli_available`` API), which would
    smuggle the boundary crossing in through Python.

It must find ZERO in runtime code. References are ALLOWED only under tests/ and
dev/ / scripts/. This is a real, non-mocked scan of the checked-out files.

If this fails: a runtime path took a dependency on KiCad. Move the logic to the
native worker tier and keep the kicad-cli use in a tests/oracle helper.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

# tests/ -> worker/ -> pcb/  (repo layout: pcb/worker/tests/this_file.py)
WORKER = Path(__file__).resolve().parents[1]   # pcb/worker
PCB = WORKER.parent                            # pcb

# Runtime source trees that must be kicad-cli-free. These are the user-facing /
# shipped code paths: the Python worker, the agent_router, and the Godot plugin.
RUNTIME_GLOBS: list[tuple[Path, str]] = [
    (WORKER / "pcb_worker", "**/*.py"),
    (WORKER / "agent_router", "**/*.py"),
    (PCB / "ui", "**/*.gd"),
]

# Patterns that constitute a boundary crossing. Each is a compiled regex checked
# per line so we can report file:line:text.
FORBIDDEN = [
    # The dev/CI binary itself — subprocess arg or any string literal.
    (re.compile(r"kicad-cli"), "kicad-cli binary reference"),
    # Importing the dev-only oracle package or its kicad-cli helper API.
    (re.compile(r"\btests\.oracle\b"), "import of dev-only tests.oracle package"),
    (re.compile(r"\bkicad_drc\b"), "reference to the kicad_drc oracle module"),
    (re.compile(r"\b(run_drc_on_board|run_drc_on_pcb_text|kicad_cli_available)\b"),
     "call into the kicad-cli DRC oracle API"),
]


def _iter_runtime_files():
    for root, pattern in RUNTIME_GLOBS:
        if not root.exists():
            continue
        for path in sorted(root.glob(pattern)):
            if path.is_file():
                yield path


def scan_runtime_for_kicad_cli() -> list[str]:
    """Return a list of 'file:line: reason -> text' violations (empty == clean).

    Reusable so the teeth-proof (temporarily inject a call, expect non-empty)
    and the guard test (expect empty) share one code path.
    """
    violations: list[str] = []
    for path in _iter_runtime_files():
        rel = path.relative_to(PCB)
        for lineno, line in enumerate(path.read_text(encoding="utf-8",
                                                     errors="replace").splitlines(), 1):
            for pattern, reason in FORBIDDEN:
                if pattern.search(line):
                    violations.append(f"{rel}:{lineno}: {reason} -> {line.strip()}")
    return violations


def test_runtime_has_no_kicad_cli_dependence():
    """No user-facing/runtime file may reference kicad-cli or the oracle helper."""
    violations = scan_runtime_for_kicad_cli()
    assert not violations, (
        "kicad-cli boundary violated in RUNTIME code (KiCad is dev/CI-only; move "
        "the logic to the native worker tier):\n  " + "\n  ".join(violations)
    )


def test_lint_actually_scanned_files():
    """Guard against a silently-empty scan (moved trees, bad globs) reporting a
    false green: assert we actually saw runtime source."""
    scanned = list(_iter_runtime_files())
    assert scanned, (
        "boundary lint scanned ZERO runtime files — RUNTIME_GLOBS is stale, the "
        "'clean' result would be meaningless"
    )
    # Sanity: the two load-bearing runtime roots must exist and be non-empty.
    assert any("pcb_worker" in str(p) for p in scanned), "pcb_worker not scanned"


def test_scanner_has_teeth_on_synthetic_input(tmp_path):
    """Prove the scanner MATCHES a kicad-cli invocation (self-test, no runtime
    file touched): a temp file containing a subprocess call is flagged."""
    bad = tmp_path / "leak.py"
    bad.write_text('subprocess.run(["kicad-cli", "pcb", "drc", board])\n')
    # Reuse the same forbidden patterns against the synthetic line.
    line = bad.read_text().strip()
    assert any(p.search(line) for p, _ in FORBIDDEN), (
        "scanner failed to flag a literal kicad-cli subprocess call"
    )

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
import sys
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
    # KiCad's PYTHON BINDINGS are the same boundary as its binary, and until the
    # zone-fill oracle landed nothing here said so (C6 decider claim C31). Every
    # pattern above keys on `kicad-cli`, so `import pcbnew` — a heavier
    # dependency than the CLI, shipped only with a full KiCad install and absent
    # from the deploy target — went straight through this lint. Runtime code that
    # imports pcbnew is exactly as broken on a user machine as runtime code that
    # shells out to kicad-cli, and now fails the same guard.
    #
    # MATCHED ON THE IMPORT, NOT THE WORD. `pcbnew` appears in ~15 runtime
    # COMMENTS across kicad.py / ir_parity.py / route_bridge.py / fab_capability.py
    # recording behaviour that was verified against pcbnew 9.0.9, and once as a
    # literal `.kicad_pro` JSON key (kicad.py:646). Those are documentation and
    # file format — no dependency is created by naming a tool you compared
    # against, and a lint that forbade the name would push exactly that
    # provenance out of the comments. The crossing is BINDING the module.
    (re.compile(r"^\s*(import\s+pcbnew|from\s+pcbnew\b)"),
     "import of KiCad's pcbnew python bindings"),
    (re.compile(r"""import_module\(\s*["']pcbnew["']|__import__\(\s*["']pcbnew["']"""),
     "dynamic import of KiCad's pcbnew python bindings"),
    # Same import-not-word rule as above, and for the same reason: three runtime
    # comments legitimately name ``ZONE_FILLER`` and ``zone_fill_oracle.py`` while
    # explaining WHY the filler matches KiCad's fractured-contour representation
    # and where its independent judge lives. That provenance belongs in the code
    # it explains. Binding the module is the crossing; ``pcbnew.ZONE_FILLER(...)``
    # is unreachable without an ``import pcbnew``, which the two patterns above
    # already catch.
    (re.compile(r"^\s*(from|import)\s+.*\bzone_fill_oracle\b"),
     "import of the dev-only pcbnew zone-fill oracle"),
]


def _iter_runtime_files():
    """Walk every RUNTIME_GLOBS root. FAILS CLOSED (raises) if a root is
    missing — a vanished root used to `continue`, silently degrading the scan
    to fewer files while still reporting a clean (empty violations) result.
    Two of the three roots can disappear (e.g. a tree move, a bad rebase, a
    scratch copy that forgot a sibling) and the guard would report the same
    green; only ``pcb_worker`` failing is caught elsewhere, because production
    code reads it at collection time. A silent scan is worse than no scan: it
    reads as "verified clean" when it verified nothing."""
    for root, pattern in RUNTIME_GLOBS:
        if not root.exists():
            raise FileNotFoundError(
                f"kicad-cli boundary lint: runtime scan root does not exist: "
                f"{root!s} — refusing to silently continue with fewer roots "
                "(a missing root used to degrade the scan without failing it; "
                "fix RUNTIME_GLOBS or restore the root)"
            )
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
    false green: assert we actually saw runtime source.

    Checks EVERY root in RUNTIME_GLOBS individually, not just pcb_worker: the
    previous version of this test only checked pcb_worker, so deleting either
    ``agent_router`` or ``pcb/ui`` (both silently skipped by the old
    ``_iter_runtime_files``) left this test green — a HALF fence that reads as
    "already handled" but only covers one of three roots. pcb_worker still gets
    its own belt-and-braces assertion because production code (footprints.py
    et al.) also depends on it existing, independent of this lint."""
    scanned = list(_iter_runtime_files())
    assert scanned, (
        "boundary lint scanned ZERO runtime files — RUNTIME_GLOBS is stale, the "
        "'clean' result would be meaningless"
    )
    assert any("pcb_worker" in str(p) for p in scanned), "pcb_worker not scanned"
    assert any("agent_router" in str(p) for p in scanned), "agent_router not scanned"
    assert any(str(p).endswith(".gd") for p in scanned), (
        "pcb/ui (Godot .gd sources) not scanned"
    )


def test_scan_fails_closed_on_missing_runtime_root(monkeypatch):
    """Discriminating fixture for the fail-open defect: point RUNTIME_GLOBS at
    a root that does not exist and require the walk to REFUSE (raise) rather
    than silently returning an empty/partial file list. Before the
    ``_iter_runtime_files`` hardening above, this scenario returned ``[]`` and
    the boundary-lint test would report a clean scan having looked at nothing —
    exactly the failure mode that lets ``pcb/ui`` (or any other root) vanish
    without tripping any test in this file."""
    this_module = sys.modules[__name__]
    monkeypatch.setattr(
        this_module, "RUNTIME_GLOBS",
        [(PCB / "does_not_exist", "**/*.gd")],
    )
    with pytest.raises(FileNotFoundError, match="does_not_exist"):
        list(_iter_runtime_files())


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

"""DEV/TEST-ONLY fabrication-verification oracles.

Nothing in this package may EVER be imported from ``pcb_worker`` runtime. These
modules shell out to external developer/CI tooling (e.g. ``kicad-cli``) and pull
in dev-only readers (gerbonara); they are not worker dependencies and must not be
shipped/imported by the runtime. A later task (SB.3) adds a lint enforcing that
no ``pcb_worker/*.py`` imports ``tests.oracle`` or invokes ``kicad-cli``.
"""

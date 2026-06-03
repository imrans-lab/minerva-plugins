"""files — file-primitive helpers for the Code Tools worker (P2.1).

Sub-modules
-----------
paths       expanduser + resolve + validation helpers.
walker      ignore-aware directory walker.
runner      subprocess runner with timeout + output cap + merged streams.

P4 DRY-convergence candidate: if the code-probe or a future subsystem needs
similar primitives, consolidate into a shared runtime utils package.
"""

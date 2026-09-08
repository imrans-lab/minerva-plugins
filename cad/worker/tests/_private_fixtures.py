"""Locates the private smart-remote-v2 enclosure fixture set.

The real product shell never lives in this public repo (owner ruling
2026-09-07; see pcb/worker/tests/testdata/POLICY.md). The self-contained set —
three enclosure .mcad revisions, the stand-in part meshes and the board GLB —
sits in the owner's private sandbox repo, and MCAD_PRIVATE_FIXTURES points at
that directory. Tests that pose the real shell call
private_enclosure_fixtures() and skip when the set is absent, so public CI
still runs everything synthetic.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

_SKIP = "MCAD_PRIVATE_FIXTURES does not point at the private enclosure fixture set"


def private_enclosure_fixtures(*, module: bool = False) -> Path:
    root = os.environ.get("MCAD_PRIVATE_FIXTURES")
    if not root or not Path(root).is_dir():
        pytest.skip(_SKIP, allow_module_level=module)
    return Path(root)

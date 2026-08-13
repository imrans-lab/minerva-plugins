"""THE plugin-root resolution for shipped worker data (epoch GA-4).

One derivation, imported by every module that needs the plugin root
(``footprints.py``, ``manufacturer_profile.py`` — "do not invent a second
root for shipped worker data").

Two layouts exist:

* DEV TREE — this package lives at ``pcb/worker/pcb_worker/``, so the plugin
  root (the dir holding ``library/``) is two levels up from the package.
* MARKETPLACE BINARY INSTALL — this package is copied into the extracted
  runtime bundle's ``site-packages/``, where ``parents[2]`` resolves into the
  bundle and the seed library is NOT there: the tarball ships ``library/``
  beside the plugin binary. The Go side is the one place that knows that
  directory, and states it via ``MINERVA_PCB_ROOT`` (set in
  ``pcb/main.go`` ``initWorker`` through the bridge's ExtraEnv).

The env override wins when present and non-empty; the source-tree layout is
the fallback, byte-identical to the old per-module ``parents[2]`` constant.
"""

from __future__ import annotations

import os
from pathlib import Path


def plugin_root() -> Path:
    override = os.environ.get("MINERVA_PCB_ROOT", "").strip()
    if override:
        return Path(override)
    # pcb/worker/pcb_worker/plugin_root.py -> pcb/
    return Path(__file__).resolve().parents[2]


PCB_ROOT = plugin_root()

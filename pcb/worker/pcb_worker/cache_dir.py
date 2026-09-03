"""THE cache-directory derivation for regenerable worker data.

One place for data the worker FETCHED or DERIVED and can always rebuild —
vendor downloads, expensive renders, parsed intermediates. It is deliberately
neither the repository (committing regenerable binaries is forbidden) nor the
installed bundle (a reinstall replaces that tree, so anything written there is
lost).

GO RESOLVES IT, PYTHON READS IT
-------------------------------
``pcb/main.go`` ``initWorker`` calls ``sharedruntime.EnsureCacheDir`` and
states the result via ``MINERVA_PCB_CACHE_DIR`` through the bridge's ExtraEnv,
exactly as it states the plugin root via ``MINERVA_PCB_ROOT`` (see
``plugin_root.py``). This module reads that variable AND NOTHING ELSE. It does
not consult platformdirs, and it does not hand-roll per-OS logic: two
independent resolvers eventually disagree about which directory a given
machine is using, and that disagreement is the whole bug this design avoids.

So an absent variable means "no cache is available", never "go find one".

THE CONTRACT
------------
* Nothing here is a source of truth. A missing entry is refetched or
  recomputed. Source-of-truth data belongs in the repo or in plugin data.
* Deleting the whole tree at any moment leaves the worker working — which is
  why ``tenant_dir`` recreates its directory on every call rather than
  trusting a directory that existed at startup.
* An unavailable or unwritable cache degrades to no caching, reported through
  the log. Callers get ``None`` and must carry on without a cache.
* Entries are namespaced by TENANT, so one tenant cannot collide with another.

NOTE ON "SAFE TO DELETE": the Go side hangs this off the platform DATA
directory (XDG_DATA_HOME / Application Support / %APPDATA%), not an OS cache
directory. Disposability is a promise this contract makes, not something
inherited from a platform convention — no OS housekeeping will clean it up.
"""

from __future__ import annotations

import logging
import os
import re
from pathlib import Path

log = logging.getLogger(__name__)

ENV_VAR = "MINERVA_PCB_CACHE_DIR"

# A tenant name is a single path segment: lowercase, no separators, no dots,
# so it can never traverse out of the cache root or collide by case on a
# case-insensitive filesystem.
_TENANT_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


def cache_root() -> Path | None:
    """Return the cache root the Go side handed us, or None when it handed us
    nothing (no cache available — do not invent one)."""
    stated = os.environ.get(ENV_VAR, "").strip()
    if not stated:
        return None
    return Path(stated)


def tenant_dir(tenant: str) -> Path | None:
    """Return an existing, per-tenant directory under the cache root, or None
    when caching is unavailable.

    None is a normal outcome, not an error: the variable may be absent, the
    tree may have been deleted, or the location may be unwritable. Callers
    must treat None as "run without a cache".

    The directory is created on every call, so a tree deleted mid-life is
    simply rebuilt on next use.

    Raises ValueError only for a malformed *tenant* name, which is a caller
    bug in a source literal rather than a property of the environment — the
    "never raise" rule covers the location, not typos in our own code.
    """
    if not _TENANT_RE.match(tenant):
        raise ValueError(
            f"invalid cache tenant {tenant!r}: expected a single lowercase "
            f"path segment matching {_TENANT_RE.pattern}")
    root = cache_root()
    if root is None:
        log.debug("cache unavailable: %s is not set — %s will not be cached",
                  ENV_VAR, tenant)
        return None
    path = root / tenant
    try:
        path.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        log.warning("cache unavailable at %s (%s) — %s will not be cached",
                    path, exc, tenant)
        return None
    return path

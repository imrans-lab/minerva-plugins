"""The regenerable-data cache: Go states it, Python only reads it.

Few and wide by design. One test per oracle that actually distinguishes a
working design from a broken one:

* Python reports the directory it was HANDED, and reports None when it was
  handed nothing — never a directory it resolved itself. A second resolver
  (platformdirs, or hand-rolled per-OS logic) is the failure this design
  exists to prevent, and it would show up here as a non-None answer with the
  variable absent.
* Deleting the tree mid-life leaves the worker working.
* An unwritable location degrades to no caching instead of raising.
* Tenants cannot collide, and cannot escape the root.
* The variable name Python reads is the one the Go side actually writes.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

import pytest

from pcb_worker import cache_dir


def test_reports_the_directory_it_was_handed(monkeypatch, tmp_path):
    """The whole contract on the happy path: the root is the stated one, a
    tenant is a real created child of it, and two tenants cannot collide."""
    root = tmp_path / "cache"
    monkeypatch.setenv(cache_dir.ENV_VAR, str(root))

    assert cache_dir.cache_root() == root

    parts = cache_dir.tenant_dir("part-models")
    other = cache_dir.tenant_dir("renders")
    assert parts == root / "part-models"
    assert other == root / "renders"
    assert parts.is_dir() and other.is_dir()
    assert parts != other

    # A tenant name is one path segment — it can never escape the root.
    for bad in ("../escape", "a/b", "Part-Models", "", ".hidden"):
        with pytest.raises(ValueError):
            cache_dir.tenant_dir(bad)


def test_reports_none_when_the_variable_is_absent(monkeypatch):
    """Absent, empty and whitespace-only all mean 'no cache available'. The
    oracle is that Python does NOT produce a path: a resolver of its own would
    return one here, and the two resolvers would eventually disagree."""
    monkeypatch.delenv(cache_dir.ENV_VAR, raising=False)
    assert cache_dir.cache_root() is None
    assert cache_dir.tenant_dir("part-models") is None

    for blank in ("", "   "):
        monkeypatch.setenv(cache_dir.ENV_VAR, blank)
        assert cache_dir.cache_root() is None
        assert cache_dir.tenant_dir("part-models") is None


def test_deleting_the_tree_mid_life_leaves_it_working(monkeypatch, tmp_path):
    """Nothing here is a source of truth, so a tree that vanishes between two
    calls must simply be rebuilt — no error, no stale handle."""
    root = tmp_path / "cache"
    monkeypatch.setenv(cache_dir.ENV_VAR, str(root))

    first = cache_dir.tenant_dir("part-models")
    (first / "vendor-model.step").write_text("regenerable")

    shutil.rmtree(root)
    assert not root.exists()

    second = cache_dir.tenant_dir("part-models")
    assert second == first
    assert second.is_dir()
    # The entry is gone — which is fine, it is refetched — but the place to
    # put it back is usable again.
    assert not (second / "vendor-model.step").exists()
    (second / "vendor-model.step").write_text("refetched")


@pytest.mark.skipif(sys.platform == "win32",
                    reason="POSIX mode bits do not gate directory creation on Windows")
@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0,
                    reason="root ignores mode bits, so the location cannot be made unwritable")
def test_unwritable_location_degrades_to_no_caching(monkeypatch, tmp_path):
    """A real read-only directory, not a mocked one. Work must still complete:
    the caller gets None and carries on uncached."""
    root = tmp_path / "cache"
    root.mkdir()
    root.chmod(0o500)
    try:
        monkeypatch.setenv(cache_dir.ENV_VAR, str(root))
        # No exception, and no path handed back that cannot be written to.
        assert cache_dir.tenant_dir("part-models") is None
        # The root itself is still reported — "where it would go" is knowable
        # even when it is unusable.
        assert cache_dir.cache_root() == root
    finally:
        root.chmod(0o700)


def test_go_writes_the_variable_python_reads():
    """The handoff is a wire contract across two languages, so nothing else in
    either test suite can catch a rename on one side. The oracle is the Go
    source that actually sets the worker's environment."""
    # tests/ -> worker/ -> pcb/ (never MINERVA_PCB_ROOT: this asserts a fact
    # about the SOURCE tree, and must not follow an env override).
    pcb = Path(__file__).resolve().parents[2]
    main_go = (pcb / "main.go").read_text()
    assert f"{cache_dir.ENV_VAR}=" in main_go, (
        f"{cache_dir.ENV_VAR} is not set anywhere in pcb/main.go — the worker "
        f"would silently never cache")
    # And the cache travels beside the plugin root, in the same ExtraEnv.
    assert "MINERVA_PCB_ROOT=" in main_go

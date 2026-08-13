"""Epoch GA-4 — the ONE plugin-root derivation for shipped worker data.

In a dev tree the root is two levels above the package; in a marketplace
binary install the package runs from inside the extracted runtime bundle's
site-packages, where that relative walk lands INSIDE the bundle — so the Go
side (the one place that knows the plugin dir the tarball unpacked to)
states it via MINERVA_PCB_ROOT. These tests pin both halves and the
consumers' agreement on a single root.
"""

from __future__ import annotations

from pathlib import Path

from pcb_worker import footprints, manufacturer_profile, plugin_root


def test_dev_tree_fallback_is_the_package_grandparent(monkeypatch):
    monkeypatch.delenv("MINERVA_PCB_ROOT", raising=False)
    root = plugin_root.plugin_root()
    # pcb/worker/pcb_worker/plugin_root.py -> pcb/
    assert root == Path(plugin_root.__file__).resolve().parents[2]
    assert (root / "library" / "footprints.lock.json").exists(), (
        "the dev-tree fallback must land on the dir that actually holds the "
        "seed library")


def test_env_override_wins(monkeypatch, tmp_path):
    monkeypatch.setenv("MINERVA_PCB_ROOT", str(tmp_path))
    assert plugin_root.plugin_root() == tmp_path


def test_blank_override_is_ignored(monkeypatch):
    # An empty/whitespace env value is "not set", never Path("") (which would
    # resolve every data file relative to the worker's cwd — silently).
    monkeypatch.setenv("MINERVA_PCB_ROOT", "  ")
    assert plugin_root.plugin_root() == Path(
        plugin_root.__file__).resolve().parents[2]


def test_both_consumers_share_the_one_root():
    """footprints and manufacturer_profile must derive from the SAME root —
    'do not invent a second root for shipped worker data'. Import-time
    constants, so this pins the module wiring rather than re-deriving."""
    assert footprints._PCB_ROOT == manufacturer_profile._PCB_ROOT
    assert footprints.DEFAULT_LIBRARY_ROOT == \
        footprints._PCB_ROOT / "library" / "footprints"
    assert manufacturer_profile.DEFAULT_PROFILE_ROOT == \
        manufacturer_profile._PCB_ROOT / "library" / "profiles"

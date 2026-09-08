"""The smart-remote-v2 enclosure fixture set, private to the owner's sandbox.

The real shell never lives in this public repo (owner ruling 2026-09-07); the
set MCAD_PRIVATE_FIXTURES points at carries the three enclosure revisions, the
six stand-in part meshes and the board GLB that every filed geometry-check
reproduction names. Two things have to stay true for those reproductions to run
from a checkout:

* every path a `mesh()` call names resolves inside the fixture tree, because the
  panel loads them relative to the .mcad file; and
* the newest revision still evaluates.

ORACLE. The evaluation numbers are the worker's own result for the fixture as
stored in the private set, not a count read off the source. Rev 3 unions a tray, a top shell, a
battery door and four keycaps; the fused result is six solids, because the
keycap over SW1 touches the shell at its notch and fuses into it.
`reference_count` is one per `mesh()` binding. An independent observation that
would show this wrong is opening the exported STEP/STL in a CAD tool and
counting the loose solids.

The worker never opens a referenced mesh file (see mcad/reference.py), so this
test needs no live Minerva and no GPU — the same document in the panel would.
"""

from __future__ import annotations

import re

import pytest

pytest.importorskip("build123d", reason="build123d not installed in this environment")

from mcad.evaluator import evaluate_source  # noqa: E402

from tests._private_fixtures import private_enclosure_fixtures  # noqa: E402

FIXTURES = private_enclosure_fixtures(module=True)
REVISIONS = ("enclosure-rev1.mcad", "enclosure.mcad", "enclosure-rev3.mcad")

# mesh("<path>", ...) — the first string literal of the call is the file.
_MESH_PATH = re.compile(r'mesh\(\s*"([^"]+)"')


@pytest.mark.parametrize("name", REVISIONS)
def test_every_mesh_reference_resolves_inside_the_fixture_tree(name: str) -> None:
    source = (FIXTURES / name).read_text(encoding="utf-8")
    paths = _MESH_PATH.findall(source)
    assert len(paths) == 6, f"{name} should pose the board plus five off-board parts"
    for path in paths:
        assert (FIXTURES / path).is_file(), f"{name} references missing {path}"


def test_rev3_evaluates_with_six_bodies_and_six_references() -> None:
    result = evaluate_source((FIXTURES / "enclosure-rev3.mcad").read_text(encoding="utf-8"))
    assert result.shape_name == "enclosure"
    assert result.body_count == 6
    assert len(result.references) == 6

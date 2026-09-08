"""Exporting a document the panel has already rendered.

An export used to translate the whole DSL again, so a heavy document — a
lofted shell of ~60 booleans — rendered in the panel and then failed to export
inside the MCP client's window. The evaluation now leaves the part it built
behind, keyed by a digest of the source, and an export of that same source
writes the file from it.

ORACLE. Two independent observations, either of which shows a wrong
implementation:

  * The translation counter. `mcad.evaluator.Translator` is the one door every
    build goes through, so counting its construction counts evaluations
    directly: an export that reuses the evaluated part constructs none. An
    implementation that only *claims* to reuse (or that keys the cache
    loosely enough to miss) shows up here as a count of one.
  * The bytes on disk, against a reference export built from the source with
    no cache in play. Reuse has to be invisible in the output — a cached part
    exported for the wrong source is the failure that matters, and edited
    source exported from a stale part is caught by comparing the triangle
    count against BOTH references.
"""

from __future__ import annotations

import struct

import pytest

try:
    import build123d  # type: ignore[import]  # noqa: F401
except ImportError:
    pytest.skip(
        "build123d not installed — export cache test skipped in this environment",
        allow_module_level=True,
    )

import mcad.evaluator as evaluator
from mcad_worker import methods

# A box and a sphere: the same DSL shape by role, wildly different meshes, so
# one exported in the other's place cannot hide in a size comparison.
SRC_BOX = "part = cube(10, center=true)\n"
SRC_SPHERE = "part = sphere(r=6)\n"


def _triangles(path: str) -> int:
    """Triangle count of an STL, binary or ASCII."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:5] == b"solid" and b"facet normal" in data:
        return data.count(b"facet normal")
    return struct.unpack("<I", data[80:84])[0]


def _reference(source: str, path) -> str:
    """Export *source* the long way — the answer the cache must agree with."""
    return evaluator.export_source(source, format="stl", path=str(path))


@pytest.fixture
def translations(monkeypatch):
    """A counter over every geometry build the evaluator performs."""
    real = evaluator.Translator
    counted: list[int] = [0]

    def spy(*args, **kwargs):
        counted[0] += 1
        return real(*args, **kwargs)

    monkeypatch.setattr(evaluator, "Translator", spy)
    return counted


@pytest.fixture(autouse=True)
def _clean_caches():
    methods.reset_caches()
    yield
    methods.reset_caches()


class TestExportReusesTheEvaluatedPart:
    def test_rendered_source_exports_without_building_again(self, tmp_path, translations):
        reference = _reference(SRC_BOX, tmp_path / "reference.stl")

        evaluated = methods._evaluate({"source": SRC_BOX})
        assert evaluated["ok"], evaluated
        translations[0] = 0

        target = tmp_path / "from_cache.stl"
        reply = methods._export(
            {"source": SRC_BOX, "format": "stl", "path": str(target)}
        )
        assert reply["ok"], reply
        assert translations[0] == 0, (
            "the export built the document again instead of reusing the "
            "evaluation the panel already paid for"
        )
        assert reply["result"]["reused_evaluation"] is True
        assert reply["result"]["bytes_written"] > 0
        with open(reference, "rb") as a, open(target, "rb") as b:
            assert a.read() == b.read(), (
                "the file written from the cached part differs from the one "
                "built for this export"
            )

    def test_edited_source_is_not_exported_from_the_stale_part(self, tmp_path, translations):
        box_reference = _reference(SRC_BOX, tmp_path / "box.stl")
        sphere_reference = _reference(SRC_SPHERE, tmp_path / "sphere.stl")

        evaluated = methods._evaluate({"source": SRC_BOX})
        assert evaluated["ok"], evaluated
        translations[0] = 0

        target = tmp_path / "edited.stl"
        reply = methods._export(
            {"source": SRC_SPHERE, "format": "stl", "path": str(target)}
        )
        assert reply["ok"], reply
        assert translations[0] == 1, "source that was never evaluated must be built"
        assert reply["result"]["reused_evaluation"] is False
        assert _triangles(str(target)) == _triangles(sphere_reference)
        assert _triangles(str(target)) != _triangles(box_reference)

    def test_a_document_of_references_alone_leaves_no_part_to_export(self, tmp_path):
        """An evaluation that builds no part must not arm the export cache."""
        source = 'ref = mesh("a.glb")\n'
        evaluated = methods._evaluate({"source": source})
        assert evaluated["ok"], evaluated

        reply = methods._export(
            {"source": source, "format": "stl", "path": str(tmp_path / "empty.stl")}
        )
        assert not reply["ok"]
        assert reply["error"]["kind"] == "translate"


def test_named_bindings_share_build_and_edits_invalidate(tmp_path, translations):
    source = "bottom = cube(10,10,2)\ndoor = sphere(3)\nassembly = bottom + door\n"
    assert methods._evaluate({"source": source})["ok"]
    translations[0] = 0
    for name in ("bottom", "door", "bottom"):
        target = tmp_path / (name + ".stl")
        reply = methods._export({"source": source, "part": name, "source_version": 3,
                                 "format": "stl", "path": str(target)})
        assert reply["ok"], reply
        assert reply["result"]["part"] == name
        assert reply["result"]["source_version"] == 3
        assert reply["result"]["reused_evaluation"]
        assert target.stat().st_size > 84
    assert translations[0] == 0
    assert _triangles(str(tmp_path / "bottom.stl")) == 12
    assert _triangles(str(tmp_path / "door.stl")) > 12
    before = (tmp_path / "door.stl").read_bytes()
    edited = source.replace("sphere(3)", "cube(6,6,6)")
    reply = methods._export({"source": edited, "part": "door", "source_version": 4,
                             "format": "stl", "path": str(tmp_path / "door.stl")})
    assert reply["ok"], reply
    assert translations[0] == 1
    assert not reply["result"]["reused_evaluation"]
    assert (tmp_path / "door.stl").read_bytes() != before
    refused = methods._export({"source": source, "part": "missing", "format": "stl",
                               "path": str(tmp_path / "missing.stl")})
    assert not refused["ok"] and not (tmp_path / "missing.stl").exists()


def test_named_export_refusal_never_borrows_assembly_defects(tmp_path, monkeypatch):
    from mcad.mesh_export import MeshNotSolid
    source = "door = cube(2,2,2)\nassembly = sphere(4)\n"
    assert methods._evaluate({"source": source})["ok"]
    def refuse(*args, **kwargs):
        raise MeshNotSolid(RuntimeError("mesh is invalid"), node_name=kwargs["node_name"])
    monkeypatch.setattr(evaluator, "export_built", refuse)
    reply = methods._export({"source": source, "part": "door", "format": "3mf", "path": str(tmp_path / "door.3mf")})
    assert not reply["ok"]
    assert reply["error"]["details"]["shape_name"] == "door"
    assert reply["error"]["details"]["counts_from"] == "unavailable"

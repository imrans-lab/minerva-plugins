"""A 3MF the writer refuses says WHICH defect it tripped on.

build123d's Mesher triangulates the part itself and rejects anything that is
not a closed manifold solid, with a bare RuntimeError("3mf mesh is invalid").
STL streams the same part out without asking — so a user gets a file from one
format, a shrug from the other, and no way to tell whether the design or the
exporter is at fault.

ORACLE. The rev-3 enclosure fixture (private set, MCAD_PRIVATE_FIXTURES —
without it this class skips) is a part the 3MF writer refuses and the
STL writer accepts; an independent observation is opening enclosure-rev3.stl in
a mesh tool and finding the non-manifold edges the evaluation counts. The
defect count in the export message must be the SAME number the evaluation
reported as mesh_defects — one derivation, quoted twice. Swallowing the
Mesher's validation (writing the 3MF anyway) fails the refusal assertions;
reporting the refusal without the class and count fails the message ones.
"""

from __future__ import annotations

import re

import pytest

pytest.importorskip("build123d", reason="build123d not installed in this environment")

from mcad_worker.methods import _evaluate, _export  # noqa: E402

from tests._private_fixtures import private_enclosure_fixtures  # noqa: E402

# "2 non-manifold edges", "642 degenerate faces" — the class and its count.
_DEFECT_PHRASE = re.compile(r"(\d+) (non-manifold edges?|degenerate faces?|duplicate faces?|open edges?)")


@pytest.fixture(scope="module")
def refused(tmp_path_factory) -> dict:
    """Evaluate the fixture, then export it both ways — the panel's own order.

    The export quotes the evaluation's defect counts, so the evaluation has to
    have happened first, exactly as it has when a user exports what they are
    looking at.
    """
    source = (private_enclosure_fixtures() / "enclosure-rev3.mcad").read_text(encoding="utf-8")
    out = tmp_path_factory.mktemp("export")
    summary = _evaluate({"source": source, "summary": True})
    assert summary["ok"] is True, summary
    return {
        "summary": summary["result"],
        "3mf": _export({"source": source, "format": "3mf", "path": str(out / "e.3mf")}),
        "stl": _export({"source": source, "format": "stl", "path": str(out / "e.stl")}),
        "dir": out,
    }


class TestTheRefusalNamesTheDefect:
    def test_the_export_fails_as_mesh_invalid(self, refused):
        reply = refused["3mf"]
        assert reply["ok"] is False, "the writer refuses this part; the reply must too"
        assert reply["error"]["kind"] == "mesh_invalid"
        assert not (refused["dir"] / "e.3mf").exists()

    def test_the_message_names_a_defect_class_and_its_count(self, refused):
        message = refused["3mf"]["error"]["message"]
        found = _DEFECT_PHRASE.search(message)
        assert found, f"no defect class and count in the message: {message!r}"
        assert message != "3mf mesh is invalid"

    def test_the_count_is_the_evaluation_s_own(self, refused):
        # Sort key and reported value from one derivation: the number in the
        # message is the number last_eval already showed the user.
        defects: dict = refused["summary"]["mesh_defects"]
        assert defects, "the fixture is meant to be a part with counted defects"
        assert refused["3mf"]["error"]["details"]["mesh_defects"] == defects
        message = refused["3mf"]["error"]["message"]
        for name, count in defects.items():
            noun = name.replace("_", " ").replace("non manifold", "non-manifold")
            assert str(count) in message and noun.rstrip("s") in message

    def test_the_message_names_the_part(self, refused):
        assert refused["summary"]["shape_name"] in refused["3mf"]["error"]["message"]

    def test_stl_writes_the_same_part(self, refused):
        # The whole complaint: one format refuses what the other happily writes.
        assert refused["stl"]["ok"] is True, refused["stl"]
        assert refused["stl"]["result"]["bytes_written"] > 0


def test_a_manifold_solid_still_exports_to_3mf(tmp_path):
    """The refusal must be the writer's verdict, not a blanket 'no 3MF'."""
    path = tmp_path / "block.3mf"
    reply = _export({"source": "block = cube(10, 20, 30)\n", "format": "3mf", "path": str(path)})
    assert reply["ok"] is True, reply
    assert path.stat().st_size > 0


def test_an_evaluated_clean_part_is_not_told_to_evaluate_again():
    """When the evaluation counted no defect and the writer still refuses,
    the message says the two triangulations disagree — sending the user
    round an evaluate/retry loop would never change the answer."""
    from mcad.mesh_export import MeshNotSolid
    from mcad_worker import methods

    source = "block = cube(10, 20, 30)\n"
    saved = methods._last_program
    methods._last_program = ((methods._digest(source), 0.1, 0.1), {"mesh_defects": {}, "shape_name": "block",
                                            "body_count": 1, "mesh_defect_sites": {}})
    try:
        reply = methods._mesh_invalid_error(
            MeshNotSolid(RuntimeError("3mf mesh is invalid"), node_name="block"), source)
    finally:
        methods._last_program = saved
    message = reply["error"]["message"]
    assert "has not been evaluated" not in message
    assert "counted no" in message and "block" in message
    assert reply["error"]["details"]["counts_from"] == "last_evaluation_clean"


def test_only_the_writer_s_own_refusal_becomes_mesh_invalid():
    """A RuntimeError that is not the Mesher's validation message is passed
    on as itself; a lib3mf output failure (an unwritable path) is not a
    RuntimeError at all and never reads as a geometry verdict."""
    from mcad.mesh_export import MeshNotSolid, write_3mf
    from build123d import Box

    with pytest.raises(BaseException) as failed:
        write_3mf(Box(1, 2, 3), "/nonexistent-dir-for-3mf-test/x.3mf")
    assert not isinstance(failed.value, MeshNotSolid)

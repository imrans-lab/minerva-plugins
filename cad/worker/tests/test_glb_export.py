"""cad_export writes a .glb that mesh() can read back.

The plugin could export STL, STEP and 3MF, and mesh() reads glTF — so nothing
the plugin wrote could be mounted back as a reference. The GLB writer closes
that loop; this file parses the bytes it produced rather than trusting the
writer's own arithmetic.

ORACLE. An independent observation that would show this wrong: open the file in
any glTF viewer (or Godot's GLTFDocument, which is what the panel uses) and read
the box's size. It is the DSL's millimetres divided by 1000, because the glTF
unit is the metre — which is exactly the convention the panel assumes for a .glb
when the source passes no units=.
"""

import json
import struct

import pytest

from mcad_worker.methods import _export

SOURCE = "block = cube(10, 20, 30)\n"


def _parse_glb(path) -> tuple[dict, bytes]:
    """Split a GLB into its JSON chunk and its binary chunk, checking the frame."""
    raw = path.read_bytes()
    magic, version, total = struct.unpack("<III", raw[:12])
    assert magic == 0x46546C67, "not a glTF file"
    assert version == 2
    assert total == len(raw), "the header length must be the file's length"

    json_length, json_type = struct.unpack("<II", raw[12:20])
    assert json_type == 0x4E4F534A
    document = json.loads(raw[20 : 20 + json_length])

    offset = 20 + json_length
    bin_length, bin_type = struct.unpack("<II", raw[offset : offset + 8])
    assert bin_type == 0x004E4942
    binary = raw[offset + 8 : offset + 8 + bin_length]
    return document, binary


@pytest.fixture
def exported(tmp_path):
    path = tmp_path / "block.glb"
    response = _export({"source": SOURCE, "format": "glb", "path": str(path)})
    assert response["ok"] is True, response
    assert response["result"]["format"] == "glb"
    assert response["result"]["bytes_written"] == path.stat().st_size
    return path


class TestTheFileIsAValidGlb:
    def test_the_header_and_chunks_parse(self, exported):
        document, binary = _parse_glb(exported)
        assert document["asset"]["version"] == "2.0"
        assert len(binary) == document["buffers"][0]["byteLength"]

    def test_the_node_is_named_after_the_part(self, exported):
        document, _ = _parse_glb(exported)
        assert [node["name"] for node in document["nodes"]] == ["block"]

    def test_there_is_one_mesh_with_positions_and_indices(self, exported):
        document, binary = _parse_glb(exported)
        assert len(document["meshes"]) == 1
        primitive = document["meshes"][0]["primitives"][0]
        assert primitive["attributes"]["POSITION"] == 0
        assert primitive["indices"] == 1

        position = document["accessors"][primitive["attributes"]["POSITION"]]
        index = document["accessors"][primitive["indices"]]
        assert position["type"] == "VEC3"
        assert index["type"] == "SCALAR"
        assert index["count"] % 3 == 0

        # Every index has to address a vertex that exists, or the file draws
        # nothing and the viewer says nothing about why.
        view = document["bufferViews"][index["bufferView"]]
        raw = binary[view["byteOffset"] : view["byteOffset"] + view["byteLength"]]
        indices = struct.unpack("<%dI" % index["count"], raw)
        assert max(indices) < position["count"]

    def test_the_box_is_written_in_metres_and_y_up(self, exported):
        document, _ = _parse_glb(exported)
        accessor = document["accessors"][0]
        # cube(10, 20, 30) spans x 0..10, y 0..20, z 0..30 in millimetres.
        # (x, y, z) mm, Z-up becomes (x, z, -y) / 1000 metres, Y-up.
        assert accessor["min"] == pytest.approx([0.0, 0.0, -0.020])
        assert accessor["max"] == pytest.approx([0.010, 0.030, 0.0])


class TestTheFormatIsOffered:
    def test_an_unknown_format_is_still_refused(self, tmp_path):
        response = _export(
            {"source": SOURCE, "format": "obj", "path": str(tmp_path / "x.obj")}
        )
        assert response["ok"] is False
        assert "glb" in response["error"]["message"]

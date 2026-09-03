"""THE CONTAINER'S BYTE LAYOUT — the rules a foreign parser will not check.

WHY THIS SUITE EXISTS SEPARATELY FROM THE ORACLE
------------------------------------------------
``tests/oracle/test_gltf_export_oracle.py`` reads our files with ``pygltflib``,
an independent implementation, and that catches an accessor that disagrees with
the bytes behind it. What it does NOT do is validate: it resolves whatever
offsets the JSON states and copies the bytes out, so it loads a file whose
buffer views are misaligned and whose chunks are not multiples of four just as
happily as a correct one. Deleting ``GlbBuilder._append``'s alignment loop
passed every suite in this worker before this file existed.

That matters because the defect is invisible in exactly the way the format's
alignment rules exist to prevent: a viewer that COPIES the buffer renders a
misaligned file perfectly, and a viewer that MAPS it — which is what a
performance-minded loader does, and what a GPU upload path wants — reads
garbage or refuses. So the picture on the machine that wrote the file is no
evidence at all.

HOW THE DEFECT IS MADE REACHABLE
--------------------------------
Alignment cannot be tested on geometry alone: positions are 12-byte records and
indices are 4-byte records, so a buffer built only out of those is already
aligned however carelessly it is appended, and the test would pass with the
rule deleted. Every case below therefore puts ODD-LENGTH payloads in the
buffer, which is not a contrivance — it is what an embedded PNG is, and this
export embeds two of them.

The bytes are parsed by hand rather than through a library, because a library
is the thing that does not look at these rules.
"""

from __future__ import annotations

import json
import struct

import pytest

from pcb_worker import gltf_write
from pcb_worker.gltf_write import GlbBuilder, Primitive

#: PNG-shaped payloads of deliberately awkward lengths. ``add_png`` checks the
#: signature and embeds the rest verbatim, which is all this suite needs: it is
#: testing where bytes land, not whether an image decodes. The three lengths
#: leave the buffer at three different offsets mod 4.
_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PAYLOADS = [_SIGNATURE + bytes(range(n)) for n in (5, 14, 23)]

TRIANGLE = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]


def _built() -> tuple[bytes, list[bytes]]:
    """One container carrying geometry, materials and the three odd payloads,
    and the payloads in the order they were handed in."""
    builder = GlbBuilder("test")
    first = builder.add_png(PAYLOADS[0], "one")
    attributes = builder.add_vertices(TRIANGLE, uvs=[(0.0, 0.0)] * 3)
    builder.add_png(PAYLOADS[1], "two")
    material = builder.add_material("m", (0.5, 0.5, 0.5, 1.0), texture=first)
    mesh = builder.add_mesh("m0", [Primitive(attributes=attributes,
                                             triangles=[(0, 1, 2)],
                                             material=material)])
    builder.add_png(PAYLOADS[2], "three")
    builder.add_node("n0", mesh)
    return builder.to_glb(), PAYLOADS


def _chunks(glb: bytes) -> tuple[dict, bytes]:
    """The GLB header, the JSON chunk and the BIN chunk, read by hand.

    Every length in the container is checked against the bytes actually there,
    so a header that lies about the file's own size is a failure here rather
    than a surprise in somebody's loader.
    """
    magic, version, length = struct.unpack_from("<III", glb, 0)
    assert magic == gltf_write.GLB_MAGIC
    assert version == gltf_write.GLB_VERSION
    assert length == len(glb), "the header's total length is not the file's"

    doc = None
    binary = b""
    cursor = 12
    while cursor < len(glb):
        size, kind = struct.unpack_from("<II", glb, cursor)
        body = glb[cursor + 8:cursor + 8 + size]
        assert len(body) == size, "a chunk claims more bytes than the file holds"
        # THE CHUNK RULE, on the declared length AND on the bytes: a container
        # that padded the file but not the header is as broken as one that
        # padded neither.
        assert size % 4 == 0, "a GLB chunk is not a multiple of four bytes"
        if kind == 0x4E4F534A:
            doc = json.loads(body.decode("utf-8"))
            # SPACES, not zeros. The document itself is written with no
            # whitespace separators and carries no NUL, so a single NUL here is
            # the BIN chunk's filler used on the wrong chunk — which makes the
            # JSON unparseable on a stricter reader than this one.
            assert b"\x00" not in body, "the JSON chunk must pad with SPACES"
        else:
            binary = body
        cursor += 8 + size
    assert doc is not None, "no JSON chunk"
    return doc, binary


def test_every_buffer_view_starts_on_a_four_byte_boundary():
    """THE RULE, on a buffer that does not satisfy it by luck.

    Three odd-length payloads sit between the geometry, so each following view
    would start at a different non-multiple of four if nothing aligned it.
    """
    doc, _binary = _chunks(_built()[0])
    views = doc["bufferViews"]
    assert len(views) >= 6, "the fixture stopped exercising several views"
    for index, view in enumerate(views):
        assert view["byteOffset"] % 4 == 0, \
            f"bufferView {index} starts at {view['byteOffset']}"


def test_alignment_padding_is_inserted_before_the_data_and_never_over_it():
    """Aligning by MOVING a view is the rule; aligning by trimming one is a
    corrupt file that satisfies the arithmetic. So every payload is read back
    out of the buffer at the offset its view states."""
    glb, payloads = _built()
    doc, binary = _chunks(glb)
    embedded = [doc["bufferViews"][image["bufferView"]] for image in doc["images"]]
    assert len(embedded) == len(payloads)
    for view, payload in zip(embedded, payloads):
        start = view["byteOffset"]
        assert view["byteLength"] == len(payload)
        assert binary[start:start + len(payload)] == payload


def test_both_chunks_are_multiples_of_four_and_pad_with_their_own_filler():
    """The two padding characters are NOT the same — spaces for JSON, zeros for
    BIN — and a file padded with the wrong one is a file whose JSON no longer
    parses or whose trailing bytes are not the zeros a reader may assume."""
    glb, payloads = _built()
    doc, binary = _chunks(glb)          # the multiple-of-four rule is asserted there

    # The BIN chunk's tail is the padding, and it is zeros. The last payload is
    # odd, so there IS a tail to look at.
    end = max(v["byteOffset"] + v["byteLength"] for v in doc["bufferViews"])
    assert end < len(binary), "the fixture's last view ended flush; nothing pads"
    assert binary[end:] == b"\x00" * (len(binary) - end)

    # And the buffer declares the PADDED length, which is what the chunk holds.
    assert doc["buffers"][0]["byteLength"] == len(binary)


def test_a_file_with_no_nodes_is_refused_rather_than_written():
    """The one shape of empty container that would load and show nothing."""
    with pytest.raises(ValueError, match="no nodes"):
        GlbBuilder("test").to_glb()

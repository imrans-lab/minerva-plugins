"""Write a tessellated shape as a minimal binary glTF (.glb).

Why this exists: mesh() reads glTF, and until now nothing in the plugin could
write one — a DSL stand-in could be exported to STL and then not mounted back
as a reference. This closes that round trip with the smallest file that is
still a valid glTF 2.0 document: one buffer, one mesh with POSITION and
indices, one node, one scene.

FRAME. The file is written in the glTF convention — metres, Y-up — because
that is what ``mesh("x.glb")`` assumes when the source passes no units= or up=.
CAD millimetres/Z-up map to it as (x, y, z) -> (x/1000, z/1000, -y/1000), which
is exactly the inverse of the panel's conversion for a glTF, so a round trip
through this writer lands the body back where it started.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path
from typing import Any

# Millimetres per glTF unit: the spec's linear unit is the metre.
_MM_PER_UNIT: float = 1000.0

_GLB_MAGIC: int = 0x46546C67  # "glTF"
_CHUNK_JSON: int = 0x4E4F534A  # "JSON"
_CHUNK_BIN: int = 0x004E4942  # "BIN\0"

_COMPONENT_FLOAT: int = 5126
_COMPONENT_UINT32: int = 5125
_TARGET_ARRAY_BUFFER: int = 34962
_TARGET_ELEMENT_ARRAY_BUFFER: int = 34963


def _pad4(data: bytes, filler: bytes) -> bytes:
    """glTF requires every chunk and buffer view to start on a 4-byte boundary."""
    remainder = len(data) % 4
    return data if remainder == 0 else data + filler * (4 - remainder)


def write_glb(
    shape: Any,
    path: str,
    *,
    node_name: str = "part",
    tolerance: float = 0.1,
    angular_tolerance: float = 0.1,
) -> str:
    """Tessellate *shape* and write it to *path* as a .glb. Returns the path."""
    vertices, faces = shape.tessellate(
        tolerance=float(tolerance), angular_tolerance=float(angular_tolerance)
    )
    if not vertices or not faces:
        raise ValueError("glb export: tessellation produced no mesh data")

    positions = bytearray()
    min_xyz = [float("inf")] * 3
    max_xyz = [float("-inf")] * 3
    for v in vertices:
        # CAD millimetres, Z-up -> glTF metres, Y-up.
        point = (
            float(v.X) / _MM_PER_UNIT,
            float(v.Z) / _MM_PER_UNIT,
            -float(v.Y) / _MM_PER_UNIT,
        )
        positions += struct.pack("<3f", *point)
        for axis in range(3):
            min_xyz[axis] = min(min_xyz[axis], point[axis])
            max_xyz[axis] = max(max_xyz[axis], point[axis])

    indices = bytearray()
    index_count = 0
    for face in faces:
        # A tessellation face is a triangle; anything else is fanned so the
        # writer never emits a primitive the reader cannot draw.
        ids = list(face)
        for corner in range(1, len(ids) - 1):
            indices += struct.pack("<3I", ids[0], ids[corner], ids[corner + 1])
            index_count += 3

    position_bytes = bytes(positions)
    index_offset = len(position_bytes)
    buffer_bytes = _pad4(position_bytes + bytes(indices), b"\x00")

    gltf = {
        "asset": {"version": "2.0", "generator": "minerva-cad"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": node_name}],
        "meshes": [
            {
                "name": node_name,
                "primitives": [{"attributes": {"POSITION": 0}, "indices": 1, "mode": 4}],
            }
        ],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": _COMPONENT_FLOAT,
                "count": len(vertices),
                "type": "VEC3",
                "min": min_xyz,
                "max": max_xyz,
            },
            {
                "bufferView": 1,
                "componentType": _COMPONENT_UINT32,
                "count": index_count,
                "type": "SCALAR",
            },
        ],
        "bufferViews": [
            {
                "buffer": 0,
                "byteOffset": 0,
                "byteLength": len(position_bytes),
                "target": _TARGET_ARRAY_BUFFER,
            },
            {
                "buffer": 0,
                "byteOffset": index_offset,
                "byteLength": len(indices),
                "target": _TARGET_ELEMENT_ARRAY_BUFFER,
            },
        ],
        "buffers": [{"byteLength": len(buffer_bytes)}],
    }

    json_bytes = _pad4(json.dumps(gltf, separators=(",", ":")).encode("utf-8"), b" ")

    total = 12 + 8 + len(json_bytes) + 8 + len(buffer_bytes)
    out = bytearray()
    out += struct.pack("<III", _GLB_MAGIC, 2, total)
    out += struct.pack("<II", len(json_bytes), _CHUNK_JSON) + json_bytes
    out += struct.pack("<II", len(buffer_bytes), _CHUNK_BIN) + buffer_bytes

    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(bytes(out))
    return str(output_path)

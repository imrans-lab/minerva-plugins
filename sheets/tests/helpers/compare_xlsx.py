"""Compare actual XLSX bytes, excluding only ZIP DOS time/date fields."""
from __future__ import annotations

import hashlib
import io
import json
import struct
import sys
import zipfile
from pathlib import Path
from typing import TypedDict


class Part(TypedDict):
    name: str
    crc: int
    size: int
    compressed_size: int
    compression: int
    timestamp: tuple[int, int, int, int, int, int]


def inspect_archive(raw: bytes) -> tuple[bytes, list[Part]]:
    normalized = bytearray(raw)
    parts: list[Part] = []
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        for info in archive.infolist():
            # Reading every part verifies decompression and its original CRC.
            archive.read(info)
            offset = info.header_offset
            if raw[offset:offset + 4] != b"PK\x03\x04":
                raise ValueError("Invalid local ZIP header")
            normalized[offset + 10:offset + 14] = bytes(4)
            parts.append({"name": info.filename, "crc": info.CRC,
                          "size": info.file_size, "compressed_size": info.compress_size,
                          "compression": info.compress_type, "timestamp": info.date_time})
        offset = archive.start_dir
        for _ in parts:
            if raw[offset:offset + 4] != b"PK\x01\x02":
                raise ValueError("Invalid central ZIP header")
            normalized[offset + 12:offset + 16] = bytes(4)
            name, extra, comment = struct.unpack_from("<HHH", raw, offset + 28)
            offset += 46 + name + extra + comment
    return bytes(normalized), parts


def main() -> int:
    baseline = Path(sys.argv[1]).read_bytes()
    candidate = Path(sys.argv[2]).read_bytes()
    original, original_parts = inspect_archive(baseline)
    observed, observed_parts = inspect_archive(candidate)
    equal = original == observed
    print(json.dumps({"equal_except_zip_clock_fields": equal,
                      "baseline_sha256": hashlib.sha256(baseline).hexdigest(),
                      "candidate_sha256": hashlib.sha256(candidate).hexdigest(),
                      "baseline_bytes": len(baseline), "candidate_bytes": len(candidate),
                      "baseline_parts": original_parts, "candidate_parts": observed_parts}))
    return 0 if equal else 1


if __name__ == "__main__":
    raise SystemExit(main())

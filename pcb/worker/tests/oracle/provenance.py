"""DEV/TEST-ONLY GOLDEN PROVENANCE registry loader + correctness-oracle gate.

The second half of the anti-circularity control (docket SB.2). A golden is only
trustworthy as a CORRECTNESS ORACLE if some INDEPENDENT authority confirmed it
is actually correct (an independent Gerber viewer — gerbv / JLC / OSHPark online
— and/or kicad-cli DRC on the round-tripped board). This module reads the
provenance registry (PROVENANCE.json beside the golden) and enforces the rule:

  * A golden with a provenance entry AND blessed=true  -> usable as a
    correctness oracle.
  * A golden with blessed=false, or NO entry at all     -> UNTRUSTED. It may be
    used as a DRIFT PIN (geometry_diff against it detects change) but MUST NOT be
    treated as a correctness oracle. Callers gate on
    :func:`correctness_oracle_status` and skip-with-reason — never silently pass.

Registry schema (PROVENANCE.json)::

    {
      "schema_version": 1,
      "goldens": {
        "<golden_id>": {
          "golden_id": "<golden_id>",
          "path": "<repo-relative dir>",
          "role": "correctness-reference-candidate" | "drift-pin-only",
          "blessed": true | false,
          "method": "<viewer name / kicad-cli DRC>" | null,
          "date":   "<ISO date>" | null,
          "by":     "<who blessed>" | null,
          "notes":  "<free text>"
        }
      }
    }
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ProvenanceEntry:
    golden_id: str
    blessed: bool
    method: str | None
    date: str | None
    by: str | None
    notes: str
    path: str | None
    role: str | None
    raw: dict


def load_provenance(json_path: str | Path) -> dict[str, ProvenanceEntry]:
    """Load PROVENANCE.json into {golden_id: ProvenanceEntry}."""
    data = json.loads(Path(json_path).read_text(encoding="utf-8"))
    out: dict[str, ProvenanceEntry] = {}
    for gid, e in (data.get("goldens") or {}).items():
        out[gid] = ProvenanceEntry(
            golden_id=e.get("golden_id", gid),
            blessed=bool(e.get("blessed", False)),
            method=e.get("method"),
            date=e.get("date"),
            by=e.get("by"),
            notes=e.get("notes", ""),
            path=e.get("path"),
            role=e.get("role"),
            raw=e,
        )
    return out


def correctness_oracle_status(prov: dict[str, ProvenanceEntry],
                              golden_id: str) -> tuple[bool, str]:
    """Whether *golden_id* may be used as a CORRECTNESS ORACLE.

    Returns ``(usable, reason)``. ``usable`` is True ONLY when a provenance entry
    exists with ``blessed=true``. Otherwise ``usable`` is False and ``reason``
    explains why (missing entry / not yet blessed) — the caller must
    skip-with-reason, NOT silently pass.
    """
    entry = prov.get(golden_id)
    if entry is None:
        return False, (
            f"golden '{golden_id}' has NO provenance entry — UNTRUSTED; usable as "
            f"a drift-pin only, not as a correctness oracle"
        )
    if not entry.blessed:
        return False, (
            f"golden '{golden_id}' is NOT blessed (blessed=false) — usable as a "
            f"drift-pin only, not as a correctness oracle. AWAITING external bless. "
            f"Notes: {entry.notes}"
        )
    return True, ""

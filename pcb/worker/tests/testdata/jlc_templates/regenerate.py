#!/usr/bin/env python3
"""Re-fetch JLCPCB's official BOM/CPL sample workbooks and re-derive the
SEMANTIC goldens beside this script.

The workbooks are NOT vendored. What is checked in is what was READ out of them
— every cell of the sample sheet — beside the SHA-256 of the bytes that were
read, so a later fetch can prove it is looking at the same artifact rather than
trusting a transcription. A golden claimed for an artifact that was never
downloaded would be a golden derived from prose, which is the one thing the
template pin exists to rule out.

NETWORK REQUIRED. This is a maintenance script, never a test: no test in this
repo fetches anything. Run it when JLCPCB changes a template, then reconcile
``pcb/library/service-profiles/jlcpcb-economic.json`` — its ``templates`` block
carries the same digests and columns, and ``service_profile._check_drift``
refuses the load if the emitted headers and the pinned ones drift apart without
an explanation.

    python3 pcb/worker/tests/testdata/jlc_templates/regenerate.py
"""

from __future__ import annotations

import hashlib
import json
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from datetime import date
from io import BytesIO
from pathlib import Path

MAIN_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"

#: The two artifacts, each with the help-centre article that links to it. The
#: URLs are the S3 attachments those articles serve; a moved link is itself a
#: finding, so a 404 here fails loudly instead of leaving a stale golden.
SOURCES = (
    ("bom",
     "https://s3.amazonaws.com/helpscout.net/docs/assets/59f1de7804286313cffbb22c"
     "/attachments/60ee4acd9e87cb3d0124d284/Sample-BOM_JLCSMT.xlsx",
     "https://jlcpcb.com/help/article/bill-of-materials-for-pcb-assembly"),
    ("cpl",
     "https://s3.amazonaws.com/helpscout.net/docs/assets/59f1de7804286313cffbb22c"
     "/attachments/5d83250e04286364bc8f4c5e/Sample-CPL_JLCSMT.xlsx",
     "https://jlcpcb.com/help/article/pick-place-file-for-pcb-assembly"),
)

GOLDEN = Path(__file__).resolve().parent / "jlcpcb-economic-templates.json"


def _sheet_rows(data: bytes) -> list[list[str]]:
    """Every cell of the workbook's first sheet, as text.

    Read straight out of the OOXML parts rather than through a spreadsheet
    library: the goldens must not depend on a package the worker does not
    already ship, and the sheets are four columns of strings."""
    archive = zipfile.ZipFile(BytesIO(data))
    shared: list[str] = []
    if "xl/sharedStrings.xml" in archive.namelist():
        root = ET.fromstring(archive.read("xl/sharedStrings.xml"))
        for item in root.findall(f"{MAIN_NS}si"):
            shared.append("".join(t.text or "" for t in item.iter(f"{MAIN_NS}t")))
    root = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
    rows: list[list[str]] = []
    for row in root.iter(f"{MAIN_NS}row"):
        cells: list[str] = []
        for cell in row.findall(f"{MAIN_NS}c"):
            value = cell.find(f"{MAIN_NS}v")
            if cell.get("t") == "s" and value is not None:
                cells.append(shared[int(value.text)])
            else:
                cells.append(value.text if value is not None else "")
        rows.append(cells)
    return rows


def main() -> None:
    today = date.today().isoformat()
    templates = []
    for artifact, url, referenced_from in SOURCES:
        with urllib.request.urlopen(url) as response:
            data = response.read()
        templates.append({
            "artifact": artifact,
            "url": url,
            "referenced_from": referenced_from,
            "fetched": today,
            "sha256": hashlib.sha256(data).hexdigest(),
            "rows": _sheet_rows(data),
        })
    payload = {
        "_note": (
            "SEMANTIC goldens parsed out of JLCPCB's own sample workbooks. The "
            "workbooks themselves are NOT vendored: what is checked in is what "
            "was READ from them, beside the digest of the bytes that were read, "
            "so a later fetch can prove it is looking at the same artifact. "
            "Regenerate with worker/tests/testdata/jlc_templates/regenerate.py."),
        "templates": templates,
    }
    GOLDEN.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
                      encoding="utf-8")
    print(f"wrote {GOLDEN}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Inline vendored JS into self-contained plugin html panels.

CEF/WRY load a plugin panel as a single materialized file with NO base URI, so
relative <script src="..."> assets do not resolve. We author each panel as
`ui/<name>.src.html` with a `<!-- @@D3@@ -->` placeholder and inline the vendored
library here to produce the shipped `ui/<name>.html`.
"""
import pathlib
import sys

UI = pathlib.Path(__file__).resolve().parent.parent / "ui"
D3 = UI / "vendor" / "d3.v7.min.js"

PANELS = ["code_graph", "runtime_diagnostics"]


def inline(name: str) -> bool:
    src = UI / f"{name}.src.html"
    if not src.exists():
        return False
    html = src.read_text()
    if "<!-- @@D3@@ -->" in html:
        d3 = D3.read_text()
        html = html.replace("<!-- @@D3@@ -->", "<script>\n%s\n</script>" % d3)
    out = UI / f"{name}.html"
    out.write_text(html)
    print(f"  built {out.name}  ({len(html)//1024} KB)")
    return True


def main() -> int:
    if not D3.exists():
        print(f"ERROR: vendored d3 missing at {D3}", file=sys.stderr)
        return 1
    built = 0
    for name in PANELS:
        if inline(name):
            built += 1
    print(f"built {built} panel(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

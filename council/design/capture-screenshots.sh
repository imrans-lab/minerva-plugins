#!/usr/bin/env bash
# Capture the prototype's states with the headless Chrome already on the machine.
# Nothing is installed and nothing is downloaded: the page is opened from file://.
#
# Viewport heights are deliberately realistic rather than full-page, so a shot
# shows what a reader actually sees in a narrow editor pane.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/shots"
chrome="${CHROME:-google-chrome}"
mkdir -p "$out"

# Headless Chrome reserves ~87px of the window for chrome it does not draw, and
# refuses a window narrower than 500px. So the window is asked for a little more
# than the viewport wanted, the image is cropped back, and a 400px panel is
# framed inside a 500px window with ?w=400 (the layout answers to the panel's
# width, not the window's, so this is the real thing).
BAND=87

shot() { # name  width  viewport-height  virtual-ms  query
  local name="$1" w="$2" h="$3" ms="$4" q="$5"
  "$chrome" --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
    --window-size="$w,$((h + BAND))" --virtual-time-budget="$ms" \
    --screenshot="$out/$name.png" "file://$here/index.html?$q" >/dev/null 2>&1
  local cropped
  cropped=$(python3 - "$out/$name.png" "$w" "$h" <<'PYCROP'
import sys
try:
    from PIL import Image
except ImportError:
    print("uncropped")           # Pillow is optional; the band just stays on
    raise SystemExit(0)
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
img = Image.open(path)
img.crop((0, 0, min(w, img.width), min(h, img.height))).save(path)
PYCROP
)
  echo "  $name.png  ${w}x${h}${cropped:+ (}${cropped}${cropped:+, install Pillow to trim the band)}  ?$q"
}

echo "Narrow (400px panel, framed in a 500px window), light:"
shot 400-ordinary            500 900 1200 "w=400&scenario=ordinary"
shot 400-empty               500 900 1200 "w=400&scenario=empty"
shot 400-assembling          500 900 1200 "w=400&scenario=assembling&pane=members"
shot 400-running             500 900 1200 "w=400&scenario=running"
shot 400-partial             500 900 1200 "w=400&scenario=partial"
shot 400-error               500 900 1200 "w=400&scenario=error"
shot 400-source-detail       500 900 1600 "w=400&scenario=ordinary&detail=source:src.narrow-shop:2:a.year-test"
shot 400-source-missing      500 900 1600 "w=400&scenario=ordinary&pane=sources&detail=source:src.ledger:1:"
shot 400-member-detail       500 900 1600 "w=400&scenario=ordinary&detail=member:m.okonkwo"
shot 400-compare             500 900 1600 "w=400&scenario=ordinary&detail=compare:c.capital.1,c.narrow.1"
shot 400-late-before         500 900 1200 "w=400&scenario=late"
shot 400-late-after          500 900 9500 "w=400&scenario=late"
shot 400-unreadable          500 900 1200 "w=400&scenario=unreadable"

echo "Narrow (500px), light:"
shot 500-ordinary            500 900 1200 "scenario=ordinary"
shot 500-running             500 900 1200 "scenario=running"
shot 500-compare             500 900 1600 "scenario=ordinary&detail=compare:c.capital.1,c.narrow.1"

echo "Narrow (400px), dark:"
shot 400-ordinary-dark       500 900 1200 "w=400&scenario=ordinary&theme=dark"
shot 400-source-detail-dark  500 900 1600 "w=400&scenario=ordinary&theme=dark&detail=source:src.narrow-shop:2:a.year-test"
shot 400-partial-dark        500 900 1200 "w=400&scenario=partial&theme=dark"

echo "Wide editor pane (1180px):"
shot wide-ordinary           1180 860 1200 "scenario=ordinary"
shot wide-compare            1180 860 1600 "scenario=ordinary&detail=compare:c.capital.1,c.narrow.1"
shot wide-source-detail      1180 860 1600 "scenario=ordinary&detail=source:src.pilot-call:1:a.no-reorder"
shot wide-members            1180 860 1200 "scenario=ordinary&pane=members"
shot wide-running-dark       1180 860 1200 "scenario=running&theme=dark"
shot wide-late-after         1180 860 9500 "scenario=late"

echo "Done: $out"

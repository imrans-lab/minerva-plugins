#!/usr/bin/env bash
# Capture the production panel's states with the headless Chrome already on the
# machine. Nothing is installed and nothing is downloaded: the page is opened
# from file://, against the envelopes in recorded.js that the real backend
# produced.
#
# The page under test is panel-replay.html — ui/panel.html with the replay
# bridge injected where council_bridge.gd injects the real one — so these are
# shots of the shipped page, not of a mock of it.
#
# Viewport heights are deliberately realistic rather than full-page: a shot has
# to show what a reader actually sees in a narrow editor pane.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/shots"
chrome="${CHROME:-google-chrome}"
mkdir -p "$out"

# Headless Chrome reserves ~87px of the window for chrome it does not draw, and
# refuses a window narrower than 500px. So the window is asked for a little more
# than the viewport wanted, the image is cropped back, and a 400px panel is
# framed inside a 500px window with ?w=400 — the layout answers to the panel's
# width and not the window's, so that is the real thing.
BAND=87

shot() { # name  width  viewport-height  virtual-ms  query
  local name="$1" w="$2" h="$3" ms="$4" q="$5"
  "$chrome" --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
    --window-size="$w,$((h + BAND))" --virtual-time-budget="$ms" \
    --allow-file-access-from-files \
    --screenshot="$out/$name.png" "file://$here/panel-replay.html?$q" >/dev/null 2>&1
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
shot 400-complete        500 900 2500 "w=400&case=complete"
shot 400-partial         500 900 2500 "w=400&case=partial"
shot 400-running         500 900 2500 "w=400&case=running"
shot 400-cancelled       500 900 2500 "w=400&case=cancelled"
shot 400-unreadable      500 900 2500 "w=400&case=complete&unreadable=1"
shot 400-members         500 900 2500 "w=400&case=complete&pane=members"
shot 400-sources         500 900 2500 "w=400&case=complete&pane=sources"
shot 400-source-detail   500 900 3000 "w=400&case=complete&detail=source:src-capacity-essay:2:anc-freedom"
shot 400-source-missing  500 900 3000 "w=400&case=inventory&pane=sources&detail=source:src-reading-notes:1:"
shot 400-member-detail   500 900 3000 "w=400&case=complete&detail=member:mem-okonkwo"
# An anchor that sits after curly quotes, em-dashes and an emoji: the mark has to
# land on the cited words, which byte offsets read as code units would not.
shot 400-anchor-utf8     500 900 3000 "w=400&case=punctuation&pane=sources&detail=source:src-margin-note:1:anc-worst-week"
shot 400-compare         500 900 3000 "w=400&case=complete&detail=compare:con-4,con-1"
shot 400-empty           500 900 2500 "w=400&case=inventory"
# The injection fixture: every text field carries markup, and it reads as words.
shot 400-injection       500 900 2500 "w=400&case=hostile"

echo "Narrow (500px), light:"
shot 500-complete        500 900 2500 "case=complete"
shot 500-running         500 900 2500 "case=running"
shot 500-compare         500 900 3000 "case=complete&detail=compare:con-4,con-1"

echo "Narrow (400px), dark:"
shot 400-complete-dark      500 900 2500 "w=400&case=complete&theme=dark"
shot 400-source-detail-dark 500 900 3000 "w=400&case=complete&theme=dark&detail=source:src-capacity-essay:2:anc-freedom"
shot 400-partial-dark       500 900 2500 "w=400&case=partial&theme=dark"

echo "Wide editor pane (1180px):"
shot wide-complete       1180 860 2500 "case=complete"
shot wide-compare        1180 860 3000 "case=complete&detail=compare:con-4,con-1"
shot wide-source-detail  1180 860 3000 "case=complete&detail=source:src-capacity-letter:1:anc-hard-week"
shot wide-members        1180 860 2500 "case=complete&pane=members"
shot wide-running-dark   1180 860 2500 "case=running&theme=dark"
shot wide-add-member     1180 860 3000 "case=complete&pane=members&detail=add_member"

echo "Done: $out"

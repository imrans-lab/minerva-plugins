# Council's panel surface

`panel.html` is what the wrapper stages to disk and hands to CefTexture as a
`file://` URL. It is **generated** — everything in it comes from `src/`, and it
is committed so a marketplace install needs no build step, no Node and no
network.

## Build

    node council/ui/build.mjs             # regenerate panel.html
    node council/ui/build.mjs --check     # fail if it has drifted from src/

The build is a concatenation: `src/panel.template.html` carries the shell and one
`/* @include <path> */` line per source, and each is replaced by that file's
bytes. Same sources, same bytes, on any machine. There is no bundler, no
minifier, no dependency and no lockfile; `node --check` on each file in `src/js`
is the whole of the static gate.

It refuses rather than mangles: a source containing a closing `</script>` or
`</style>` would end the block it is inlined into, so that is an error.

## What is where

| Path | What it is |
|---|---|
| `src/panel.template.html` | the shell: masthead, pane switcher, stage, foot rail |
| `src/styles/reading-room.css` | the visual direction, the container queries, the type scale |
| `src/js/dom.js` | the element builder — the reason the page has no `innerHTML` |
| `src/js/record.js` | snapshot lookups; total and pure, so a half-built record cannot crash a view |
| `src/js/bridge.js` | the wrapper protocol: reads, single-flight mutations, envelope size |
| `src/js/prefs.js` | Council's own text size |
| `src/js/views/*.js` | the panes and the detail column, record in, nodes out |
| `src/js/app.js` | reading position, navigation, keyboard, actions |
| `panel.html` | generated; do not edit |

## No network, ever

The manifest declares `network: none`, and the page holds to it: no CDN, no web
font, no icon set, no `fetch`. The type is the system serif and sans stacks and
the few glyphs used are text characters, so nothing in this directory carries a
licence of its own.

To check:

    grep -nE 'https?://|//(cdn|fonts)\.' council/ui/panel.html

The only matches should be inside comments.

## Text from the record is never markup

A member's answer comes from a model, a source excerpt comes from whatever the
user captured, and an imported council can carry anything at all. None of it
reaches the HTML parser: views build elements with `el()` from `src/js/dom.js`
and every record value goes in through `textContent`. There is no escaping rule
to remember at each concatenation, because there is no concatenation.

`tests/selftest.html` proves it against a document the real backend stored with
markup in every text field.

## Tests

    node council/ui/tests/record-envelopes.mjs    # re-record, needs a built backend
    google-chrome --headless=new --allow-file-access-from-files \
      --virtual-time-budget=120000 --window-size=1400,900 --dump-dom \
      file://$PWD/council/ui/tests/selftest.html | grep -o '<title>[^<]*'
    ./council/ui/tests/capture-screenshots.sh     # writes tests/shots/

`tests/panel-replay.html` is `panel.html` with a replay bridge injected where
`council_bridge.gd` injects the real one, so the tests drive the page that
ships. `tests/recorded.js` holds envelopes the real backend produced from
`council/fixtures`; nothing in it is hand-written. One of its documents exists
only to be awkward: `punctuation` carries a capture whose anchor sits after two
em-dashes, a curly apostrophe and an emoji, so the byte-offset-to-code-unit
conversion in `record.js` has something to get wrong.

`tests/shots/` is a **review baseline, refreshed by hand**. No gate compares
against it and nothing fails when the page's appearance changes — the images are
there so a reviewer can see what the panel looked like at each width and theme
when the work was done. Re-run `capture-screenshots.sh` whenever a change alters
what the panel looks like, and say in the review that you did.

`src/` and `tests/` are development material. A marketplace archive needs only
`panel.html`, the four `.gd` files and `CouncilPanel.tscn`.

# Council design prototype

An executable prototype of the Council panel: the reading-room direction, the
three moments the DCR asks to see before production UI, and the states around
them. It is design evidence, not production code. Nothing here is wired to the
real wrapper in `council/ui/` — `window.council` is a mock in `js/mock-bridge.js`
that imitates the same surface.

## Open it

    xdg-open council/design/index.html

No server, no build step, no network. Plain HTML, CSS and JS from `file://`.
There are no font or icon files: the page uses the system serif and sans stacks
and text glyphs, so nothing needs a licence in this directory.

The strip along the bottom is prototype scaffolding, not part of the panel. It
switches state, theme and reduced motion, and can make the next change carry a
stale revision so the refusal can be seen.

## Walk the three moments

**Assembling a council.** Open `index.html?scenario=empty`. The session pane
says the project has no council and offers one next step. Take it, press *Start
a council* — you get a chair and a library of unseated members. Give two of them
seats (the definition revision advances in the masthead each time), then *Ask
this council a question*. The panel moves to the session before the round
exists, the seats sit at *Waiting to start*, and answers land one at a time
followed by the chair's synthesis.

**Inspecting a disagreement and its source.** Open `index.html` (the ordinary
state). The chair's synthesis names the split without resolving it. Under
*Round 1*, press *Compare* on Capital Discipline, then pick the Narrow Shop
simulant from the list at the bottom of the comparison: the two sets of claims
sit side by side, each labelled `source`, `inference` or `unknown`, and the
comparison says which source they both cite. Press any citation — they are
labelled by the words they point at, not by the document — and the source opens
with the quoted span shown above the whole capture and marked inside it. *Back*,
or Escape, returns to the same scroll position with focus back on the citation.
For the other half of provenance, open the Sources pane and pick the bindery
ledger: it was captured as a reference only, so the panel says the material is
not available rather than quoting something nobody can check.

**Receiving a late contribution.** Open `index.html?scenario=late`. A follow-up
is out to one seat. Start reading Round 1 partway down the page and wait: the
answer arrives, then a hand-entered human one, and the chair reissues the
synthesis as *revised after the follow-up*. The paragraph you were reading does
not move; the arrival is announced to assistive technology and offered as a
button rather than scrolled to. The human contribution in this walkthrough is
labelled demo data — Council v0.1 sends no invitations and there is no invite
control anywhere in this prototype.

## States

`?scenario=` takes: `ordinary`, `empty`, `assembling`, `running`, `partial`,
`error`, `late`, `unreadable`. `?theme=dark`, `?motion=reduce`, `?pane=`,
`?detail=member:<id>` / `?detail=source:<id>:<rev>:<anchor>` /
`?detail=compare:<id>,<id>` open a state directly. `?w=400` frames the panel at
an exact width.

## Check it

    node rehash.js --check              # the sample content hashes match their payloads
    ./capture-screenshots.sh            # writes shots/ with the headless Chrome on this machine

Headless Chrome reserves a strip of the window it never draws, so each shot is
trimmed back to the viewport with Pillow if it happens to be importable. Pillow
is optional and nothing here installs it: without it the shots simply keep the
blank strip along the bottom, and the run says so.

    google-chrome --headless=new --allow-file-access-from-files \
      --virtual-time-budget=220000 --dump-dom \
      "file://$PWD/selftest.html" | grep -o '<title>[^<]*'

`selftest.html` drives the prototype in an iframe and checks the behaviour a
screenshot cannot show: Back restoring pane, scroll and focus; a late answer not
moving the reading position; citations opening their own span; a missing source
saying so; follow-up, retry and assembly running end to end; a write against an
old revision being refused. The `--allow-file-access-from-files` flag is for
that harness only.

## Files

| File | What it is |
|---|---|
| `index.html` | the panel surface |
| `styles/reading-room.css` | the visual direction and the responsive rules |
| `js/sample-data.js` | original sample council, members and source captures |
| `js/scenarios.js` | each state as a whole snapshot, plus the answers that arrive live |
| `js/mock-bridge.js` | a stand-in for the wrapper: envelopes, revisions, events, timers |
| `js/views.js` | every pane and detail view, record in, HTML out |
| `js/app.js` | reading position, navigation, keyboard, actions |
| `selftest.html` | the driver |
| `capture-screenshots.sh` | the screenshot run |
| `rehash.js` | derives the sample content hashes from their payload text (`--check` to verify) |
| `findings.md` | what T08 should carry over, and what it should not |

# What this prototype found, and what T08 should carry over

Written from building and driving the prototype, not from looking at it. Every
behavioural claim below was checked by `selftest.html` (23/23 at the time of
writing) or measured from the captures in `shots/`.

---

## 1. The visual direction, as concrete values

The reading-room direction resolved into these decisions. They are in
`styles/reading-room.css` as tokens; T08 should take the tokens, not the hexes.

**Palette.** Light: paper `#f4efe6`, raised surface `#fbf8f2`, ink `#221f1b`,
muted `#746c5f`, rule `#ddd4c4`, accent `#8a5320`, alarm `#8d3a2a`. Dark: paper
`#16150f`, surface `#1d1b16`, ink `#eee7d9`, muted `#9c9384`, rule `#3a352a`,
accent `#d8a862`, alarm `#e0947f`. One accent, used in exactly four places: the
current synthesis's left edge, a `source` support label, a citation link, and
the focus ring. Nothing else is coloured, so colour still means something by the
time you reach the bottom of a long round.

**Type.** Serif for everything that is read (question, contributions, claims,
captured excerpts); sans for everything administrative (labels, statuses,
identities, buttons). The question is `clamp(20px, 4.6cqi, 27px)` — sized by the panel, not the window (§2) and is the
largest thing on the page whenever there is one; body is 15.5px/1.62 capped at
62ch. Administrative labels are 10-12px sans, uppercase, `.1em` tracked. That
split does the work that boxes and background fills usually do.

**Identity.** Name in sans semibold, then a kind chip that always spells the word
— `Human`, `Assistant`, `Simulant` — never an icon or a colour alone. Human is
a filled ink chip, Assistant a filled neutral chip, Simulant an outlined dashed
chip: distinguishable in monochrome and at a glance in a list. The seat's
responsibility sits beside the name in muted sans, because identity and
responsibility are separate records and reading them as one line makes it
obvious when the same member is seated differently.

**Support labels.** `source` is a filled accent pill; `inference` a plain
outlined pill; `unknown` a dashed, italic outlined pill. The three are
distinguishable by shape alone. A `source` claim's citations sit directly under
its text; `inference` and `unknown` claims carry none, which is the schema's
rule and reads here as an absence you can see.

**Status.** A status pill is rendered only when the status is worth reading. A
finished contribution shows no pill at all; `running`, `pending`, `failed`,
`cancelled` and `stale` do. Labelling the ordinary case is noise that costs a
line in a 400px pane.

---

## 2. Layout: the panel is the responsive unit, not the window

A Minerva editor pane is a cell in a variable grid, so its width has nothing to
do with the window's. Every responsive rule here is a **container query** on
`.panel` (`container: panel / inline-size`), not a media query. Two consequences
worth keeping:

- The same page is correct in a narrow pane inside a wide window, which a media
  query gets wrong every time.
- It is safe: the CEF in this Minerva reports `Chrome/146.0.7680.179`
  (`strings vendor/godot_cef/target/release/libcef.so`), far past the 105 that
  introduced container queries. **T08 should re-check that string against
  whatever CEF the release ships**, since this is the one hard platform
  dependency the design takes.

Below a 900px panel, a detail view *covers* the reading column and Back returns
to it. At or above 900px the two sit side by side and Back is hidden — the
detail column is simply where details appear. The comparison grid needs no query
at all: `repeat(auto-fit, minmax(230px, 1fr))` gives two columns when two fit.

`prefers-reduced-motion` is still a media query, correctly — it is a user
preference, not a size.

---

## 3. Usability findings

Each of these was found by driving the prototype, and each is a thing T08 will
otherwise rediscover.

**F1 — Back must remember a selector, not a DOM node.** Every render replaces the
reading column, so the node that opened a detail is detached by the time Back
runs and `.focus()` silently does nothing. The fix is to record the trigger's
`data-*` attributes as a selector and re-query after the render. Found by the
driver, not by looking: focus loss is invisible in a screenshot.

**F2 — A valueless `data-` attribute reads back as `''`, which is falsy.**
`if (dataset.ask)` made the *Ask this council a question* button do nothing at
all. Test presence (`!== undefined`) or always give the attribute a value. This
is a one-character bug that a review will not catch and a click will.

**F3 — Mutations must be single-flight.** Two mutations in flight at once race
for the same revision: the second is written against a number the first has
already moved, comes back `stale_revision` through no fault of the user, and its
refusal is then overwritten by the first one's success message. Serialising
mutations through one promise chain costs nothing at human speed and removes the
class. This is a protocol-shaped bug, so it will exist in T08 too.

**F4 — Reading position survives by anchoring, not by saving `scrollTop`.**
Before a re-render the topmost visible block is recorded by a stable key
(`data-anchor="run:run.1"`, `c:<contribution_id>`); afterwards the scroller is
nudged so that block sits where it was. Measured movement when a late
contribution lands mid-page: **0px**. Saving and restoring `scrollTop` alone
does not work, because content inserted above the viewport changes what that
number means.

**F5 — Never auto-scroll a detail view to the cited span.** The first version
centred the highlighted span on open, which pushed the source's title, author and
capture date off the top of a 400px pane — the reader arrived with no idea what
they were looking at. The quote is now shown as a pull-quote directly under the
metadata, with the full capture below it and the same span marked. No scroll
happens on open at all.

**F6 — A citation must be labelled by the words it points at.** Two claims citing
different anchors in one source rendered as two identical links ("Pilot customer
call log · rev 1"), which reads as a UI bug and hides that they are different
evidence. Citations now read as a truncated quote, with the source title and
revision underneath in muted sans.

**F7 — `focus()` after Back needs `preventScroll: true`,** or focusing the
restored trigger immediately undoes the scroll position that was just restored.

**F8 — The wide layout needs a resting right column.** With nothing open, half
the panel was empty. It now holds *Council at a glance*: the roster with kinds
and responsibilities, and the source inventory with a plain count of how many
sources actually have their material in the project. It is rendered
unconditionally and hidden by the container query when narrow, so no width
detection is needed in script.

**F9 — The late-human label cannot live in the record.** `Contribution` is
`additionalProperties: false`, so there is nowhere to put "this is demo data".
The label is therefore a property of the *walkthrough*, rendered as a banner and
a per-card note in the `late` scenario only. T08 must not invent a field for
this: v0.1 seats one human, the local user, and a hand-entered contribution from
them is an ordinary contribution. There is no invite control anywhere in this
prototype, by design.

**F10 — Anchors must not span hard line breaks.** The first draft of the sample
captures was hard-wrapped, which made every anchor quote fragile and made the
excerpt read raggedly under `white-space: pre-wrap`. Captured text is stored as
paragraphs and wrapped by the panel. Worth stating in the capture path in T05.

**F11 — One message region is not enough.** A refusal and a success both land in
the same status line, and the later one wins. The prototype tolerates it because
mutations are now serialised (F3), but T08 should consider a refusal that stays
until it is acknowledged or acted on.

**F12 — A human member must not be shown a model's provenance.** Seating *You*
(kind `human`) in the assembling flow produces a contribution carrying
`model_id: "sonnet-4.6"`, because the prototype's follow-up generator stamps a
model on whatever it answers with. Two separate things follow for T08, and the
second is the important one: the backend must never attach a `model_id` to a
contribution a person wrote, and the panel must **render** `model_id` somewhere
for the ones that have it. Today it is in the record, is read by nothing, and is
shown nowhere — so a reader cannot tell which model produced an answer, and
could not tell a hand-entered contribution from a generated one if the field
were wrong. The schema says the field exists "so a result is never attributed to
a model that did not produce it"; a field no view renders cannot do that.

**F13 — Do not copy the prototype's size check.** `js/mock-bridge.js` measures
`JSON.stringify(payload)` against the 32768-code-unit limit. That is the payload
alone: the real hop carries the whole envelope — `schema_version`, `envelope`,
`request_id`, `command`, `base_revision` — and the wrapper's own framing on top.
A message that passes here can still be refused there. T08 must measure the
serialized envelope it is actually about to send, at the point it sends it.

**F14 — `aria-selected` needs a tab role to mean anything.** The pane switcher in
`index.html` puts `aria-selected` on plain `<button>` elements. On a button with
no `role="tab"` the attribute is not mapped, so a screen reader announces three
buttons and never says which pane is current. T08 should either give the nav
`role="tablist"` with `role="tab"` on each button (and then owe it the roving
tabindex and arrow-key behaviour the pattern requires), or drop `aria-selected`
for `aria-current="page"`, which needs no keyboard contract at all. The second is
probably right for three panes.

**F15 — `wrapper.set_view` advances no revision,** so the page cannot treat the
reply as evidence that anything was saved. The prototype uses it purely as
fire-and-forget; T08 should not build a "saved" affordance on top of it.

---

## 4. What the prototype commits to about the protocol

The mock enforces these, and the page is built against them. They are the parts
of `architecture.md` §5.2 that turned out to have visible consequences:

- A read command that carries `base_revision` is refused, and a mutating command
  without one is refused. Which commands mutate is not a detail the page can be
  vague about.
- An oversized message is refused with `payload_too_large`, never dropped. A
  dropped message leaves a promise pending forever and looks exactly like a hung
  panel.
- An event carries no authority: every one of them causes a fresh `snapshot.get`.
  Nothing in the page is patched in place from an event payload.
- Source material is read with `source.fetch`, not out of the roster the page
  already has, because in production it may exceed the inline limit and live in
  a blob.
- Session status is derived from the run set (`deriveSessionStatus` in the mock
  mirrors §4.1) and never assigned, so no view state can contradict it.

---

## 5. What this does not prove

- **It is not wired to the real bridge.** T08 replaces `js/mock-bridge.js` with
  `council.call` from `council/ui/council_bridge.gd`. The surface is identical
  on purpose; nothing else should have to change.
- **It has not been seen in CEF.** Rendering, fonts, focus behaviour and the
  scroll physics inside `CefTexture` are the owner's HITL to confirm.
- **Timings are invented.** Answers land on 1.6-8s timers so the states can be
  walked; a real round is minutes.
- **Content hashes in the sample data are derived, not typed.** They were
  hand-pasted once and two of them were wrong — one source carried another's
  hash — which is precisely the failure the schema's `content_hash` exists to
  make impossible, reproduced in the fixture meant to demonstrate it. `node
  rehash.js` now recomputes them from the payload text and rewrites the data
  file, and `node rehash.js --check` fails if they have drifted; it substitutes
  positionally so it cannot swap one source's hash for another's. The page
  still does not verify them at render time, and in production it should not
  have to: verification belongs to the backend that captured the bytes.
- **All sample material is original and fictional.** The bindery, its pilot
  customer, and R. V. Okonkwo and the essay attributed to the simulant were
  written for this prototype. No real person is quoted or represented.

## 6. If the owner walks it by hand

Worth doing with the keyboard only, since synthetic events cannot prove native
activation: Tab through a round (every control is a real `<button>`), open a
citation with Enter, read the source, press Escape, and check you are back where
you were with the citation still focused. Then `?scenario=late`, scroll to
mid-page, and watch what happens to the line you are reading when the answer
lands.

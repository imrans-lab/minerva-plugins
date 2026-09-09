# Council panel — live check

Everything in T03 that can be decided without launching Minerva has been.
This is the part that cannot: whether the panel really renders in a live CEF
surface, whether Minerva around it keeps working, and whether the flows behave
when a person drives them.

Nothing below has been performed. Each line is a claim to confirm or refute; a
refuted line is a finding to file, not something to fix in place.

## Before you start

1. Build the backend. The manifest's `setup` step does this on a dev-lane
   install, but building it first makes a build failure legible:

   ```
   cd <plugins>/council && go build -o council-plugin ./
   ```

2. Have a Minerva running that has godot-cef. If `CefTexture` is missing the
   panel says so in words instead of rendering; that is a pass for the
   compatibility path and a stop for everything else here.

## Install

Side-load the plugin directory `<plugins>/council` (its `manifest.json` is the
install target). The dev lane is the one that runs the `setup` stanza.

- [ ] Install reports success, and Council appears in the plugin list.
- [ ] Starting Council starts `council-plugin` without an error toast.

## The panel renders

Open **New Council** from the editor's new-document menu (`editor_items`
declares it, default filename `untitled.mcouncil`).

- [ ] The tab opens with the Council page rendered — warm background, the
      "Council" heading, and the empty-project sentence. **Not** a black
      rectangle, not a blank panel, not a red diagnostic label.
- [ ] The text is crisp, not upscaled and soft. (If it is soft, the oversampling
      the panel applies is not reaching this display — file it.)
- [ ] Clicking inside the page focuses it; the buttons respond to the mouse.

## Minerva around it still works — the highest-value check here

`CefTexture`'s node-level input hook consumes every event in the viewport it
sits in, which is why the panel puts it in a SubViewport. If that has gone
wrong, the whole application stops responding, not just the tab.

- [ ] With the Council tab open and focused, the editor tab bar still switches
      tabs by mouse.
- [ ] The menu bar still opens.
- [ ] Ctrl+Tab / the chat pane / other editors still take keyboard input.
- [ ] Typing in a text editor tab still types there, not into the Council page.

## Theme and focus

- [ ] Switch Minerva between light and dark. The Council page follows within a
      moment (its background and text invert).
- [ ] Click away to another tab and back: focus returns to the page.

## Save, reopen, restart

- [ ] Ctrl+S writes an `.mcouncil` file. Open it in a text editor: it is
      formatted JSON with `"record_kind": "council_project_snapshot"`.
- [ ] Close the tab and open the `.mcouncil` file again: the panel opens it and
      shows the same content.
- [ ] Save the project, quit Minerva, restart, reopen the project: the Council
      tab comes back with its content and its selected session.
- [ ] Stop the Council plugin, then open the same document: it still renders
      (the record is the panel's, not the backend's). Commands report that the
      backend is not running, and say the council is safe.

## A document Council cannot read

- [ ] Make a text file `notes.mcouncil` containing prose (not JSON) and open it.
      The panel shows a sentence saying it is not a Council document and that
      saving writes it back unchanged.
- [ ] Press Ctrl+S on it, then compare the file with the original —
      `cmp original notes.mcouncil` must report no difference.
- [ ] Save the project with that tab open, restart, reopen, Ctrl+S again, and
      compare once more. Still identical.

## The note round trip

- [ ] Use the panel's **create note** action. A note appears with a preview image
      and a caption naming the session.
- [ ] Open that note: a Council tab reopens carrying the same content.

## Chat handoff — the empty half

- [ ] On a council with no session at all, **Send selected to the bound chat**
      reports that there is no session and sends nothing.

The populated half of this check is in the fixture section below, where a
session with a recorded `chat_binding` exists.

## Two projects at once

- [ ] Open two Council documents in two projects at the same time, change
      something in each, save both, and reopen both. Each holds only its own
      content. (`tests/gd/test_council_panel.gd` section 6 asserts this against
      the backend store; this line is the same question with a person driving.)

## A populated document — the checks the empty panel could not reach

The first live pass could not exercise persistence, notes or restart, because
nothing in the UI creates a session yet and there was no populated file to open.
`council/fixtures/workshop_complete.mcouncil` is that file. It holds one council
(a chair, a functional advisor, and a simulant grounded in two captured pieces of
fixture writing), one session, and two runs: an initial round that lost a member
to a timeout, and a retry that completed. Its session status is **complete**.

Work on a **copy**, so a failed step leaves the shipped fixture intact:

```
cp <plugins>/council/fixtures/workshop_complete.mcouncil ~/council-live.mcouncil
```

### Open it

- [ ] Open `~/council-live.mcouncil` from the editor's file-open. A Council tab
      opens — **not** the empty-project sentence, and **not** the "this is not a
      Council document" notice.
- [ ] The question reads *"Should the workshop take the recurring 40-unit order
      at 0.7x price?"*
- [ ] The roster shows three names: **Chair**, **Unit costing** (labelled
      Assistant), **Okonkwo (capacity writing)** (labelled Simulant). The
      simulant shows what it represents and its stated limitations near the
      name, not buried.
- [ ] The session reads as finished, not running. Nothing is spinning, and no
      progress indicator is left over.
- [ ] Two runs are visible. The first is marked partial and says a member did
      not answer; the second is marked complete. If the panel shows only the
      latest run, the older one must still be reachable, not lost.
- [ ] The sources view lists two sources by "R. Okonkwo" and shows their
      excerpts. A claim marked as coming from a source can be followed to the
      excerpt it cites; claims marked as inference or as unknown show **no**
      source link.

### Ctrl+S and reopen — the persistence check

- [ ] Press Ctrl+S. Nothing visibly changes and no error appears.
- [ ] In a terminal:
      `python3 -m json.tool ~/council-live.mcouncil | head -5` — it is formatted
      JSON whose `record_kind` is `council_project_snapshot`.
- [ ] Close the tab, reopen `~/council-live.mcouncil`: the same question, the
      same three names, the same two runs, the same synthesis text.
- [ ] Nothing gained a "failed" or "interrupted" badge on reopening. A document
      with no work in flight must come back exactly as it was; a run that
      suddenly reads interrupted here is a defect, not a state.

### Note create and restore

- [ ] With the document open, use the panel's **create note** action. A note
      appears with a preview image and a one-line caption naming this session.
- [ ] Before creating it, switch the panel from the Session view to the Sources
      view. That writes `view.pane` as `sources` where the file on disk still
      says `session`, so the restored copy is distinguishable from the file.
- [ ] Close the Council tab. Open the note and use its reopen action: a Council
      tab comes back carrying the same session, the same two runs and the same
      synthesis.
- [ ] The restored tab is a Council panel, not a screenshot and not a blank
      panel with a toast.

### Restart

- [ ] With `~/council-live.mcouncil` open, save the project. Quit Minerva
      completely. Restart it and reopen the project.
- [ ] The Council tab comes back with the populated session, and with the pane
      you last had selected.
- [ ] Press Ctrl+S once more and run
      `python3 -m json.tool ~/council-live.mcouncil >/dev/null` — it is still
      valid JSON.
- [ ] Compare it with the shipped fixture, normalising numbers on both sides.
      Godot's `JSON.stringify` writes every integral number as a float, so a
      plain `diff` reports `31` against `31.0` on every revision and byte count
      and tells you nothing:

      ```
      norm() { python3 -c 'import json,sys
      def f(x):
          if isinstance(x,float) and x.is_integer(): return int(x)
          if isinstance(x,dict): return {k:f(v) for k,v in x.items()}
          if isinstance(x,list): return [f(v) for v in x]
          return x
      print(json.dumps(f(json.load(open(sys.argv[1]))),indent=2,sort_keys=True))' "$1"; }
      diff <(norm ~/council-live.mcouncil) <(norm <plugins>/council/fixtures/workshop_complete.mcouncil)
      ```

      Expected differences: the `view` block (you switched pane), and
      `snapshot_revision` / `session_revision` if the panel wrote anything. A
      changed run, contribution, synthesis or source is a defect.

### The backend, and the unreadable file, against a populated document

- [ ] Stop the Council plugin, then open `~/council-live.mcouncil` again. It
      still renders — the record is the panel's, not the backend's — and any
      command reports that the backend is not running while saying the council
      is safe.
- [ ] Start the plugin again and reopen: commands work, and the content is
      unchanged.
- [ ] Copy the fixture to `~/broken.mcouncil` and then **truncate it**:
      `head -c 400 ~/council-live.mcouncil > ~/broken.mcouncil`. Open it. The
      panel says it is not a Council document it can edit, and does not offer to
      edit it.
- [ ] Press Ctrl+S on it and run `cmp ~/broken.mcouncil <(head -c 400 ~/council-live.mcouncil)` — no difference.
      A half-written document must come back byte-for-byte, not be replaced by
      an empty council.

### Chat handoff, now that a bound session exists

The fixture's session records `chat_binding.chat_id = "chat-0192ab"`, which is
almost certainly not a chat on your machine.

- [ ] Select a contribution and use **Send selected to the bound chat**. The
      expected result is a clear report that the bound chat could not be found —
      naming the binding — and **nothing sent to whichever chat tab is open.**
      A message landing in the focused chat is the failure this check exists for.

## Chat provider — Council in the chooser

Everything below is the live half of §5.3 of `docs/architecture.md`. The
protocol tests drive a fake host; nothing in them proves the entry actually
reaches Minerva's provider chooser, which is the one thing this section is for.

Do this with a Council document open that holds **one** council with at least
one model-backed advisor and a model-backed chair, and with at least one model
enabled in Minerva's settings.

### It appears

- [ ] Open a new chat and drop the provider chooser. **Council** is listed,
      after the native providers.
- [ ] Check the Minerva log for `registered the Council chat provider entry`
      and, on the host side, `[CapabilityBroker] Plugin 'council' registered
      chat provider 'council'`. If the entry is missing from the chooser, this
      line says whether registration was refused or never attempted.
- [ ] Stop the Council plugin from the Plugin Manager. Council disappears from
      the chooser. Start it again: it comes back without restarting Minerva.

### It answers

- [ ] Select Council and ask a real question. Within a minute and a half either
      the chair's synthesis appears as the assistant message, or a reply saying
      the council is still deliberating and naming the run. **A turn that hangs
      until the chat times out is a failure**; so is an empty assistant message.
- [ ] The reply ends by pointing at the Council editor. Open it: the session is
      there, its question is the one you typed, and each member's own argument
      is listed separately with its sources.
- [ ] Ask a second question in the SAME chat. It becomes a second run on the
      same session, not a new session.

### It binds by chat, not by tab

- [ ] With the Council chat still open, open a second chat, also on Council, and
      ask a different question. Two sessions now exist, each bound to its own
      chat.
- [ ] Go back to the first chat and ask again. The answer continues the FIRST
      session. Switching Council editor tabs in between must change nothing.
- [ ] Open a second project with its own Council document, and ask again in the
      first project's chat. Expected: a visible refusal saying the chat belongs
      to a session in a document that is not the one open — **not** a new
      session, and not an answer in the wrong project.

### Choosing, when there is a choice

- [ ] Add a second council to the document. Ask a question in a fresh chat.
      Expected: Council replies with the councils as clickable options rather
      than picking one.
- [ ] Click one. The round runs on that council, and the session's question is
      the one you typed originally — you should not have had to type it twice.

### Cancel

- [ ] Ask something, and press stop while it is still running. The chat turn
      resolves promptly as cancelled.
- [ ] In the Council editor, the run reads cancelled and the session offers a
      retry. Nothing restarts on its own, and no further tokens are spent —
      check the cost readout before and after.

### Model choice

- [ ] Run `minerva_council_models` (or read the Council editor's member pane):
      the list matches the models enabled in Minerva's settings.
- [ ] Give a member a `model_hint` that is not on that list. Expected: an
      immediate refusal naming the models you do have, and **no round starts**.
- [ ] Disable every model in Minerva's settings and ask a question. Expected: a
      visible failure that says so, recoverable by enabling a model and asking
      again.

### Restart

- [ ] Mid-answer, stop the Council plugin. The chat turn ends with a visible
      error rather than hanging.
- [ ] Start the plugin, reopen the document. The interrupted run reads failed
      with an explicit retry; it does not resume and does not spend anything.
      Asking again in the same chat continues the same session.

#### The cross-project refusal, across a restart

This used to be a known hole: the guard lived in the backend's memory, so a
restart forgot it. It now rests on the project identity in the document, which
means the guard comes back as soon as the owning document is opened.

- [ ] With project A's Council document open, ask something in a chat so it
      binds to a session there. Save the project.
- [ ] Stop and start the Council plugin.
- [ ] Reopen project A's Council document (this is the step that matters — it is
      what lets the backend see the binding again), then open project B's.
- [ ] Ask again in that same chat. Expected: Council **refuses**, naming the
      project the chat belongs to, and project B's document gains no session.
- [ ] Reopen project A's document and ask again in that chat: it continues the
      original session.

#### The residual limit — confirm it is still only this big

- [ ] Repeat the sequence above but do **not** reopen project A's document after
      the restart: go straight to project B and ask.
- [ ] Expected **today**: a new session opens in project B, because no document
      the backend has seen names that chat. Confirm project A's session is
      untouched and still records the binding, and that nothing in B references
      A's content.
- [ ] Record what you saw. If B's session carries anything from A, that is a
      different and much worse bug — file it. Otherwise this is the residual
      limit in `docs/architecture.md` §5.3.2, which needs a host capability that
      does not exist.

### An older document, and a panel closed mid-round

- [ ] Open `council/fixtures/migrations/snapshot_v0_pre_project_identity.json`
      (copy it to a `.mcouncil` name first). It must OPEN as a council — not as
      a file Council refuses to touch — and Ctrl+S must write it back carrying
      `"schema_version": 1` and a `"project_id"`. Reopen it: the identity must be
      the SAME one, and the tab must not come up dirty.
- [ ] Start a round from the panel and close the tab while it is still running.
      Reopen the document from the same project. The contributions that landed
      after the tab closed must be there. (If the backend was stopped in between,
      the run reads failed with an explicit retry instead — that is the other
      rule, and both are correct for what happened.)
- [ ] Retain a conclusion as a note, then delete that note, then reopen the
      session. The outcome must still be listed, marked as a note that cannot be
      resolved, with its link back to the contribution intact — never silently
      dropped.

### One chat, one session

- [ ] In a chat already consulting a session, use the Council editor to point
      that chat at a *different* existing session. The editor's old session
      should stop showing the chat as its destination.
- [ ] Ask a follow-up in that chat. It must land on the **new** session — check
      the run count on both. A follow-up arriving on the old one is the failure
      this check exists for.

### Ordinary chat is untouched

- [ ] Switch the same chat back to a native provider and ask something. It
      answers normally.
- [ ] A chat that never had Council selected behaves exactly as before —
      history, cost, notes injection, stop.

## What to record

The Minerva build and plugin version, the install lane, a screenshot of the
rendered panel, and — for anything refuted — what you saw, so it becomes a
Docket item rather than a memory.

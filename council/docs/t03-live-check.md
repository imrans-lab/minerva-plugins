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

## Chat handoff

Needs a session with a recorded `chat_binding`, which arrives with T06/T07. Once
one exists:

- [ ] Select one or more contributions, press **Send selected to the bound
      chat**. The message lands in the chat named by the session's binding —
      confirm it is that chat, not whichever chat tab was open.
- [ ] With a session that has no binding, the same action reports that the
      session is not bound to a chat and sends nothing.

## Two projects at once

- [ ] Open two Council documents in two projects at the same time, change
      something in each, save both, and reopen both. Each holds only its own
      content. (`tests/gd/test_council_panel.gd` section 6 asserts this against
      the backend store; this line is the same question with a person driving.)

## What to record

The Minerva build and plugin version, the install lane, a screenshot of the
rendered panel, and — for anything refuted — what you saw, so it becomes a
Docket item rather than a memory.

extends RefCounted
## WHETHER AN OVERLAY IS ACTUALLY ON SCREEN, and what to tell a human when it
## is not.
##
## Off-tree module — NO class_name, reached by relative preload. Every function
## is STATIC and pure: a worker reply in, one line out.
##
## THE PROBLEM. show_fab_preview and show_mask are canvas DRAW FLAGS the View
## menu raises BEFORE the artwork is fetched. A failed fetch that leaves the flag
## standing tells both readers a view exists that does not: the View menu draws a
## check beside an empty canvas, and minerva_pcb_view_state reports the preview
## as up. A note drawn INSIDE the missing overlay is no help — it is not drawn
## either.
##
## THE RULE. The flag is a claim about what is on screen, so it may stand only
## while an overlay is actually held. A fetch that came back with nothing
## retracts it and says why through the HELD STATUS LEAD — the same channel
## pcb_load_checks.status_lead writes, for the same reason: a verdict that is
## honest only in JSON is invisible to anyone working from the GUI.
##
## THE STALE CASE IS THE SAME CASE. A board edit under a live preview clears the
## artwork, and a preview with no layers draws no board — so a flag left up over
## it claims a view nobody can see, which is the condition the rule above
## forbids. Both stale paths (a board edit, and a board that moved while the
## worker ran) retract through stale_reply below, so there is ONE retraction
## mechanism and one place the human reads the reason.

## The fetches this module governs, lead key -> the human's word for it (the
## View menu's own label, where one exists). A key absent from here is reported
## by its raw name rather than dropped.
##
## `zone_fill` has NO canvas flag behind it, deliberately: the pours are still
## drawn, they have merely stopped claiming any copper, so there is nothing to
## retract. What it shares with the overlays is the failure mode — a fill that
## did not land makes every join through a plane read as still owed, and saying
## nothing about it is the same defect — so it holds a lead here and rides
## PCBPanel.overlay_notes() into minerva_pcb_view_state like the rest.
const OVERLAY_LABELS: Dictionary = {
	"show_fab_preview": "Fab preview",
	"show_mask": "Mask openings",
	"zone_fill": "Pour fill",
}

## The payload-cap refusal, by every name it arrives under.
##
## MATCHED ON THE MESSAGE, of necessity: the broker refuses with
## PluginErrors.payload_too_large ({error_code:"payload_too_large",
## error_message:"Payload too large: N bytes (limit: M bytes)"}) and the panel's
## five *_check envelope normalisations keep only error_message, so the words
## are what survives to here. Case-insensitive (findn), and all three spellings
## are accepted so a code that does reach us is recognised too.
const _CAP_MARKERS: Array[String] = ["payload_too_large", "too_large", "too large"]

## What a human can do about the cap refusal once the board itself travels by
## reference: the only way back to it is a snapshot file that could not be
## written (panel_tools.board_payload_by_ref_if_large returns the original
## payload on any write failure, deliberately, so the broker refuses loudly).
const _CAP_NOTE := "the board could not be snapshotted for the worker, so the request went whole and was refused as too large — check free space and write permission under the Minerva user data directory"


## THE STALE REASONS, as a reply this module's own failure_reason can read.
##
## Shaped like a worker refusal on purpose: a stale overlay and a refused one
## reach the human through the same retraction, the same held lead and the same
## view_state key, so neither can grow a second half-implemented path.
const STALE_BOARD_EDITED := "the board changed under it — re-open View ▸ Fab preview (exact) to re-render the emitted artwork"
const STALE_BOARD_MOVED_IN_FLIGHT := "the board changed while it was rendering — re-open View ▸ Fab preview (exact)"


static func stale_reply(reason: String) -> Dictionary:
	return {"ok": false, "error": {"kind": "stale", "message": reason}}


## Why an overlay fetch came back with nothing, in a human's words. "" for a
## reply that succeeded.
##
## THE REPLY'S OWN WORDS when it supplied any — the same rule
## pcb_load_checks._note follows, so this line cannot drift from what the
## channel actually said.
static func failure_reason(reply: Dictionary) -> String:
	if bool(reply.get("ok", false)):
		return ""
	var raw: Variant = reply.get("error")
	var error: Dictionary = raw if raw is Dictionary else {}
	var kind := str(error.get("kind", ""))
	var message := str(error.get("message", ""))
	for marker in _CAP_MARKERS:
		if kind.findn(marker) != -1 or message.findn(marker) != -1:
			return _CAP_NOTE
	if not message.is_empty():
		return message
	if not kind.is_empty():
		return kind
	return "the worker returned no result and no reason"


## The held status lead for every overlay currently retracted, or "" when none
## is. `leads` maps canvas flag name -> reason.
##
## It LEADS the status line because the label ellipsizes on overflow; the
## tooltip carries the rest (PCBPanel._set_status).
static func status_lead(leads: Dictionary) -> String:
	if leads.is_empty():
		return ""
	var parts := PackedStringArray()
	for flag in leads:
		parts.append("%s OFF — %s" % [
			str(OVERLAY_LABELS.get(str(flag), str(flag))), str(leads[flag])])
	return "%s  •  " % "  •  ".join(parts)

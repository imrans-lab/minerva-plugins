package session

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"reflect"
	"sort"
	"strings"

	"github.com/ipeerbhai/plugins/council/internal/contract"
)

// This file holds the commands that build a grounded member: capturing the
// material, editing the identity that reads it, and moving that identity onto a
// newer capture.
//
// None of them touches a session. A session embeds the definition it was run
// against, so a capture made today cannot reach into yesterday's run: the old
// contribution still names the source revision it actually read, and that
// revision is still in the session's own copy. That is the whole reason
// re-grounding is a command of its own rather than a side effect of capturing.

// cmdSourceCapture turns user-supplied text — a note, a document, or a pasted
// excerpt — into a source revision.
//
// It exists beside source.upsert, which takes a source record the caller has
// already built, because the hash and the excerpt spans have exactly one
// correct value and two places computing them will eventually disagree. Here
// the caller supplies the material and the quotes; the engine derives the rest
// and refuses a quote it cannot place.
//
// Naming an existing revision that holds no material repairs it instead:
// an import without content leaves inventory entries whose content_hash says
// which bytes are missing, and material that hashes to the same value is the
// same capture returning, not a new one.
func cmdSourceCapture(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	defID, f := need(req.Payload, "definition_id")
	if f != nil {
		return nil, f
	}
	srcID, f := need(req.Payload, "source_id")
	if f != nil {
		return nil, f
	}
	text, _ := req.Payload["text"].(string)
	if text == "" {
		return nil, fail(CodeInternal, "payload field \"text\" is required and carries the captured material", false)
	}
	if len(text) > contract.InlineLimit {
		return nil, fail(CodePayloadTooLarge, fmt.Sprintf(
			"the captured text is %d bytes and one inline field carries %d; capture a shorter excerpt, or store the material as a blob and use source.upsert",
			len(text), contract.InlineLimit), false)
	}
	def, _ := findByID(snap["definitions"], "definition_id", defID)
	if def == nil {
		return nil, missingDefinition(defID)
	}

	hash := contentHash(text)
	requested, repairing, f := revisionArg(req.Payload)
	if f != nil {
		return nil, f
	}
	var target map[string]any
	highest := 0
	for _, x := range arr(def["sources"]) {
		src := obj(x)
		if str(src["source_id"]) != srcID {
			continue
		}
		at := int(num(src["source_revision"]))
		if at > highest {
			highest = at
		}
		if repairing && at == requested {
			target = src
		}
	}
	if repairing && target == nil {
		return nil, fail(CodeMissingSource, fmt.Sprintf(
			"source %q has no revision %d in council %q; omit source_revision to capture a new one", srcID, requested, defID), false)
	}

	var out map[string]any
	if target != nil {
		out, f = repairSource(target, text, hash, req)
	} else {
		out, f = s.captureSource(def, srcID, highest+1, text, hash, req)
	}
	if f != nil {
		return nil, f
	}
	// Capturing material changes the council, so the definition moves with it.
	def["definition_revision"] = float64(int(num(def["definition_revision"])) + 1)
	if f := s.validateRecord("council_definition", def); f != nil {
		return nil, f
	}
	out["definition_id"] = defID
	out["definition_revision"] = int(num(def["definition_revision"]))
	out["source_id"] = srcID
	out["content_hash"] = hash
	return out, nil
}

// captureSource mints the next revision of a source. A revision is a capture,
// never an edit, so it is always a new record beside the old ones.
func (s *Store) captureSource(def map[string]any, srcID string, revision int, text, hash string, req *Request) (map[string]any, *Failure) {
	title, f := need(req.Payload, "title")
	if f != nil {
		return nil, f
	}
	anchors, f := buildAnchors(text, arr(req.Payload["excerpts"]))
	if f != nil {
		return nil, f
	}
	src := map[string]any{
		"source_id":       srcID,
		"source_revision": float64(revision),
		"title":           title,
		"captured_at":     s.now(),
		"content_hash":    hash,
		"payload":         inlinePayload(text, hash, str(req.Payload["content_type"])),
		"anchors":         anchors,
	}
	for _, key := range []string{"author", "locator"} {
		if v := str(req.Payload[key]); v != "" {
			src[key] = v
		}
	}
	if artifact := obj(req.Payload["artifact"]); artifact != nil {
		src["artifact"] = artifact
	}
	def["sources"] = append(arr(def["sources"]), src)
	return map[string]any{
		"source_revision": revision,
		"anchor_ids":      anchorIDs(anchors),
		"repaired":        false,
	}, nil
}

// repairSource puts the material back into an inventory entry that arrived
// without it. The recorded hash is the gate: the same bytes are the same
// capture, and anything else is different material that has to be captured as
// its own revision rather than rewriting what a past contribution read.
func repairSource(src map[string]any, text, hash string, req *Request) (map[string]any, *Failure) {
	revision := int(num(src["source_revision"]))
	if src["payload"] != nil {
		return nil, fail(CodeInternal, fmt.Sprintf(
			"source %q revision %d already holds its material; a change to the material is a new source_revision, never an edit of an old one",
			str(src["source_id"]), revision), false)
	}
	if recorded := str(src["content_hash"]); recorded != hash {
		return nil, fail(CodeMissingSource, fmt.Sprintf(
			"the text supplied hashes to %s but revision %d of %q captured %s; this is different material, so capture it as a new revision rather than repairing this one",
			hash, revision, str(src["source_id"]), recorded), false)
	}
	// The stored anchors are the authority on what may be cited; only their
	// spans are recovered, because the quotes were fixed when the capture was
	// made and a citation already points at them.
	anchors, f := buildAnchors(text, arr(src["anchors"]))
	if f != nil {
		return nil, f
	}
	src["anchors"] = anchors
	src["payload"] = inlinePayload(text, hash, str(req.Payload["content_type"]))
	// A repair is also where a reference the user re-found is re-attached.
	if artifact := obj(req.Payload["artifact"]); artifact != nil {
		src["artifact"] = artifact
	}
	return map[string]any{
		"source_revision": revision,
		"anchor_ids":      anchorIDs(anchors),
		"repaired":        true,
	}, nil
}

// buildAnchors places each excerpt inside the captured text. A quote that
// appears nowhere is refused, and so is one that appears twice: an anchor whose
// span was guessed would put a citation next to text the member never read.
// An entry that already carries a span keeping its quote is left as it is,
// which is what lets a repair recover an anchor the capture placed by hand.
func buildAnchors(text string, entries []any) ([]any, *Failure) {
	anchors := []any{}
	seen := map[string]bool{}
	for i, x := range entries {
		entry := obj(x)
		id := str(entry["anchor_id"])
		quote := str(entry["quote"])
		if id == "" || quote == "" {
			return nil, fail(CodeInternal, fmt.Sprintf("excerpt %d needs both an anchor_id and the quote it marks", i), false)
		}
		if seen[id] {
			return nil, fail(CodeInternal, fmt.Sprintf("anchor_id %q is used twice; a citation would not know which excerpt it meant", id), false)
		}
		seen[id] = true

		start, end := int(num(entry["start"])), int(num(entry["end"]))
		if !(start >= 0 && end <= len(text) && start <= end && text[start:end] == quote) {
			at := strings.Index(text, quote)
			if at < 0 {
				return nil, fail(CodeMissingSource, fmt.Sprintf(
					"excerpt %q does not appear in the captured text; quote it exactly as it is written", id), false)
			}
			if strings.Contains(text[at+1:], quote) {
				return nil, fail(CodeInternal, fmt.Sprintf(
					"excerpt %q appears more than once in the captured text; quote more of the surrounding sentence so the anchor is unambiguous", id), false)
			}
			start, end = at, at+len(quote)
		}
		anchors = append(anchors, map[string]any{
			"anchor_id": id,
			"quote":     quote,
			"start":     float64(start),
			"end":       float64(end),
		})
	}
	return anchors, nil
}

// cmdMemberUpsert creates or edits one member identity without touching the
// seat that holds it. Identity and responsibility are separate records, so
// renaming what a member is responsible for cannot rename the member, and a
// member can exist before anyone decides where to seat them.
//
// The member in the payload is the whole identity, not a patch: an omitted
// field is an identity without that field, which is what makes "clear the
// limitations" expressible at all.
//
// member_revision is minted here rather than supplied. It advances when what
// the member is grounded in or answerable for changes — the things that would
// make an old answer wrong if it were re-attributed — and stays put for a
// cosmetic edit such as a display name. A resend of the identity already stored
// reports changed:false and moves no revision at all.
func cmdMemberUpsert(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	defID, f := need(req.Payload, "definition_id")
	if f != nil {
		return nil, f
	}
	member := obj(req.Payload["member"])
	if member == nil {
		return nil, fail(CodeInternal, "payload field \"member\" is required and must be a member record", false)
	}
	if member["member_revision"] != nil {
		return nil, fail(CodeInternal, "member_revision is minted by the engine when the identity changes; leave it out", false)
	}
	memberID := str(member["member_id"])
	if memberID == "" {
		return nil, fail(CodeInternal, "member field \"member_id\" is required", false)
	}
	def, _ := findByID(snap["definitions"], "definition_id", defID)
	if def == nil {
		return nil, missingDefinition(defID)
	}

	next := deepCopy(member)
	existing, at := findByID(def["members"], "member_id", memberID)
	revision := 1
	if existing != nil {
		revision = int(num(existing["member_revision"]))
		if consultedIdentityChanged(existing, next) {
			revision++
		}
	}
	next["member_revision"] = float64(revision)

	// A resend that would store the identity already stored moves nothing. A
	// panel that saves on every keystroke, or a caller replaying a form, would
	// otherwise advance definition_revision and make every other open view
	// stale for a write that changed no byte.
	if existing != nil && reflect.DeepEqual(existing, next) {
		return map[string]any{
			"definition_id":       defID,
			"definition_revision": int(num(def["definition_revision"])),
			"member_id":           memberID,
			"member_revision":     revision,
			"created":             false,
			"seated":              holdsSeat(def, memberID),
			"changed":             false,
		}, nil
	}

	members := arr(def["members"])
	if existing != nil {
		members[at] = next
	} else {
		members = append(members, next)
	}
	def["members"] = members
	def["definition_revision"] = float64(int(num(def["definition_revision"])) + 1)
	if f := s.validateRecord("council_definition", def); f != nil {
		return nil, f
	}

	return map[string]any{
		"definition_id":       defID,
		"definition_revision": int(num(def["definition_revision"])),
		"member_id":           memberID,
		"member_revision":     revision,
		"created":             existing == nil,
		"seated":              holdsSeat(def, memberID),
		"changed":             true,
	}, nil
}

// holdsSeat reports whether anyone seated this member. A member with no seat is
// a normal state, not an error — but it is one the caller has to know about,
// because an unseated member is consulted by nothing.
func holdsSeat(def map[string]any, memberID string) bool {
	for _, x := range arr(def["seats"]) {
		if str(obj(x)["member_id"]) == memberID {
			return true
		}
	}
	return false
}

// consultedIdentityChanged reports whether an edit changes what the member was
// asked to be. These are the fields a contribution is answerable to: a past
// answer produced under a different scope, gap statement, grounding, kind or
// attribution is a different member's answer, and the revision has to say so.
func consultedIdentityChanged(before, after map[string]any) bool {
	for _, key := range []string{"kind", "represents", "scope", "limitations"} {
		if str(before[key]) != str(after[key]) {
			return true
		}
	}
	return groundingKey(before) != groundingKey(after)
}

// groundingKey renders a member's grounding as a comparable string. Order is
// not meaning, so it is sorted: reordering the same sources is not a change.
func groundingKey(member map[string]any) string {
	refs := []string{}
	for _, x := range arr(member["grounding"]) {
		ref := obj(x)
		refs = append(refs, fmt.Sprintf("%s@%d", str(ref["source_id"]), int(num(ref["source_revision"]))))
	}
	sort.Strings(refs)
	return strings.Join(refs, ",")
}

// cmdMemberAdoptSource is the explicit act of moving a member onto a different
// capture of a source it is already grounded in — or onto one it is not.
//
// Nothing does this on the member's behalf. A new capture appears beside the
// old one and every member keeps reading what they were grounded in until
// somebody decides otherwise, because the alternative is that yesterday's
// answer silently starts claiming to be about today's text.
func cmdMemberAdoptSource(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	defID, f := need(req.Payload, "definition_id")
	if f != nil {
		return nil, f
	}
	memberID, f := need(req.Payload, "member_id")
	if f != nil {
		return nil, f
	}
	srcID, f := need(req.Payload, "source_id")
	if f != nil {
		return nil, f
	}
	def, _ := findByID(snap["definitions"], "definition_id", defID)
	if def == nil {
		return nil, missingDefinition(defID)
	}
	member, _ := findByID(def["members"], "member_id", memberID)
	if member == nil {
		return nil, fail(CodeInternal, fmt.Sprintf("member %q is not on council %q", memberID, defID), false)
	}

	// With no source_revision the newest capture is adopted, which is the
	// common case: the user has just re-read the note and wants this member to
	// read it too.
	wanted, named, f := revisionArg(req.Payload)
	if f != nil {
		return nil, f
	}
	newest := 0
	found := false
	known := false
	for _, x := range arr(def["sources"]) {
		src := obj(x)
		if str(src["source_id"]) != srcID {
			continue
		}
		known = true
		at := int(num(src["source_revision"]))
		if at > newest {
			newest = at
		}
		if named && at == wanted {
			found = true
		}
	}
	if !known {
		return nil, fail(CodeMissingSource, fmt.Sprintf("source %q is not in council %q", srcID, defID), false)
	}
	if !named {
		wanted = newest
	} else if !found {
		return nil, fail(CodeMissingSource, fmt.Sprintf("source %q has no revision %d in council %q", srcID, wanted, defID), false)
	}

	grounding := arr(member["grounding"])
	previous := 0
	grounded := false
	for _, x := range grounding {
		ref := obj(x)
		if str(ref["source_id"]) != srcID {
			continue
		}
		grounded = true
		previous = int(num(ref["source_revision"]))
		if previous == wanted {
			// Already reading it. Reporting no change keeps the snapshot
			// revision still, so an idle adopt cannot invalidate every open
			// view.
			return map[string]any{
				"definition_id":   defID,
				"member_id":       memberID,
				"member_revision": int(num(member["member_revision"])),
				"source_id":       srcID,
				"source_revision": wanted,
				"changed":         false,
			}, nil
		}
		ref["source_revision"] = float64(wanted)
	}
	if !grounded {
		grounding = append(grounding, map[string]any{
			"source_id":       srcID,
			"source_revision": float64(wanted),
		})
		member["grounding"] = grounding
	}

	member["member_revision"] = float64(int(num(member["member_revision"])) + 1)
	def["definition_revision"] = float64(int(num(def["definition_revision"])) + 1)
	if f := s.validateRecord("council_definition", def); f != nil {
		return nil, f
	}
	out := map[string]any{
		"definition_id":       defID,
		"definition_revision": int(num(def["definition_revision"])),
		"member_id":           memberID,
		"member_revision":     int(num(member["member_revision"])),
		"source_id":           srcID,
		"source_revision":     wanted,
		"changed":             true,
	}
	if grounded {
		out["previous_source_revision"] = previous
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

// revisionArg reads the optional source_revision from a command payload.
// Presence is the question, not the value: reading an omitted field as zero
// would only work while revisions happen to start at 1, and a caller that sends
// an explicit 0 would be answered as though it had sent nothing. A revision
// below 1 is refused rather than rounded into a sentinel.
func revisionArg(payload map[string]any) (int, bool, *Failure) {
	raw, present := payload["source_revision"]
	if !present || raw == nil {
		return 0, false, nil
	}
	revision := int(num(raw))
	if revision < 1 {
		return 0, false, fail(CodeInternal, fmt.Sprintf(
			"source_revision %v is not a revision; revisions count from 1, and omitting the field means the newest capture", raw), false)
	}
	return revision, true, nil
}

// contentHash is the one place captured bytes are hashed, in the ContentHash
// form common.schema.json defines.
func contentHash(text string) string {
	sum := sha256.Sum256([]byte(text))
	return "sha256:" + hex.EncodeToString(sum[:])
}

func inlinePayload(text, hash, contentType string) map[string]any {
	if contentType == "" {
		contentType = "text/plain"
	}
	return map[string]any{
		"content_type": contentType,
		"byte_length":  float64(len(text)),
		"content_hash": hash,
		"inline":       text,
	}
}

func anchorIDs(anchors []any) []any {
	out := []any{}
	for _, a := range anchors {
		out = append(out, str(obj(a)["anchor_id"]))
	}
	return out
}

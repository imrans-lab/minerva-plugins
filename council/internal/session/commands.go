package session

import (
	"encoding/json"
	"fmt"

	"github.com/ipeerbhai/plugins/council/internal/contract"
)

// command is one entry in the protocol's closed command set.
//
// There is deliberately no "mutates" flag here. The contract already classifies
// every command — its envelope invariant refuses a mutating command that omits
// base_revision and a read that carries one — so by the time a request has
// passed validation, the presence of base_revision IS the classification.
// Dispatch reads it from the request rather than from a second table that could
// drift out of step with the contract's.
type command struct {
	apply func(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure)

	// after, when a command sets one, runs with the engine lock RELEASED and
	// produces the reply the caller actually receives. It is how a command that
	// has to wait — run.start and run.retry, which set a round going, and
	// run.await, which watches one — waits without the engine waiting with it:
	// every other command is served throughout, which is what makes a cancel or
	// a read arriving mid-round answerable at all. A command without one
	// replies from apply.
	after func(s *Store, req *Request, payload map[string]any) Reply
}

// commands is the whole dispatch table, one entry per Command in
// envelope.schema.json. A command in the schema with no entry here is reported
// rather than ignored.
var commands = map[string]command{
	"snapshot.get":        {apply: cmdSnapshotGet},
	"source.fetch":        {apply: cmdSourceFetch},
	"definition.export":   {apply: cmdDefinitionExport},
	"definition.upsert":   {apply: cmdDefinitionUpsert},
	"definition.import":   {apply: cmdDefinitionImport},
	"source.upsert":       {apply: cmdSourceUpsert},
	"source.capture":      {apply: cmdSourceCapture},
	"member.upsert":       {apply: cmdMemberUpsert},
	"member.adopt_source": {apply: cmdMemberAdoptSource},
	"session.create":      {apply: cmdSessionCreate},
	"session.bind_chat":   {apply: cmdSessionBindChat},
	"run.start":           {apply: cmdRunStart, after: afterRunStart},
	"run.await":           {apply: cmdRunAwait, after: afterRunAwait},
	"run.cancel":          {apply: cmdRunCancel},
	"run.retry":           {apply: cmdRunRetry, after: afterRunStart},
	"outcome.retain":      {apply: cmdOutcomeRetain},
}

// ---------------------------------------------------------------------------
// reads
// ---------------------------------------------------------------------------

func cmdSnapshotGet(_ *Store, snap map[string]any, _ *Request) (map[string]any, *Failure) {
	return map[string]any{"snapshot": deepCopy(snap)}, nil
}

func cmdSourceFetch(_ *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	defID, f := need(req.Payload, "definition_id")
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
	// With no source_revision the newest capture is returned. Array order is not
	// a version order, and answering with whichever capture happens to be first
	// would silently ground a reader in superseded material.
	revision := int(num(req.Payload["source_revision"]))
	var found map[string]any
	for _, x := range arr(def["sources"]) {
		src := obj(x)
		if str(src["source_id"]) != srcID {
			continue
		}
		at := int(num(src["source_revision"]))
		if revision != 0 {
			if at == revision {
				found = src
				break
			}
			continue
		}
		if found == nil || at > int(num(found["source_revision"])) {
			found = src
		}
	}
	if found == nil {
		if revision == 0 {
			return nil, fail(CodeMissingSource,
				fmt.Sprintf("source %q is not in council %q", srcID, defID), false)
		}
		return nil, fail(CodeMissingSource,
			fmt.Sprintf("source %q at revision %d is not in council %q", srcID, revision, defID), false)
	}
	return map[string]any{"source": deepCopy(found)}, nil
}

func cmdDefinitionExport(_ *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	defID, f := need(req.Payload, "definition_id")
	if f != nil {
		return nil, f
	}
	def, _ := findByID(snap["definitions"], "definition_id", defID)
	if def == nil {
		return nil, missingDefinition(defID)
	}
	includeContent, _ := req.Payload["include_content"].(bool)
	// include_source_ids is the user's per-source choice. Absent means "every
	// source", present means exactly these — including present-but-empty, which
	// is how the panel says "the inventory only". It is distinguished from
	// absent here, because the difference is the whole point of the field.
	var selected []string
	if raw, ok := req.Payload["include_source_ids"].([]any); ok {
		selected = []string{}
		for _, x := range raw {
			selected = append(selected, str(x))
		}
	}
	exported, included, withheld, err := contract.ExportDefinition(def, includeContent, selected)
	if err != nil {
		return nil, fail(CodeInternal, "could not build the portable definition: "+err.Error(), false)
	}
	return map[string]any{
		"definition":          exported,
		"include_content":     includeContent,
		"included_source_ids": asAny(included),
		"withheld_source_ids": asAny(withheld),
	}, nil
}

// asAny widens a string list for a JSON payload. The reply is decoded JSON
// everywhere else, so a []string would be the one value in it that is not.
func asAny(values []string) []any {
	out := []any{}
	for _, v := range values {
		out = append(out, v)
	}
	return out
}

// ---------------------------------------------------------------------------
// definitions and sources
// ---------------------------------------------------------------------------

func cmdDefinitionUpsert(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	return putDefinition(s, snap, req, true)
}

// cmdDefinitionImport brings a council in from outside the project. It refuses
// an id the project already holds: an import that silently replaced an existing
// council would destroy work the user never offered up.
func cmdDefinitionImport(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	return putDefinition(s, snap, req, false)
}

func putDefinition(s *Store, snap map[string]any, req *Request, allowReplace bool) (map[string]any, *Failure) {
	def := obj(req.Payload["definition"])
	if def == nil {
		return nil, fail(CodeInternal, "payload field \"definition\" is required and must be a council_definition record", false)
	}
	if f := s.validateRecord("council_definition", def); f != nil {
		return nil, f
	}
	id := str(def["definition_id"])
	revision := int(num(def["definition_revision"]))
	existing, at := findByID(snap["definitions"], "definition_id", id)

	if existing != nil && !allowReplace {
		return nil, fail(CodeInternal,
			fmt.Sprintf("council %q is already in this project; edit it with definition.upsert or import it under a new definition_id", id), false)
	}
	if existing != nil && revision <= int(num(existing["definition_revision"])) {
		return nil, fail(CodeInternal,
			fmt.Sprintf("definition_revision %d is not ahead of the stored revision %d; an edit advances the revision it was written against",
				revision, int(num(existing["definition_revision"]))), false)
	}

	definitions := arr(snap["definitions"])
	if existing != nil {
		definitions[at] = def
	} else {
		definitions = append(definitions, def)
	}
	snap["definitions"] = definitions

	out := map[string]any{
		"definition_id":       id,
		"definition_revision": revision,
		"replaced":            existing != nil,
	}
	// An import names the material it could not find rather than presenting an
	// ungrounded member as grounded.
	if !allowReplace {
		missing := []any{}
		for _, x := range arr(def["sources"]) {
			src := obj(x)
			if src["payload"] == nil {
				missing = append(missing, map[string]any{
					"source_id":       str(src["source_id"]),
					"source_revision": num(src["source_revision"]),
					"title":           str(src["title"]),
				})
			}
		}
		out["sources_without_content"] = missing
	}
	return out, nil
}

// cmdSourceUpsert captures new material into a council. A source revision is a
// capture and never an edit, so re-using an existing (source_id, revision) pair
// is refused: a past contribution has to stay inspectable against the bytes it
// actually read.
func cmdSourceUpsert(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	defID, f := need(req.Payload, "definition_id")
	if f != nil {
		return nil, f
	}
	src := obj(req.Payload["source"])
	if src == nil {
		return nil, fail(CodeInternal, "payload field \"source\" is required", false)
	}
	def, _ := findByID(snap["definitions"], "definition_id", defID)
	if def == nil {
		return nil, missingDefinition(defID)
	}
	srcID := str(src["source_id"])
	revision := int(num(src["source_revision"]))
	for _, x := range arr(def["sources"]) {
		other := obj(x)
		if str(other["source_id"]) == srcID && int(num(other["source_revision"])) == revision {
			return nil, fail(CodeInternal,
				fmt.Sprintf("source %q already has a revision %d; a change to the material is a new source_revision, never an edit of an old one", srcID, revision), false)
		}
	}
	def["sources"] = append(arr(def["sources"]), src)
	// Capturing material changes the council, so the definition moves with it.
	def["definition_revision"] = float64(int(num(def["definition_revision"])) + 1)
	return map[string]any{
		"definition_id":       defID,
		"definition_revision": int(num(def["definition_revision"])),
		"source_id":           srcID,
		"source_revision":     revision,
	}, nil
}

// ---------------------------------------------------------------------------
// sessions
// ---------------------------------------------------------------------------

func cmdSessionCreate(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	sessionID, f := need(req.Payload, "session_id")
	if f != nil {
		return nil, f
	}
	defID, f := need(req.Payload, "definition_id")
	if f != nil {
		return nil, f
	}
	question, f := need(req.Payload, "question")
	if f != nil {
		return nil, f
	}
	chatID, f := need(req.Payload, "chat_id")
	if f != nil {
		return nil, fail(CodeMissingChat, "a session is bound to a chat at creation; payload field \"chat_id\" is required", false)
	}
	if existing, _ := findByID(snap["sessions"], "session_id", sessionID); existing != nil {
		return nil, fail(CodeInternal, fmt.Sprintf("session %q already exists", sessionID), false)
	}
	def, _ := findByID(snap["definitions"], "definition_id", defID)
	if def == nil {
		return nil, missingDefinition(defID)
	}

	binding := map[string]any{"chat_id": chatID, "bound_at": s.now()}
	if origin := str(req.Payload["origin_message_id"]); origin != "" {
		binding["origin_message_id"] = origin
	}
	// The definition is embedded, not referenced: later edits to the council
	// must never rewrite what was actually asked of whom.
	session := map[string]any{
		"schema_version":      float64(SchemaVersion),
		"record_kind":         "council_session",
		"session_id":          sessionID,
		"session_revision":    float64(1),
		"definition_snapshot": deepCopy(def),
		"chat_binding":        binding,
		"question":            question,
		"runs":                []any{},
		"outcomes":            []any{},
	}
	// Even here, where the answer can only be "draft", the status comes from the
	// derivation: it is the single oracle the invariants check every record
	// against, and a literal would be a second opinion.
	session["status"] = contract.DeriveSessionStatus(session)
	if ctx := obj(req.Payload["context_snapshot"]); ctx != nil {
		session["context_snapshot"] = ctx
	}
	if f := s.validateRecord("council_session", session); f != nil {
		return nil, f
	}
	snap["sessions"] = append(arr(snap["sessions"]), session)
	return map[string]any{
		"session_id":          sessionID,
		"session_revision":    1,
		"definition_id":       defID,
		"definition_revision": int(num(def["definition_revision"])),
		"status":              str(session["status"]),
	}, nil
}

func cmdSessionBindChat(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	session, f := requireSession(snap, req)
	if f != nil {
		return nil, f
	}
	chatID, f := need(req.Payload, "chat_id")
	if f != nil {
		return nil, fail(CodeMissingChat, "payload field \"chat_id\" is required", false)
	}
	binding := map[string]any{"chat_id": chatID, "bound_at": s.now()}
	if origin := str(req.Payload["origin_message_id"]); origin != "" {
		binding["origin_message_id"] = origin
	}
	if missing, ok := req.Payload["missing"].(bool); ok {
		binding["missing"] = missing
	}
	// One chat has one session. The chat provider routes by chat_id alone, so
	// leaving the id on a second session would leave a follow-up's destination
	// to array order. Moving the binding is the whole of the act: the session
	// it came from keeps its question, its runs and its outcomes, and simply
	// stops being where that chat's replies go.
	//
	// checkSnapshot enforces the same rule over the finished document, so a
	// caller reaching the snapshot any other way is refused rather than trusted.
	released := []any{}
	for _, x := range arr(snap["sessions"]) {
		other := obj(x)
		if other == nil || str(other["session_id"]) == str(session["session_id"]) {
			continue
		}
		if str(obj(other["chat_binding"])["chat_id"]) != chatID {
			continue
		}
		delete(other, "chat_binding")
		bumpSession(other)
		released = append(released, str(other["session_id"]))
	}
	session["chat_binding"] = binding
	bumpSession(session)
	return map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"chat_id":          chatID,
		// Named rather than silent: a view showing the old session has to know
		// it is no longer the chat's destination.
		"released_session_ids": released,
	}, nil
}

// ---------------------------------------------------------------------------
// shared payload handling
// ---------------------------------------------------------------------------

// need reads a required string field. The Failure enum has no code for "the
// caller sent something I cannot act on", so a payload fault is reported as
// internal with a message that names the field.
func need(payload map[string]any, key string) (string, *Failure) {
	value := str(payload[key])
	if value == "" {
		return "", fail(CodeInternal, fmt.Sprintf("payload field %q is required", key), false)
	}
	return value, nil
}

func missingDefinition(id string) *Failure {
	return fail(CodeInternal, fmt.Sprintf("council %q is not in this project", id), false)
}

func requireSession(snap map[string]any, req *Request) (map[string]any, *Failure) {
	id, f := need(req.Payload, "session_id")
	if f != nil {
		return nil, f
	}
	session, _ := findByID(snap["sessions"], "session_id", id)
	if session == nil {
		return nil, fail(CodeInternal, fmt.Sprintf("session %q is not in this project", id), false)
	}
	return session, nil
}

// findByID returns the element of a record array whose idField matches, plus
// its index so a caller can replace it in place.
func findByID(list any, idField, id string) (map[string]any, int) {
	for i, x := range arr(list) {
		if record := obj(x); str(record[idField]) == id {
			return record, i
		}
	}
	return nil, -1
}

// bumpSession advances the revision of the session a command touched. The
// snapshot revision is advanced separately, once, when the mutation commits.
func bumpSession(session map[string]any) {
	session["session_revision"] = float64(int(num(session["session_revision"])) + 1)
}

// validateRecord checks one record on its own before it joins the snapshot, so
// a bad definition or session is reported against its own field paths instead
// of as a snapshot-wide report the caller has to dig through.
func (s *Store) validateRecord(kind string, record map[string]any) *Failure {
	raw, err := json.Marshal(record)
	if err != nil {
		return fail(CodeInternal, "could not serialise the "+kind+" record: "+err.Error(), false)
	}
	if errs := s.registry.ValidateRecord(kind, raw); len(errs) > 0 {
		return fail(CodeInternal, "the "+kind+" record does not satisfy the contract: "+joinErrs(errs), false)
	}
	return nil
}

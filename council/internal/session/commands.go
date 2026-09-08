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
}

// commands is the whole dispatch table, one entry per Command in
// envelope.schema.json. A command in the schema with no entry here is reported
// rather than ignored.
var commands = map[string]command{
	"snapshot.get":      {cmdSnapshotGet},
	"source.fetch":      {cmdSourceFetch},
	"definition.export": {cmdDefinitionExport},
	"definition.upsert": {cmdDefinitionUpsert},
	"definition.import": {cmdDefinitionImport},
	"source.upsert":     {cmdSourceUpsert},
	"session.create":    {cmdSessionCreate},
	"session.bind_chat": {cmdSessionBindChat},
	"run.start":         {cmdRunStart},
	"run.cancel":        {cmdRunCancel},
	"run.retry":         {cmdRunRetry},
	"outcome.retain":    {cmdOutcomeRetain},
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
	exported, err := contract.ExportDefinition(def, includeContent)
	if err != nil {
		return nil, fail(CodeInternal, "could not build the portable definition: "+err.Error(), false)
	}
	return map[string]any{"definition": exported, "include_content": includeContent}, nil
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
	session["chat_binding"] = binding
	bumpSession(session)
	return map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"chat_id":          chatID,
	}, nil
}

// ---------------------------------------------------------------------------
// runs
// ---------------------------------------------------------------------------

// runKinds is the Run.kind enum. run.start takes initial_round or follow_up;
// retry is minted by run.retry so a retry cannot be forged as a fresh round.
var runKinds = map[string]bool{"initial_round": true, "follow_up": true}

func cmdRunStart(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	session, f := requireSession(snap, req)
	if f != nil {
		return nil, f
	}
	kind := str(req.Payload["kind"])
	if kind == "" {
		kind = "initial_round"
	}
	if !runKinds[kind] {
		return nil, fail(CodeInternal, fmt.Sprintf("run kind %q must be initial_round or follow_up; a retry is started with run.retry", kind), false)
	}
	prompt := str(req.Payload["prompt"])
	addressed := str(req.Payload["addressed_seat_id"])
	if kind == "follow_up" && addressed == "" && prompt == "" {
		return nil, fail(CodeInternal, "a follow-up must name either a seat or a prompt", false)
	}

	seats, f := selectSeats(session, req, addressed)
	if f != nil {
		return nil, f
	}
	run, contributionIDs := s.newRun(session, req.RequestID, kind, prompt, addressed, seats)
	session["runs"] = append(arr(session["runs"]), run)
	session["status"] = contract.DeriveSessionStatus(session)
	bumpSession(session)

	return map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"run_id":           str(run["run_id"]),
		"kind":             kind,
		"status":           "pending",
		"seat_ids":         seatIDs(seats),
		"contribution_ids": contributionIDs,
	}, nil
}

// selectSeats decides who is consulted. The choice is explicit or it is the
// whole advisory bench; when the bench is larger than the round allows, the
// command is refused rather than silently narrowed — a user must see which
// members were left out before the round runs.
func selectSeats(session map[string]any, req *Request, addressed string) ([]map[string]any, *Failure) {
	def := obj(session["definition_snapshot"])
	byID := map[string]map[string]any{}
	advisors := []map[string]any{}
	for _, x := range arr(def["seats"]) {
		seat := obj(x)
		byID[str(seat["seat_id"])] = seat
		if str(seat["role"]) == "advisor" {
			advisors = append(advisors, seat)
		}
	}

	var wanted []string
	for _, x := range arr(req.Payload["seat_ids"]) {
		wanted = append(wanted, str(x))
	}
	if len(wanted) == 0 && addressed != "" {
		wanted = []string{addressed}
	}

	selected := advisors
	if len(wanted) > 0 {
		selected = nil
		for _, id := range wanted {
			seat, ok := byID[id]
			if !ok {
				return nil, fail(CodeInternal, fmt.Sprintf("seat %q is not on this council", id), false)
			}
			if str(seat["role"]) == "chair" {
				return nil, fail(CodeInternal, "the chair synthesises the round and is not consulted as an advisor", false)
			}
			selected = append(selected, seat)
		}
	}
	if len(selected) == 0 {
		return nil, fail(CodeInternal, "this council has no advisor seat to consult", false)
	}
	max := int(num(obj(def["deliberation"])["max_members_per_round"]))
	if max > 0 && len(selected) > max {
		return nil, fail(CodeInternal, fmt.Sprintf(
			"%d seats were selected but this council allows %d per round; name the seats explicitly in seat_ids so the choice is visible",
			len(selected), max), false)
	}
	return selected, nil
}

// newRun builds a pending run with one pending contribution per consulted
// seat. Nothing is executed here: this build carries the state model, and the
// deliberation engine fills these contributions in.
func (s *Store) newRun(session map[string]any, requestID, kind, prompt, addressed string, seats []map[string]any) (map[string]any, []any) {
	taken := map[string]bool{}
	for _, x := range arr(session["runs"]) {
		run := obj(x)
		taken[str(run["run_id"])] = true
		for _, c := range arr(run["contributions"]) {
			taken[str(obj(c)["contribution_id"])] = true
		}
	}
	memberRev := map[string]float64{}
	for _, x := range arr(obj(session["definition_snapshot"])["members"]) {
		member := obj(x)
		memberRev[str(member["member_id"])] = num(member["member_revision"])
	}

	contributions := []any{}
	ids := []any{}
	for _, seat := range seats {
		memberID := str(seat["member_id"])
		id := s.mintID("con", func(c string) bool { return taken[c] })
		taken[id] = true
		ids = append(ids, id)
		contributions = append(contributions, map[string]any{
			"contribution_id": id,
			"seat_id":         str(seat["seat_id"]),
			"member_id":       memberID,
			"member_revision": memberRev[memberID],
			"status":          "pending",
			"claims":          []any{},
		})
	}

	run := map[string]any{
		"run_id":        s.mintID("run", func(c string) bool { return taken[c] }),
		"request_id":    requestID,
		"kind":          kind,
		"status":        "pending",
		"started_at":    s.now(),
		"contributions": contributions,
	}
	if prompt != "" {
		run["prompt"] = prompt
	}
	if addressed != "" {
		run["addressed_seat_id"] = addressed
	}
	return run, ids
}

// cmdRunCancel stops a run. It is deliberately tolerant of arriving late: the
// host's chat provider fires cancel_tool without awaiting it, so a cancel for a
// run that has already stopped is a success that moves nothing.
func cmdRunCancel(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	session, f := requireSession(snap, req)
	if f != nil {
		return nil, f
	}
	run, f := requireRun(session, req)
	if f != nil {
		return nil, f
	}
	status := str(run["status"])
	if status != "pending" && status != "running" {
		return map[string]any{
			"session_id": str(session["session_id"]),
			"run_id":     str(run["run_id"]),
			"status":     status,
			"changed":    false,
		}, nil
	}
	for _, x := range arr(run["contributions"]) {
		contribution := obj(x)
		switch str(contribution["status"]) {
		case "pending", "running":
			contribution["status"] = "cancelled"
		}
	}
	run["status"] = "cancelled"
	run["ended_at"] = s.now()
	run["failure"] = map[string]any{
		"code":      CodeCancelled,
		"message":   "The run was cancelled before it finished. Start it again to ask the same question.",
		"retryable": true,
	}
	session["status"] = contract.DeriveSessionStatus(session)
	bumpSession(session)
	return map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"run_id":           str(run["run_id"]),
		"status":           "cancelled",
		"changed":          true,
	}, nil
}

// cmdRunRetry starts a fresh run over the seats the previous one did not
// answer. It never resumes the old run: the process that owned those calls is
// gone, and a retry the user asked for is the only thing that spends tokens.
func cmdRunRetry(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	session, f := requireSession(snap, req)
	if f != nil {
		return nil, f
	}
	previous, f := requireRun(session, req)
	if f != nil {
		return nil, f
	}
	if status := str(previous["status"]); status == "pending" || status == "running" {
		return nil, fail(CodeInternal,
			fmt.Sprintf("run %q is still %s; cancel it before retrying", str(previous["run_id"]), status), false)
	}

	def := obj(session["definition_snapshot"])
	byID := map[string]map[string]any{}
	for _, x := range arr(def["seats"]) {
		seat := obj(x)
		byID[str(seat["seat_id"])] = seat
	}
	var seats []map[string]any
	for _, x := range arr(previous["contributions"]) {
		contribution := obj(x)
		switch str(contribution["status"]) {
		case "complete":
			continue
		}
		if seat, ok := byID[str(contribution["seat_id"])]; ok {
			seats = append(seats, seat)
		}
	}
	if len(seats) == 0 {
		return nil, fail(CodeInternal,
			fmt.Sprintf("every seat in run %q answered; there is nothing to retry", str(previous["run_id"])), false)
	}

	run, contributionIDs := s.newRun(session, req.RequestID, "retry", str(previous["prompt"]), str(previous["addressed_seat_id"]), seats)
	session["runs"] = append(arr(session["runs"]), run)
	session["status"] = contract.DeriveSessionStatus(session)
	bumpSession(session)
	return map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"run_id":           str(run["run_id"]),
		"retry_of":         str(previous["run_id"]),
		"status":           "pending",
		"seat_ids":         seatIDs(seats),
		"contribution_ids": contributionIDs,
	}, nil
}

// cmdOutcomeRetain links a conclusion the user kept to the note that holds it.
// The note is the durable artifact; this record is only the way back to the
// contribution it came from.
func cmdOutcomeRetain(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	session, f := requireSession(snap, req)
	if f != nil {
		return nil, f
	}
	run, f := requireRun(session, req)
	if f != nil {
		return nil, f
	}
	contributionID, f := need(req.Payload, "contribution_id")
	if f != nil {
		return nil, f
	}
	noteRef, f := need(req.Payload, "note_ref")
	if f != nil {
		return nil, f
	}
	note := map[string]any{"kind": "note", "ref": noteRef}
	if label := str(req.Payload["note_label"]); label != "" {
		note["label"] = label
	}
	taken := map[string]bool{}
	for _, x := range arr(session["outcomes"]) {
		taken[str(obj(x)["outcome_id"])] = true
	}
	outcome := map[string]any{
		"outcome_id":      s.mintID("out", func(c string) bool { return taken[c] }),
		"run_id":          str(run["run_id"]),
		"contribution_id": contributionID,
		"note":            note,
		"retained_at":     s.now(),
	}
	session["outcomes"] = append(arr(session["outcomes"]), outcome)
	bumpSession(session)
	return map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"outcome_id":       str(outcome["outcome_id"]),
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

func requireRun(session map[string]any, req *Request) (map[string]any, *Failure) {
	id, f := need(req.Payload, "run_id")
	if f != nil {
		return nil, f
	}
	for _, x := range arr(session["runs"]) {
		if run := obj(x); str(run["run_id"]) == id {
			return run, nil
		}
	}
	return nil, fail(CodeInternal, fmt.Sprintf("run %q is not part of session %q", id, str(session["session_id"])), false)
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

func seatIDs(seats []map[string]any) []any {
	out := []any{}
	for _, seat := range seats {
		out = append(out, str(seat["seat_id"]))
	}
	return out
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

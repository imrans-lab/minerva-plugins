package session

import (
	"encoding/json"
	"fmt"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/ipeerbhai/plugins/council/internal/contract"
)

// idPattern is the Id shape from common.schema.json. It is applied to a raw
// request before anything else, because a reply envelope has nowhere to put a
// request_id that is not a valid Id — a request that cannot be identified
// cannot be answered in the protocol and is reported as a transport error.
var idPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)

// Store is the working copy of one Council snapshot plus the idempotency
// ledger for the requests applied to it.
//
// Everything in it is process memory. Load seeds it from the wrapper's durable
// snapshot; Export hands the acknowledged state back for persistence. The
// ledger is scoped to the loaded snapshot and is cleared by Load, because a
// request_id is only meaningful against the snapshot it was written for.
type Store struct {
	generation uint64
	mu         sync.Mutex
	registry   *contract.Registry
	snapshot   map[string]any
	ledger     map[string]Reply
	seq        map[string]int

	// chat is the route to a host model. It is refusing by default, so a Store
	// nobody bound a transport to reports model_unavailable rather than hanging.
	chat ChatHost

	// catalog is the route to the host's enabled-model list, and models is what
	// it last returned. modelsKnown separates "the host has none" from "Council
	// has not been able to ask", which is the difference between refusing a
	// hint and letting it through (models.go).
	catalog     ModelCatalog
	models      []HostModel
	modelsKnown bool

	// The chat routing table (chat.go). It is process memory that OUTLIVES a
	// Load on purpose: the durable binding is each session's own chat_binding,
	// and what these add is the knowledge that a chat Council has already
	// routed, whose session is not in the document now loaded, belongs to
	// another project and must not be adopted into this one.
	//
	// chatProject maps a chat to the PROJECT that owns it, not to a load
	// generation, and every Load rebuilds it from the bindings in the document
	// it adopts (adoptChatRoutes). That is what makes the guard survive a plugin
	// restart: it is recovered from the durable record rather than remembered
	// across it. Its residual limit is stated in architecture.md §5.3.2 — a
	// chat whose owning document has not been opened at all since the restart is
	// a chat this process has no way to place.
	chatProject map[string]string
	chatPending map[string]string
	chatCouncil map[string]string
	chatSeq     int
	chatActive  map[*chatScope]struct{}

	// live holds one handle per run this engine is executing, keyed by
	// (session_id, run_id) — a run id is only unique within its session, so the
	// id alone would let two sessions share a handle. A result landing from a
	// model call is checked against the handle it was started with: an entry
	// that is gone, or replaced, means the run it belongs to is no longer the
	// current one and the reply has nowhere to go.
	live map[string]*runControl

	// now returns the timestamp written into new records. Injectable so a test
	// can assert an exact record rather than matching a wall clock.
	now func() string

	// observe is told about every commit, so the wrapper that durably owns the
	// document can find out that the engine moved it. See SetRecordObserver.
	observe RecordObserver
}

// RecordObserver is told which document the engine just advanced, and to what
// revision, after every commit that installs a new snapshot.
//
// It is called WITH THE ENGINE LOCK HELD, because the commit that produced the
// revision is the only place the pair is known to be consistent. So an
// implementation must not block and must not call back into the Store: it
// records what it was told and returns.
type RecordObserver func(projectID string, revision int)

// SetRecordObserver installs the observer. Production wires the notification
// that reaches an open panel; a Store with none simply tells nobody.
func (s *Store) SetRecordObserver(observe RecordObserver) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.observe = observe
}

// New creates a Store holding an empty snapshot at revision 1.
func New() (*Store, error) {
	r, err := contract.LoadRegistry()
	if err != nil {
		return nil, err
	}
	empty, err := emptySnapshot()
	if err != nil {
		return nil, err
	}
	return &Store{
		registry:    r,
		snapshot:    empty,
		ledger:      map[string]Reply{},
		seq:         map[string]int{},
		chat:        unavailableChatHost{},
		live:        map[string]*runControl{},
		chatProject: map[string]string{},
		chatPending: map[string]string{},
		chatCouncil: map[string]string{},
		now:         func() string { return time.Now().UTC().Format("2006-01-02T15:04:05Z") },
	}, nil
}

// SetClock replaces the timestamp source. Tests use it to make minted records
// exactly comparable; production never calls it.
func (s *Store) SetClock(f func() string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.now = f
}

// emptySnapshot is the document a backend holds before anything is loaded into
// it. It carries a project identity of its own so that it is a valid record
// like any other — and so that it can never be mistaken for a later state of a
// document the wrapper is about to hand over (Store.recoverable).
func emptySnapshot() (map[string]any, error) {
	id, err := contract.NewProjectID()
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"schema_version":    float64(SchemaVersion),
		"record_kind":       "council_project_snapshot",
		"project_id":        id,
		"snapshot_revision": float64(1),
		"definitions":       []any{},
		"sessions":          []any{},
	}, nil
}

// LoadReport says what changed when a snapshot was adopted. runs_demoted is the
// count the interruption rule acted on: work that was in flight when the owning
// process went away, and which is now a visible failure with a retry rather
// than something that quietly resumes and spends tokens.
//
// migrations names every migration step that rewrote the document, and
// recovered says the engine KEPT what it was already holding instead of taking
// the record it was handed — the panel-closed-mid-round case (§4.3). Either one
// means the record that comes back is not the record that went in, so the
// wrapper has to persist what Export now returns.
type LoadReport struct {
	SnapshotRevision int      `json:"snapshot_revision"`
	ProjectID        string   `json:"project_id"`
	Definitions      int      `json:"definitions"`
	Sessions         int      `json:"sessions"`
	RunsDemoted      int      `json:"runs_demoted"`
	Migrations       []string `json:"migrations,omitempty"`
	Recovered        bool     `json:"recovered,omitempty"`
}

// Load replaces the working snapshot with one the wrapper restored, applies the
// interruption rule, and clears the idempotency ledger. Whatever the engine was
// working on is replaced, and any run still executing is stopped.
//
// Rehydration only demotes statuses and attaches an interrupted failure, both
// of which the schema and the invariants already permit, so the validated input
// is still valid afterwards.
func (s *Store) Load(raw []byte) (LoadReport, error) {
	return s.load(raw, false)
}

// Reopen is Load for the wrapper's own seeding path: a panel making the engine
// hold ITS record. It differs in one case — when the engine is already holding a
// later state of the very same document, that state is KEPT and reported rather
// than being replaced by the older copy the panel persisted (§4.3). That is the
// panel-closed-mid-round recovery, and it is opt-in rather than part of Load
// because "load this document" otherwise has to mean exactly that: a caller
// replacing the working document must be able to rely on it.
func (s *Store) Reopen(raw []byte) (LoadReport, error) {
	return s.load(raw, true)
}

func (s *Store) load(raw []byte, allowRecovery bool) (LoadReport, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	// v0.1 moves the whole snapshot across the host's IPC hop in one message, so
	// the document itself is bounded by that hop. The refusal names the numbers
	// and what the document holds, because "too large" on its own tells a user
	// nothing they can act on.
	if len(raw) > MaxEnvelopeBytes {
		return LoadReport{}, fmt.Errorf(
			"this Council document is %d bytes and the host's IPC transport carries %d in one message, so it cannot be loaded; it holds %d council(s) and %d session(s), and v0.1 moves the whole snapshot at once",
			len(raw), MaxEnvelopeBytes, countRecords(raw, "definitions"), countRecords(raw, "sessions"))
	}
	// Migration runs BEFORE validation: an older document is not expected to
	// satisfy today's schema, and the ladder is what makes it able to. A
	// document from a newer version is refused here rather than guessed at.
	var next map[string]any
	if err := json.Unmarshal(raw, &next); err != nil {
		return LoadReport{}, err
	}
	migrations, err := contract.MigrateSnapshot(next)
	if err != nil {
		return LoadReport{}, err
	}
	if len(migrations) > 0 {
		if raw, err = json.Marshal(next); err != nil {
			return LoadReport{}, err
		}
	}
	if errs := s.registry.ValidateRecord("council_project_snapshot", raw); len(errs) > 0 {
		return LoadReport{}, fmt.Errorf("snapshot is not a valid council_project_snapshot: %s", joinErrs(errs))
	}
	if err := checkSnapshotBudget(next); err != nil {
		return LoadReport{}, err
	}

	// The panel closed while a round was running, and here it is again. The
	// engine kept executing — the contributions that landed after the panel went
	// away are in the resident snapshot and in no other place, because the
	// wrapper was not there to persist them. Taking the record the panel just
	// handed over would throw exactly that work away.
	//
	// It is safe to keep the resident copy only when it is provably the SAME
	// document and not behind: same project identity, a revision at least as
	// high, and every session and run the incoming record names still present
	// in it. The engine
	// only ever advances a record it was seeded with, so a resident that
	// satisfies all three descends from the one being handed back.
	if allowRecovery && s.recoverable(next) {
		return LoadReport{
			SnapshotRevision: s.revision(),
			ProjectID:        str(s.snapshot["project_id"]),
			Definitions:      len(arr(s.snapshot["definitions"])),
			Sessions:         len(arr(s.snapshot["sessions"])),
			Recovered:        true,
		}, nil
	}
	// The document these runs belong to is being replaced. Stop the calls, and
	// drop the handles so anything already in flight lands on nothing: a reply
	// for the old document must never write into the one taking its place.
	s.cancelLive()
	s.generation++
	clear(s.chatPending)
	clear(s.chatCouncil)

	demoted := contract.RehydrateOnLoad(next)
	// Demotion rewrites run and session statuses, so the document that comes
	// out of load is not the one that went in. It gets its own revision:
	// two different documents must never claim the same snapshot_revision, and
	// the wrapper has to persist the demoted form rather than the one it sent.
	if demoted > 0 {
		next["snapshot_revision"] = float64(int(num(next["snapshot_revision"])) + 1)
	}
	if len(migrations) > 0 && demoted == 0 {
		// A migrated document is not the document that was handed in, for the
		// same reason a demoted one is not: two different records must never
		// claim one revision, and the wrapper has to persist the migrated form.
		next["snapshot_revision"] = float64(int(num(next["snapshot_revision"])) + 1)
	}
	s.snapshot = next
	s.ledger = map[string]Reply{}
	s.seq = map[string]int{}
	s.adoptChatRoutes()
	return LoadReport{
		SnapshotRevision: s.revision(),
		ProjectID:        str(next["project_id"]),
		Definitions:      len(arr(next["definitions"])),
		Sessions:         len(arr(next["sessions"])),
		RunsDemoted:      demoted,
		Migrations:       migrations,
	}, nil
}

// recoverable reports whether the resident snapshot is a later state of the
// document being handed in, and so must be kept rather than replaced. The
// caller holds the lock.
func (s *Store) recoverable(incoming map[string]any) bool {
	project := str(s.snapshot["project_id"])
	if project == "" || project != str(incoming["project_id"]) {
		return false
	}
	// At equal revision, only identical content is evidence of the same state.
	// A copied document can keep IDs and revision while its content diverges.
	incomingRevision := int(num(incoming["snapshot_revision"]))
	if s.revision() == incomingRevision {
		return reflect.DeepEqual(s.snapshot, incoming)
	}
	if s.revision() < incomingRevision {
		return false
	}
	// Descendancy: everything the incoming record knows about, the resident one
	// still knows about. A document that has lost a session or a run is a
	// different history, not a later one — a reverted copy, say — and the
	// caller's record wins.
	for _, x := range arr(incoming["sessions"]) {
		incomingSession := obj(x)
		resident, _ := findByID(s.snapshot["sessions"], "session_id", str(incomingSession["session_id"]))
		if resident == nil {
			return false
		}
		for _, r := range arr(incomingSession["runs"]) {
			run, _ := findByID(resident["runs"], "run_id", str(obj(r)["run_id"]))
			if run == nil {
				return false
			}
		}
	}
	return true
}

// Export returns the acknowledged snapshot for the wrapper to persist. It is a
// copy: the caller cannot reach into the engine's state through it.
func (s *Store) Export() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return deepCopy(s.snapshot)
}

// Revision reports the current snapshot revision, which is the concurrency
// token every mutating command is checked against.
func (s *Store) Revision() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.revision()
}

// Status is a small summary of the working snapshot: enough to answer "what is
// this council doing" without moving the whole document.
func (s *Store) Status() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	definitions := []any{}
	for _, d := range arr(s.snapshot["definitions"]) {
		def := obj(d)
		definitions = append(definitions, map[string]any{
			"definition_id":       str(def["definition_id"]),
			"definition_revision": num(def["definition_revision"]),
			"name":                str(def["name"]),
			"seats":               len(arr(def["seats"])),
		})
	}
	sessions := []any{}
	for _, x := range arr(s.snapshot["sessions"]) {
		ses := obj(x)
		runs := []any{}
		for _, r := range arr(ses["runs"]) {
			run := obj(r)
			runs = append(runs, map[string]any{
				"run_id":        str(run["run_id"]),
				"kind":          str(run["kind"]),
				"status":        str(run["status"]),
				"contributions": len(arr(run["contributions"])),
			})
		}
		sessions = append(sessions, map[string]any{
			"session_id":       str(ses["session_id"]),
			"session_revision": num(ses["session_revision"]),
			"status":           str(ses["status"]),
			"question":         str(ses["question"]),
			"chat_id":          str(obj(ses["chat_binding"])["chat_id"]),
			"runs":             runs,
			"outcomes":         len(arr(ses["outcomes"])),
		})
	}
	return map[string]any{
		"snapshot_revision": s.revision(),
		"definitions":       definitions,
		"sessions":          sessions,
	}
}

// Dispatch applies one protocol envelope and returns the reply envelope.
//
// It returns a Go error only when no reply is possible — a message that is not
// JSON, or one whose request_id is not an Id, has nothing to address a reply
// to. Every other failure, including a refused command, comes back as a
// well-formed reply carrying a Failure the view can render.
func (s *Store) Dispatch(raw []byte) (Reply, error) {
	return s.dispatchGuarded(raw, nil)
}

func (s *Store) dispatchGuarded(raw []byte, guard func(*Request) *Failure) (Reply, error) {
	reply, cmd, req, err := s.dispatchLockedGuarded(raw, guard)
	// A command with an "after" stage has only been set up so far. The stage
	// that waits — for the members to answer, or for somebody else's run —
	// happens here, with the lock released. That is one half of what makes a
	// cancel or a read arriving mid-round answerable; the other half is the
	// protocol loop, which dispatches each tool call on its own goroutine.
	if err != nil || !reply.OK || reply.Replayed || cmd.after == nil {
		return reply, err
	}
	return cmd.after(s, req, reply.Payload), nil
}

// dispatchLocked validates one envelope and applies its command against the
// snapshot, holding the engine lock for exactly that and no longer. It returns
// the command it dispatched so Dispatch can run any deferred stage afterwards.
func (s *Store) dispatchLocked(raw []byte) (Reply, command, *Request, error) {
	return s.dispatchLockedGuarded(raw, nil)
}

func (s *Store) dispatchLockedGuarded(raw []byte, guard func(*Request) *Failure) (Reply, command, *Request, error) {
	var probe struct {
		RequestID string `json:"request_id"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return Reply{}, command{}, nil, fmt.Errorf("request is not a JSON object: %w", err)
	}
	if !idPattern.MatchString(probe.RequestID) {
		return Reply{}, command{}, nil, fmt.Errorf("request carries no usable request_id; a reply has nowhere to be addressed")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if len(raw) > MaxEnvelopeBytes {
		return errReply(probe.RequestID, s.revision(), fail(CodePayloadTooLarge,
			fmt.Sprintf("request of %d bytes exceeds the %d byte transport budget; carry the content as a blob handle instead", len(raw), MaxEnvelopeBytes),
			false)), command{}, nil, nil
	}

	// The schema and its invariants decide what a well-formed request is:
	// the command enum, the required fields, and the rule that a mutating
	// command carries base_revision while a read does not.
	if errs := s.registry.ValidateRecord("council_envelope", raw); len(errs) > 0 {
		return errReply(probe.RequestID, s.revision(), fail(CodeInternal,
			"request does not satisfy the Council envelope contract: "+joinErrs(errs), false)), command{}, nil, nil
	}

	var req Request
	if err := json.Unmarshal(raw, &req); err != nil {
		return Reply{}, command{}, nil, err
	}
	req.generation = s.generation
	if guard != nil {
		if failure := guard(&req); failure != nil {
			return errReply(req.RequestID, s.revision(), failure), command{}, &req, nil
		}
	}
	if req.Envelope != "request" {
		return errReply(req.RequestID, s.revision(), fail(CodeInternal,
			fmt.Sprintf("the backend answers requests; it was sent a %q envelope", req.Envelope), false)), command{}, nil, nil
	}

	// A repeated request_id returns the stored reply unchanged. The command is
	// applied once, so a retry after a lost reply cannot start a second run.
	// The ledger lives for the life of the process and is cleared only by Load,
	// because a request_id is only meaningful against the snapshot it was
	// written for.
	if stored, ok := s.ledger[req.RequestID]; ok {
		stored.Replayed = true
		return stored, command{}, &req, nil
	}

	cmd, known := commands[req.Command]
	if !known {
		return errReply(req.RequestID, s.revision(), fail(CodeInternal,
			fmt.Sprintf("command %q is in the schema but has no handler in this build", req.Command), false)), command{}, nil, nil
	}

	// base_revision is the classification, not a second table here: the envelope
	// invariant this request has already passed refuses a mutating command that
	// omits it and a read that carries it, so its presence says which this is.
	if req.BaseRevision != nil {
		if *req.BaseRevision != s.revision() {
			return errReply(req.RequestID, s.revision(), fail(CodeStaleRevision,
				fmt.Sprintf("base_revision %d is behind the current snapshot revision %d; re-read and retry.", *req.BaseRevision, s.revision()),
				true)), command{}, nil, nil
		}
		return s.applyMutation(&req, cmd), cmd, &req, nil
	}

	payload, f := cmd.apply(s, s.snapshot, &req)
	if f != nil {
		return errReply(req.RequestID, s.revision(), f), command{}, nil, nil
	}
	// A read is not recorded in the ledger: replaying it would return a view of
	// a revision that has since moved, which is worse than reading again.
	return okReply(req.RequestID, s.revision(), payload), cmd, &req, nil
}

// unchanged is the sentinel a mutation returns when the command it carried was
// already satisfied. It is not a failure: nothing is written and the revision
// does not move, which is how a fire-and-forget cancel for a run that has
// already stopped reports success without invalidating every other view.
var unchanged = &Failure{Code: CodeInternal, Message: "the command was already satisfied", Retryable: false}

// commit applies one mutation to a COPY of the snapshot, advances the revision,
// and installs the result only if the whole document still satisfies the
// contract. A mutation that would produce an invalid record leaves the snapshot
// untouched and the caller is told which invariant refused it.
//
// It is the single write path. Both a protocol command and a model result
// landing mid-round go through it, so neither can install a snapshot the other
// would have been refused for. The caller holds the lock.
func (s *Store) commit(mutate func(snap map[string]any) *Failure) *Failure {
	next := deepCopy(s.snapshot)
	if f := mutate(next); f != nil {
		return f
	}
	next["snapshot_revision"] = float64(s.revision() + 1)
	raw, err := json.Marshal(next)
	if err != nil {
		return fail(CodeInternal, "could not serialise the resulting snapshot: "+err.Error(), false)
	}
	if errs := s.registry.ValidateRecord("council_project_snapshot", raw); len(errs) > 0 {
		return fail(CodeInternal,
			"the change was refused because the resulting snapshot would break the contract: "+joinErrs(errs), false)
	}
	var canonical map[string]any
	if err := json.Unmarshal(raw, &canonical); err != nil {
		return fail(CodeInternal, "could not re-read the resulting snapshot: "+err.Error(), false)
	}
	if err := checkSnapshotBudget(canonical); err != nil {
		return fail(CodePayloadTooLarge, err.Error(), false)
	}
	s.snapshot = canonical
	// One write path, one place the change is announced. A chat turn and an MCP
	// tool call commit here with no panel in the exchange, and this is what
	// gives the panel that durably owns the document a chance to read it back
	// before it saves (architecture.md §5.5).
	if s.observe != nil {
		s.observe(str(canonical["project_id"]), s.revision())
	}
	return nil
}

// applyMutation runs one protocol command through the write path and builds the
// reply, remembering it against the request_id so a retry after a lost reply
// cannot apply the command twice.
func (s *Store) applyMutation(req *Request, cmd command) Reply {
	var payload map[string]any
	f := s.commit(func(next map[string]any) *Failure {
		var refused *Failure
		payload, refused = cmd.apply(s, next, req)
		if refused != nil {
			return refused
		}
		if changed, ok := payload["changed"].(bool); ok && !changed {
			return unchanged
		}
		return nil
	})
	if f != nil && f != unchanged {
		return errReply(req.RequestID, s.revision(), f)
	}
	reply := okReply(req.RequestID, s.revision(), payload)
	// Only a successful mutation is remembered, for the life of the process.
	s.ledger[req.RequestID] = reply
	return reply
}

func (s *Store) revision() int { return int(num(s.snapshot["snapshot_revision"])) }

// mintID issues the ids the backend owns — runs, contributions and outcomes.
// Every other identity is minted by the wrapper and arrives in the payload.
// The counter is per prefix so ids read predictably, and taken() skips a value
// a loaded snapshot already used.
func (s *Store) mintID(prefix string, taken func(string) bool) string {
	for {
		s.seq[prefix]++
		id := fmt.Sprintf("%s-%d", prefix, s.seq[prefix])
		if !taken(id) {
			return id
		}
	}
}

// ---------------------------------------------------------------------------
// decoding helpers — the snapshot is held as decoded JSON, not as typed structs,
// because the schemas are the source of truth for its shape and a second
// hand-maintained transcription of them is exactly what the contract forbids.
// ---------------------------------------------------------------------------

func arr(v any) []any          { a, _ := v.([]any); return a }
func obj(v any) map[string]any { m, _ := v.(map[string]any); return m }
func str(v any) string         { s, _ := v.(string); return s }
func num(v any) float64        { f, _ := v.(float64); return f }

// countRecords reports how many entries a top-level snapshot array holds. It
// decodes defensively because it is only ever called to describe a document the
// loader is already refusing, and an unreadable one must not turn a clear
// refusal into a decode error.
func countRecords(raw []byte, field string) int {
	var probe map[string]any
	if err := json.Unmarshal(raw, &probe); err != nil {
		return 0
	}
	return len(arr(probe[field]))
}

func deepCopy(m map[string]any) map[string]any {
	raw, err := json.Marshal(m)
	if err != nil {
		return map[string]any{}
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return map[string]any{}
	}
	return out
}

// joinErrs renders a validation report as one line, capped so a pathological
// document cannot push a multi-kilobyte error message through the transport.
func joinErrs(errs []string) string {
	const maxReported = 6
	if len(errs) > maxReported {
		return strings.Join(errs[:maxReported], "; ") + fmt.Sprintf("; and %d more", len(errs)-maxReported)
	}
	return strings.Join(errs, "; ")
}

package contract

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
)

// InlineLimit is the largest payload Council will carry inline. It is half of
// the host's 64 KiB pluginIPC request cap, which leaves room for the envelope
// and for the cap being counted in UTF-16 code units rather than bytes.
// Anything larger travels as a blob handle and is fetched separately.
//
// It is also the ceiling on the longest free-text fields — a contribution's
// text, a captured excerpt — because a single field that could fill the hop
// would make a snapshot unmovable.
const InlineLimit = 32768

// ClaimTextLimit is the ceiling on one claim, one question and one focused
// prompt. It is smaller than InlineLimit on purpose: those are single
// assertions and single sentences, not documents, and a schema ceiling nothing
// in the engine agreed with would be a ceiling the engine discovered by being
// refused. The engine truncates to this value before it writes, and the schema
// carries the same number — asserted in the contract tests, never maintained
// twice.
const ClaimTextLimit = 8000

// CheckInvariants applies the cross-field rules the JSON Schemas cannot state:
// that references resolve, that revisions agree, that a captured payload still
// hashes to what was captured, and that a claim's support label matches whether
// it cites anything. Returned messages are sorted for a stable report.
func CheckInvariants(recordKind string, value any) []string {
	var errs []string
	obj, ok := value.(map[string]any)
	if !ok {
		return []string{"(root): expected an object"}
	}
	switch recordKind {
	case "council_definition":
		checkDefinition(obj, "", &errs)
	case "council_session":
		checkSession(obj, "", &errs)
	case "council_project_snapshot":
		checkSnapshot(obj, &errs)
	case "council_envelope":
		checkEnvelope(obj, &errs)
	default:
		errs = append(errs, fmt.Sprintf("(root): unknown record kind %q", recordKind))
	}
	sort.Strings(errs)
	return errs
}

// ---------------------------------------------------------------------------
// council_definition
// ---------------------------------------------------------------------------

func checkDefinition(def map[string]any, at string, errs *[]string) {
	add := adder(at, errs)

	members := arr(def["members"])
	seats := arr(def["seats"])
	sources := arr(def["sources"])

	memberRev := map[string]float64{}
	for i, m := range members {
		mo := obj(m)
		id := str(mo["member_id"])
		if _, dup := memberRev[id]; dup {
			add("/members/%d: duplicate member_id %q", i, id)
		}
		memberRev[id] = num(mo["member_revision"])
	}

	chairs := 0
	seen := map[string]bool{}
	for i, s := range seats {
		so := obj(s)
		id := str(so["seat_id"])
		if seen[id] {
			add("/seats/%d: duplicate seat_id %q", i, id)
		}
		seen[id] = true
		if _, ok := memberRev[str(so["member_id"])]; !ok {
			add("/seats/%d: unknown member_id %q", i, str(so["member_id"]))
		}
		if str(so["role"]) == "chair" {
			chairs++
		}
	}
	if chairs != 1 {
		add("/seats: a council needs exactly one chair, found %d", chairs)
	}

	revisions := map[string]map[float64]map[string]bool{} // source -> revision -> anchors
	for i, s := range sources {
		so := obj(s)
		id := str(so["source_id"])
		rev := num(so["source_revision"])
		if revisions[id] == nil {
			revisions[id] = map[float64]map[string]bool{}
		}
		if _, dup := revisions[id][rev]; dup {
			add("/sources/%d: duplicate source revision %s@%v", i, id, rev)
		}
		anchors := map[string]bool{}
		revisions[id][rev] = anchors

		var inline string
		var hasInline bool
		if p, ok := so["payload"].(map[string]any); ok {
			inline, hasInline = checkPayload(p, fmt.Sprintf("%s/sources/%d/payload", at, i), errs)
			// The source carries the hash so that an inventory entry still
			// names its material after the payload is stripped for export.
			// The two copies describe the same capture, so they agree or the
			// record is claiming to hold something it does not.
			if got := str(p["content_hash"]); got != str(so["content_hash"]) {
				add("/sources/%d: the source's content_hash %s does not describe the payload present, which hashes to %s; a different capture is a new source_revision",
					i, str(so["content_hash"]), got)
			}
		}
		for j, a := range arr(so["anchors"]) {
			ao := obj(a)
			aid := str(ao["anchor_id"])
			if anchors[aid] {
				add("/sources/%d/anchors/%d: duplicate anchor_id %q", i, j, aid)
			}
			anchors[aid] = true
			if !hasInline {
				continue
			}
			start, end := int(num(ao["start"])), int(num(ao["end"]))
			quote := str(ao["quote"])
			if start < 0 || end > len(inline) || start > end {
				add("/sources/%d/anchors/%d: span [%d,%d) is outside the captured payload", i, j, start, end)
				continue
			}
			if inline[start:end] != quote {
				add("/sources/%d/anchors/%d: quote does not match the captured payload at [%d,%d)", i, j, start, end)
			}
		}
	}

	for i, m := range members {
		mo := obj(m)
		checkMemberKind(mo, i, add)
		for j, g := range arr(mo["grounding"]) {
			go_ := obj(g)
			sid, srev := str(go_["source_id"]), num(go_["source_revision"])
			byRev, ok := revisions[sid]
			if !ok {
				add("/members/%d/grounding/%d: unknown source_id %q", i, j, sid)
				continue
			}
			if _, ok := byRev[srev]; !ok {
				add("/members/%d/grounding/%d: unknown source revision %s@%v", i, j, sid, srev)
			}
		}
	}
}

// checkMemberKind holds the line between a functional advisor and a
// source-grounded simulant. Both are members and both answer in a round, but
// only a simulant claims to interpret a named author, and that claim is only
// honest when there is captured material behind it and the gaps are stated. A
// human member is the local user: nothing prompts them, so they have neither
// grounding nor a model.
func checkMemberKind(mo map[string]any, i int, add func(string, ...any)) {
	kind := str(mo["kind"])
	represents := strings.TrimSpace(str(mo["represents"]))
	if kind != "simulant" && represents != "" {
		add("/members/%d: only a simulant interprets a named author; a %q member must not carry represents", i, kind)
	}
	switch kind {
	case "simulant":
		if len(arr(mo["grounding"])) == 0 {
			add("/members/%d: a simulant speaks only from captured material and this one is grounded in nothing; ground it or make it an assistant", i)
		}
		if strings.TrimSpace(str(mo["scope"])) == "" {
			add("/members/%d: a simulant must state the narrow scope it can speak to", i)
		}
		if strings.TrimSpace(str(mo["limitations"])) == "" {
			add("/members/%d: a simulant must state what its grounding does NOT establish", i)
		}
	case "human":
		if len(arr(mo["grounding"])) > 0 {
			add("/members/%d: a human member is the local user and speaks for themselves; grounding belongs to a simulant", i)
		}
		if strings.TrimSpace(str(mo["model_hint"])) != "" {
			add("/members/%d: a human member is not answered by a model, so a model_hint has nothing to select", i)
		}
	}
}

// checkPayload enforces the one-of-two carriage rule and, for inline content,
// that the recorded length and hash still describe the bytes present.
func checkPayload(p map[string]any, at string, errs *[]string) (inline string, hasInline bool) {
	add := adder(at, errs)
	inlineRaw, hasInline := p["inline"].(string)
	_, hasBlob := p["blob_handle"].(string)
	switch {
	case hasInline && hasBlob:
		add(": carries both inline content and a blob_handle; exactly one is allowed")
	case !hasInline && !hasBlob:
		add(": carries neither inline content nor a blob_handle")
	}
	length := int(num(p["byte_length"]))
	if hasInline {
		if length > InlineLimit {
			add(": inline payload of %d bytes exceeds the %d byte inline limit; use a blob_handle", length, InlineLimit)
		}
		if len(inlineRaw) != length {
			add(": byte_length %d does not match the %d bytes present", length, len(inlineRaw))
		}
		sum := sha256.Sum256([]byte(inlineRaw))
		want := "sha256:" + hex.EncodeToString(sum[:])
		if str(p["content_hash"]) != want {
			add(": content_hash does not match the content present")
		}
	}
	return inlineRaw, hasInline
}

// ---------------------------------------------------------------------------
// council_session
// ---------------------------------------------------------------------------

func checkSession(s map[string]any, at string, errs *[]string) {
	add := adder(at, errs)

	// chat_binding is not checked here: the schema makes it a required property,
	// so a session without one never reaches the invariants.

	def, ok := s["definition_snapshot"].(map[string]any)
	if !ok {
		add(": missing definition_snapshot")
		return
	}
	checkDefinition(def, at+"/definition_snapshot", errs)

	if p, ok := s["context_snapshot"].(map[string]any); ok {
		checkPayload(p, at+"/context_snapshot", errs)
	}

	seatMember := map[string]string{}
	for _, seat := range arr(def["seats"]) {
		so := obj(seat)
		seatMember[str(so["seat_id"])] = str(so["member_id"])
	}
	memberRev := map[string]float64{}
	for _, m := range arr(def["members"]) {
		mo := obj(m)
		memberRev[str(mo["member_id"])] = num(mo["member_revision"])
	}
	anchors := map[string]bool{} // "source@rev#anchor"
	for _, src := range arr(def["sources"]) {
		so := obj(src)
		for _, a := range arr(so["anchors"]) {
			anchors[fmt.Sprintf("%s@%v#%s", str(so["source_id"]), num(so["source_revision"]), str(obj(a)["anchor_id"]))] = true
		}
	}

	// Claim identity is session-wide, because a follow-up names one argument by
	// its claim id and has to reach the member that made it. The map is built
	// before the runs are walked so a run may address a claim from any round.
	claimSeat := map[string]string{}
	for i, r := range arr(s["runs"]) {
		ro := obj(r)
		for _, c := range append(append([]any{}, arr(ro["contributions"])...), synthesisList(ro)...) {
			co := obj(c)
			for _, x := range arr(co["claims"]) {
				id := str(obj(x)["claim_id"])
				if _, duplicate := claimSeat[id]; duplicate {
					add("/runs/%d: claim_id %q is used twice; a follow-up naming it would not know which argument it meant", i, id)
				}
				claimSeat[id] = str(co["seat_id"])
			}
		}
	}

	requests := map[string]bool{}
	runIDs := map[string]map[string]bool{} // run -> contribution ids
	contributionIDs := map[string]bool{}
	runs := arr(s["runs"])
	for i, r := range runs {
		ro := obj(r)
		base := fmt.Sprintf("%s/runs/%d", at, i)
		if requests[str(ro["request_id"])] {
			add("/runs/%d: request_id %q is reused; it is the idempotency key and must be unique", i, str(ro["request_id"]))
		}
		requests[str(ro["request_id"])] = true

		status := str(ro["status"])
		if (status == "failed" || status == "cancelled" || status == "partial") && ro["failure"] == nil {
			add("/runs/%d: status %q must carry a failure the user can see", i, status)
		}
		if status == "complete" && ro["synthesis"] == nil {
			add("/runs/%d: a complete run must carry the chair's synthesis", i)
		}
		if str(ro["kind"]) == "follow_up" && str(ro["addressed_seat_id"]) == "" && str(ro["prompt"]) == "" {
			add("/runs/%d: a follow-up must name either a seat or a prompt", i)
		}
		// A follow-up about an argument is answered by the member that made it.
		// If the run could name a different seat, one member would be recorded
		// as answering for another's reasoning.
		if claimID := str(ro["addressed_claim_id"]); claimID != "" {
			seat, known := claimSeat[claimID]
			switch {
			case !known:
				add("/runs/%d: addressed_claim_id %q is not a claim made in this session", i, claimID)
			case str(ro["addressed_seat_id"]) != seat:
				add("/runs/%d: claim %q was made by seat %q, so this follow-up must address that seat and not %q",
					i, claimID, seat, str(ro["addressed_seat_id"]))
			}
		}

		if _, duplicate := runIDs[str(ro["run_id"])]; duplicate {
			add("/runs/%d: duplicate run_id %q", i, str(ro["run_id"]))
		}
		ids := map[string]bool{}
		runIDs[str(ro["run_id"])] = ids
		contributions := arr(ro["contributions"])
		if syn, ok := ro["synthesis"].(map[string]any); ok {
			contributions = append(contributions, syn)
		}
		for j, c := range contributions {
			co := obj(c)
			cat := fmt.Sprintf("%s/contributions/%d", base, j)
			if contributionIDs[str(co["contribution_id"])] {
				*errs = append(*errs, cat+fmt.Sprintf(": duplicate contribution_id %q", str(co["contribution_id"])))
			}
			contributionIDs[str(co["contribution_id"])] = true
			ids[str(co["contribution_id"])] = true
			seat := str(co["seat_id"])
			member, known := seatMember[seat]
			if !known {
				*errs = append(*errs, cat+fmt.Sprintf(": unknown seat_id %q", seat))
				continue
			}
			if member != str(co["member_id"]) {
				*errs = append(*errs, cat+fmt.Sprintf(": member_id %q does not hold seat %q", str(co["member_id"]), seat))
			}
			if rev := memberRev[member]; rev != num(co["member_revision"]) {
				*errs = append(*errs, cat+fmt.Sprintf(": member_revision %v does not match the consulted revision %v", num(co["member_revision"]), rev))
			}
			cstatus := str(co["status"])
			if cstatus == "failed" && co["failure"] == nil {
				*errs = append(*errs, cat+": a failed contribution must carry a failure")
			}
			if cstatus == "complete" && strings.TrimSpace(str(co["text"])) == "" {
				*errs = append(*errs, cat+": a complete contribution must carry text")
			}
			for k, cl := range arr(co["claims"]) {
				clo := obj(cl)
				lat := fmt.Sprintf("%s/claims/%d", cat, k)
				cites := arr(clo["citations"])
				switch str(clo["support"]) {
				case "source":
					if len(cites) == 0 {
						*errs = append(*errs, lat+": a 'source' claim must cite at least one anchor")
					}
				case "inference", "unknown":
					if len(cites) > 0 {
						*errs = append(*errs, lat+fmt.Sprintf(": a %q claim must not cite a source; an interpretation is never shown as something a source said", str(clo["support"])))
					}
				}
				for n, ci := range cites {
					cio := obj(ci)
					key := fmt.Sprintf("%s@%v#%s", str(cio["source_id"]), num(cio["source_revision"]), str(cio["anchor_id"]))
					if !anchors[key] {
						*errs = append(*errs, fmt.Sprintf("%s/citations/%d: unknown anchor %s", lat, n, key))
					}
				}
			}
		}
	}

	// The session status is a function of the run set and of nothing else, so it
	// is checked against that function rather than against a list of special
	// cases. This makes the derivation the single oracle: any code that writes a
	// status has to agree with DeriveSessionStatus, and a stored record that
	// disagrees is a defect rather than a matter of taste.
	if want := DeriveSessionStatus(s); str(s["status"]) != want {
		add(": status %q does not match the run set, which derives %q", str(s["status"]), want)
	}

	outcomeIDs := map[string]bool{}
	for i, o := range arr(s["outcomes"]) {
		oo := obj(o)
		if outcomeIDs[str(oo["outcome_id"])] {
			add("/outcomes/%d: duplicate outcome_id %q", i, str(oo["outcome_id"]))
		}
		outcomeIDs[str(oo["outcome_id"])] = true
		ids, ok := runIDs[str(oo["run_id"])]
		if !ok {
			add("/outcomes/%d: unknown run_id %q", i, str(oo["run_id"]))
			continue
		}
		if !ids[str(oo["contribution_id"])] {
			add("/outcomes/%d: contribution %q is not part of run %q", i, str(oo["contribution_id"]), str(oo["run_id"]))
		}
	}
}

// ---------------------------------------------------------------------------
// council_project_snapshot and envelopes
// ---------------------------------------------------------------------------

func checkSnapshot(p map[string]any, errs *[]string) {
	add := adder("", errs)
	defs := map[string]bool{}
	for i, d := range arr(p["definitions"]) {
		do := obj(d)
		if defs[str(do["definition_id"])] {
			add("/definitions/%d: duplicate definition_id %q", i, str(do["definition_id"]))
		}
		defs[str(do["definition_id"])] = true
		checkDefinition(do, fmt.Sprintf("/definitions/%d", i), errs)
	}
	sessions := map[string]bool{}
	for i, s := range arr(p["sessions"]) {
		so := obj(s)
		if sessions[str(so["session_id"])] {
			add("/sessions/%d: duplicate session_id %q", i, str(so["session_id"]))
		}
		sessions[str(so["session_id"])] = true
		checkSession(so, fmt.Sprintf("/sessions/%d", i), errs)
	}
	if v, ok := p["view"].(map[string]any); ok {
		if id := str(v["selected_session_id"]); id != "" && !sessions[id] {
			add("/view: selected_session_id %q does not exist", id)
		}
		if id := str(v["selected_definition_id"]); id != "" && !defs[id] {
			add("/view: selected_definition_id %q does not exist", id)
		}
	}
}

// mutatingCommands are the envelope commands that advance the snapshot and so
// must carry the base_revision they were written against.
var mutatingCommands = map[string]bool{
	"definition.upsert": true, "definition.import": true,
	"source.upsert": true, "source.capture": true,
	"member.upsert": true, "member.adopt_source": true,
	"session.create": true, "session.bind_chat": true,
	"run.start": true, "run.cancel": true, "run.retry": true, "outcome.retain": true,
}

func checkEnvelope(e map[string]any, errs *[]string) {
	add := adder("", errs)
	switch str(e["envelope"]) {
	case "request":
		cmd := str(e["command"])
		_, hasBase := e["base_revision"]
		if mutatingCommands[cmd] && !hasBase {
			add(": command %q mutates the snapshot and must carry base_revision", cmd)
		}
		if !mutatingCommands[cmd] && hasBase {
			add(": read command %q must not carry base_revision", cmd)
		}
	case "reply":
		ok, _ := e["ok"].(bool)
		_, hasErr := e["error"]
		if ok && hasErr {
			add(": a successful reply must not carry an error")
		}
		if !ok && !hasErr {
			add(": a failed reply must carry an error the user can act on")
		}
		if replayed, _ := e["replayed"].(bool); replayed && !ok {
			add(": a replayed reply is by definition the stored successful reply")
		}
	}
}

// ---------------------------------------------------------------------------
// small decoding helpers
// ---------------------------------------------------------------------------

func adder(at string, errs *[]string) func(string, ...any) {
	return func(format string, args ...any) {
		prefix := at
		if prefix == "" && !strings.HasPrefix(format, "/") {
			prefix = "(root)"
		}
		*errs = append(*errs, prefix+fmt.Sprintf(format, args...))
	}
}

func arr(v any) []any          { a, _ := v.([]any); return a }
func obj(v any) map[string]any { m, _ := v.(map[string]any); return m }
func str(v any) string         { s, _ := v.(string); return s }
func num(v any) float64        { f, _ := v.(float64); return f }

// synthesisList wraps a run's synthesis so it can be walked beside the member
// contributions. The chair's answer is a Contribution and its claims are as
// citable and as addressable as anybody's.
func synthesisList(run map[string]any) []any {
	if synthesis, ok := run["synthesis"].(map[string]any); ok {
		return []any{synthesis}
	}
	return nil
}

package session

import (
	"fmt"
	"time"
)

// limits is what one run is allowed to spend. Every value comes from the
// council's own deliberation rules, which the schema validates; nothing here
// has a default, because a default in code is a limit nobody can see in the
// record.
type limits struct {
	MembersPerRound  int
	Concurrent       int
	PromptBytes      int
	MemberTimeout    time.Duration
	RunBudget        time.Duration
	RoundsPerSession int // how many runs one session may hold
}

// limitFields maps each narrowable limit onto its deliberation-rules field, so
// the override path and the reading path cannot disagree about which field a
// name refers to.
var limitFields = []string{
	"max_concurrent_members",
	"max_prompt_bytes",
	"per_member_timeout_seconds",
	"run_budget_seconds",
}

// readLimits takes the council's rules and applies the run request's optional
// narrowing.
//
// A run may ask for LESS than the council permits and never for more. The
// council definition is the record a user can inspect and export; if a run
// request could raise a ceiling, the definition would stop describing what the
// council can cost, and the only place the real limit lived would be a command
// that is gone as soon as it is answered.
func readLimits(def map[string]any, payload map[string]any) (limits, *Failure) {
	rules := obj(def["deliberation"])
	effective := map[string]int{}
	for _, field := range limitFields {
		effective[field] = int(num(rules[field]))
	}

	if overrides := obj(payload["limits"]); overrides != nil {
		// An unrecognised name is refused before anything is applied: a caller
		// that misspelled a limit believes it narrowed one, and running the
		// round under the council's wider value would be the worst answer.
		for name := range overrides {
			if !knownLimit(name) {
				return limits{}, fail(CodeInternal, fmt.Sprintf(
					"limit %q is not one this council has; the narrowable limits are %v", name, limitFields), false)
			}
		}
		for _, field := range limitFields {
			raw, present := overrides[field]
			if !present || raw == nil {
				continue
			}
			wanted := int(num(raw))
			if wanted < 1 {
				return limits{}, fail(CodeInternal,
					fmt.Sprintf("limit %q must be at least 1, not %v", field, raw), false)
			}
			if wanted > effective[field] {
				return limits{}, fail(CodeInternal, fmt.Sprintf(
					"this run asked for %s of %d but the council allows %d; a run may narrow a limit and never widen it — edit the council to change what it may spend",
					field, wanted, effective[field]), false)
			}
			effective[field] = wanted
		}
	}

	return limits{
		MembersPerRound:  int(num(rules["max_members_per_round"])),
		Concurrent:       effective["max_concurrent_members"],
		PromptBytes:      effective["max_prompt_bytes"],
		MemberTimeout:    time.Duration(effective["per_member_timeout_seconds"]) * time.Second,
		RunBudget:        time.Duration(effective["run_budget_seconds"]) * time.Second,
		RoundsPerSession: int(num(rules["max_rounds_per_session"])),
	}, nil
}

func knownLimit(name string) bool {
	for _, field := range limitFields {
		if field == name {
			return true
		}
	}
	return false
}

// checkRoundBudget refuses a run that would take the session past the number of
// rounds the council allows.
//
// This is the ceiling that makes "nothing loops" more than a claim about the
// engine's own control flow: the engine starts nothing on its own, and a client
// that did could still only reach this many runs before being told to stop.
func checkRoundBudget(session map[string]any, max int) *Failure {
	held := len(arr(session["runs"]))
	if held < max {
		return nil
	}
	return fail(CodeInternal, fmt.Sprintf(
		"session %q already holds %d runs and this council allows %d; start a new session, or raise max_rounds_per_session on the council",
		str(session["session_id"]), held, max), false)
}

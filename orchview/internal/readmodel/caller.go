package readmodel

import (
	"strings"
	"time"
)

// Caller is who is asking, as the HOST established it (Minerva session
// identity). It is never read from tool arguments: a caller cannot widen its
// view by naming a principal or a dispatch id.
//
// Restricted=false is the owner's full view. Restricted=true limits the tree
// to records the caller is authorized to see (W1 KB section 5): those
// assigned, directed or claimed to its principal or its role, their
// descendants, and their ancestors as navigation context (marked partial).
// Principal and Role are a session's registered identity and role, the same
// pair the agent-container gateway scopes Docket by.
type Caller struct {
	Principal  string
	Role       string
	Restricted bool
}

// Owner is the unrestricted view the owner's Minerva GUI is shown.
var Owner = Caller{Principal: "owner", Restricted: false}

// addresses reports whether the record names the caller's principal or role.
func (c Caller) addresses(r Record) bool {
	return addressedTo(r, c.Principal) || addressedTo(r, c.Role)
}

func samePrincipal(a, b string) bool {
	a, b = strings.TrimSpace(a), strings.TrimSpace(b)
	return a != "" && strings.EqualFold(a, b)
}

// addressedTo reports whether the record names the principal as its
// intended holder, its addressee or its claim holder.
func addressedTo(r Record, principal string) bool {
	return samePrincipal(r.AssignedTo, principal) ||
		samePrincipal(r.DirectedTo, principal) ||
		samePrincipal(r.ClaimHolder, principal)
}

// SessionEvidence is one Minerva harness session as the host observed it:
// HarnessSessionRegistry's identity, role and liveness, the W1 principal the
// host maps that session to, and when the observation was made.
// LastActivityAt is set only when the host has a measured activity time.
type SessionEvidence struct {
	Principal      string
	Identity       string
	Role           string
	Liveness       string
	ObservedAt     time.Time
	LastActivityAt *time.Time
}

// knownLiveness is HarnessSessionRegistry's liveness vocabulary minus its
// "unknown". Any other value, including "unknown", carries no evidence, so a
// host cannot make this model report a state (such as idle) it never defines.
var knownLiveness = map[string]bool{
	"live": true, "other_harness": true, "no_harness": true, "exited": true, "unbound": true,
}

// Activity separates observed facts from recorded stage. Unknown is true when
// no usable observation exists; there is no idle value.
type Activity struct {
	Unknown        bool     `json:"unknown"`
	Liveness       string   `json:"liveness,omitempty"`
	ObservedAt     string   `json:"observed_at,omitempty"`
	LastActivityAt string   `json:"last_activity_at,omitempty"`
	Sessions       []string `json:"sessions,omitempty"`
}

// actorActivity describes one principal from the sessions mapped to it. A
// principal shared by several sessions (every local MCP caller on a machine
// is one principal, W1 KB section 5) cannot say which session did the work,
// so it lists them and stays unknown.
func actorActivity(principal string, sessions []SessionEvidence) Activity {
	var matched []SessionEvidence
	for _, s := range sessions {
		if samePrincipal(s.Principal, principal) {
			matched = append(matched, s)
		}
	}
	if len(matched) != 1 {
		act := Activity{Unknown: true}
		for _, s := range matched {
			act.Sessions = append(act.Sessions, s.Identity)
		}
		return act
	}
	s := matched[0]
	act := Activity{Sessions: []string{s.Identity}}
	if !knownLiveness[s.Liveness] || s.ObservedAt.IsZero() {
		act.Unknown = true
		return act
	}
	act.Liveness = s.Liveness
	act.ObservedAt = s.ObservedAt.UTC().Format(time.RFC3339)
	if s.LastActivityAt != nil {
		act.LastActivityAt = s.LastActivityAt.UTC().Format(time.RFC3339)
	}
	return act
}

// rollUp gives a record node the latest observation among its descendants'
// actors. Liveness is not rolled up: one live actor says nothing about the
// others.
func rollUp(children []*Node) Activity {
	act := Activity{Unknown: true}
	for _, c := range children {
		if c.Activity.Unknown {
			continue
		}
		act.Unknown = false
		if c.Activity.ObservedAt > act.ObservedAt {
			act.ObservedAt = c.Activity.ObservedAt
		}
		if c.Activity.LastActivityAt > act.LastActivityAt {
			act.LastActivityAt = c.Activity.LastActivityAt
		}
	}
	return act
}

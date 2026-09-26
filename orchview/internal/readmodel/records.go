// Package readmodel composes W1 work records (Docket work_items tagged wr:*)
// with Minerva session evidence into one bounded, permission-filtered tree:
// objectives → tasks → dispatch attempts → role instances → actors.
//
// It is read-only. Recorded stage comes from the records; observed activity
// comes only from session evidence the host supplies; a node with no usable
// evidence says unknown and is never reported as idle.
package readmodel

import (
	"strings"
)

// Record is one work_item as docket_get returns it (with include ["links"]).
// Project is not part of the reply; the loader sets it.
type Record struct {
	Project     string   `json:"-"`
	ID          string   `json:"id"`
	Title       string   `json:"title"`
	Status      string   `json:"status"`
	Tags        []string `json:"tags"`
	Parent      string   `json:"parent"`
	AssignedTo  string   `json:"assigned_to"`
	DirectedTo  string   `json:"directed_to"`
	BlockedBy   string   `json:"blocked_by"`
	Description string   `json:"description"`
	Resolution  string   `json:"resolution"`
	UpdatedAt   string   `json:"updated_at"`
	// Revision and ClaimHolder are absent on older Docket builds that report
	// no item revision or claim; nil and "" then.
	Revision    *int   `json:"revision"`
	ClaimHolder string `json:"claim_holder"`
	Links       []Link `json:"links"`
}

// Link is one outgoing docket link.
type Link struct {
	Relation string `json:"relation"`
	To       string `json:"to"`
}

// Key is the record's project-qualified id, the form every reference in the
// tree uses.
func (r Record) Key() string { return r.Project + ":" + r.ID }

// Kind is a tree level.
type Kind string

const (
	KindObjective Kind = "objective"
	KindTask      Kind = "task"
	KindAttempt   Kind = "attempt"
	KindRole      Kind = "role"
	KindActor     Kind = "actor"
)

// recordKind reads the wr: tag; "" for a record that is not a W1 record.
func (r Record) recordKind() Kind {
	switch {
	case r.hasTag("wr:objective"):
		return KindObjective
	case r.hasTag("wr:task"):
		return KindTask
	case r.hasTag("wr:attempt"):
		return KindAttempt
	}
	return ""
}

func (r Record) hasTag(tag string) bool {
	for _, t := range r.Tags {
		if t == tag {
			return true
		}
	}
	return false
}

// tagValue returns the value after `namespace:` of the first such tag.
func (r Record) tagValue(namespace string) string {
	values := r.tagValues(namespace)
	if len(values) == 0 {
		return ""
	}
	return values[0]
}

func (r Record) tagValues(namespace string) []string {
	prefix := namespace + ":"
	var out []string
	for _, t := range r.Tags {
		if strings.HasPrefix(t, prefix) {
			out = append(out, strings.TrimPrefix(t, prefix))
		}
	}
	return out
}

func (r Record) isDone() bool { return r.Status == "done" }

// qualify turns a reference as stored ("project:id" or a bare id meaning the
// record's own project) into project-qualified form.
func qualify(ref, ownProject string) string {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return ""
	}
	if strings.Contains(ref, ":") {
		return ref
	}
	return ownProject + ":" + ref
}

// Criterion is one DONE WHEN bullet of a task.
type Criterion struct {
	Task string `json:"task"`
	Text string `json:"text"`
}

const (
	// maxCriterionRunes and maxCriteriaPerNode bound acceptance text on one
	// node so no single node can approach the reply cap.
	maxCriterionRunes  = 300
	maxCriteriaPerNode = 20
	maxTitleRunes      = 300
)

// doneWhen extracts the bullets of a task description's DONE WHEN section
// (W1 KB section 2: GOAL / DONE WHEN / TRAPS). The section ends at the next
// all-caps heading line. A wrapped bullet's continuation lines join it.
func doneWhen(description string) []string {
	var bullets []string
	inSection := false
	for _, raw := range strings.Split(description, "\n") {
		line := strings.TrimSpace(raw)
		if isHeading(line) {
			inSection = line == "DONE WHEN"
			continue
		}
		if !inSection || line == "" {
			continue
		}
		if strings.HasPrefix(line, "- ") {
			bullets = append(bullets, strings.TrimSpace(line[2:]))
		} else if len(bullets) > 0 {
			bullets[len(bullets)-1] += " " + line
		}
	}
	return bullets
}

// isHeading reports an all-caps section heading such as "DONE WHEN" or
// "NON-GOALS (from the DCR)": upper-case letters before any parenthesis.
func isHeading(line string) bool {
	head := line
	if i := strings.Index(head, "("); i >= 0 {
		head = strings.TrimSpace(head[:i])
	}
	if head == "" || strings.HasPrefix(head, "-") {
		return false
	}
	letters := 0
	for _, c := range head {
		switch {
		case c >= 'A' && c <= 'Z':
			letters++
		case c == ' ' || c == '-' || c == '/':
		default:
			return false
		}
	}
	return letters >= 3
}

func clip(s string, runes int) string {
	r := []rune(s)
	if len(r) <= runes {
		return s
	}
	return string(r[:runes-1]) + "…"
}

package readmodel

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Identity sources a verb reply names.
const (
	// SourceCallerArgument: the view was cut for the principal in the
	// `caller` argument. The agent-container gateway stamps it with the
	// session's registered identity and refuses one the container sends.
	SourceCallerArgument = "caller_argument"
	// SourceHostDefaultOwner: no caller was named, so the owner's view was
	// returned. Minerva passes no caller identity on plugin tool calls, so
	// every host-path call lands here.
	SourceHostDefaultOwner = "host_default_owner"
)

const hostDefaultNote = "Minerva passes no caller identity on plugin tool calls, so this call was answered " +
	"with the owner's view. A `caller` argument only narrows a view; through the agent-container " +
	"gateway it is stamped with the session's registered identity."

// Identity says whom a verb reply was evaluated for and how that was decided.
type Identity struct {
	Principal string `json:"principal"`
	Role      string `json:"role,omitempty"`
	Source    string `json:"source"`
	Note      string `json:"note,omitempty"`
}

// TreeReply is minerva_orchview_tree's answer: the same page Build returns,
// plus the identity it was evaluated for.
type TreeReply struct {
	Reply
	Identity Identity `json:"identity"`
}

// Change is one record node that differs between two cursors.
type Change struct {
	ID string `json:"id"`
	// Change is added, changed or removed.
	Change string `json:"change"`
	// Node is the current node with every field group and without children;
	// absent for a removed record.
	Node *Node `json:"node,omitempty"`
}

// ChangesReply is minerva_orchview_changes's answer.
type ChangesReply struct {
	Caller   string   `json:"caller"`
	Scope    string   `json:"scope"`
	Identity Identity `json:"identity"`
	Since    string   `json:"since"`
	Cursor   string   `json:"cursor"`
	// Unchanged: nothing recorded in this caller's view changed since.
	Unchanged bool `json:"unchanged,omitempty"`
	// Reset: `since` is not a cursor this backend remembers for this caller
	// (too old, from before a restart, or cut for another view); read the
	// tree again.
	Reset   bool     `json:"reset,omitempty"`
	Changed []Change `json:"changed"`
	// ChangesTotal counts every change; Truncated says the list stops short
	// of it, in which case reading the tree again is cheaper than paging.
	ChangesTotal     int      `json:"changes_total"`
	Truncated        bool     `json:"truncated"`
	IgnoredArguments []string `json:"ignored_arguments,omitempty"`
}

// historySize bounds how many earlier views changes can diff against.
const historySize = 64

// History remembers the recorded state behind recent cursors, per caller,
// so changes can diff against a cursor a tree reply handed out. A cursor is
// only ever diffed against the view of the caller it was cut for, so a
// restricted caller cannot learn ids from another view's cursor.
//
// A History is not safe for concurrent use; the backend serialises reads.
type History struct {
	views map[string]map[string]string
	order []string
}

func NewHistory() *History {
	return &History{views: map[string]map[string]string{}}
}

func historyKey(caller Caller, cursor string) string {
	return strings.Join([]string{strconv.FormatBool(caller.Restricted), caller.Principal, caller.Role, cursor}, "\x00")
}

func (h *History) remember(caller Caller, cursor string, records []Record) {
	key := historyKey(caller, cursor)
	if _, ok := h.views[key]; ok {
		return
	}
	state := make(map[string]string, len(records))
	for _, r := range records {
		state[r.Key()] = recordLine(r)
	}
	h.views[key] = state
	h.order = append(h.order, key)
	if len(h.order) > historySize {
		delete(h.views, h.order[0])
		h.order = h.order[1:]
	}
}

// verbArgs splits a verb's arguments into the caller they name and the rest.
// `caller` and `caller_role` are consumed here; everything else is left for
// ParseQuery, which ignores what it does not know.
func verbArgs(raw json.RawMessage) (Caller, Identity, map[string]json.RawMessage, error) {
	args := map[string]json.RawMessage{}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &args); err != nil {
			return Caller{}, Identity{}, nil, fmt.Errorf("arguments must be an object: %w", err)
		}
	}
	principalRaw, named := args["caller"]
	var principal, role string
	if named {
		if err := json.Unmarshal(principalRaw, &principal); err != nil {
			return Caller{}, Identity{}, nil, fmt.Errorf("caller: %w", err)
		}
		if strings.TrimSpace(principal) == "" {
			return Caller{}, Identity{}, nil, fmt.Errorf("caller: must name a principal when present")
		}
	}
	if roleRaw, ok := args["caller_role"]; ok {
		if !named {
			return Caller{}, Identity{}, nil, fmt.Errorf("caller_role needs caller")
		}
		if err := json.Unmarshal(roleRaw, &role); err != nil {
			return Caller{}, Identity{}, nil, fmt.Errorf("caller_role: %w", err)
		}
	}
	delete(args, "caller")
	delete(args, "caller_role")
	if !named {
		return Owner, Identity{Principal: Owner.Principal, Source: SourceHostDefaultOwner, Note: hostDefaultNote}, args, nil
	}
	caller := Caller{Principal: clip(principal, 200), Role: clip(role, 200), Restricted: true}
	return caller, Identity{Principal: caller.Principal, Role: caller.Role, Source: SourceCallerArgument}, args, nil
}

// Tree serves minerva_orchview_tree: the caller comes from verbArgs, the
// bounds from ParseQuery, and the page from the same forest and pager Build
// uses. The cursor it hands out is remembered for Changes.
func (h *History) Tree(snap Snapshot, raw json.RawMessage) (TreeReply, error) {
	caller, identity, args, err := verbArgs(raw)
	if err != nil {
		return TreeReply{}, err
	}
	rest, _ := json.Marshal(args)
	q, ignored, err := ParseQuery(rest)
	if err != nil {
		return TreeReply{}, err
	}
	f := buildForest(snap.Records, snap.Sessions, caller)
	reply := page(f, caller, q, ignored)
	h.remember(caller, reply.Cursor, f.included)
	return TreeReply{Reply: reply, Identity: identity}, nil
}

// Changes serves minerva_orchview_changes: which record nodes of the
// caller's view were added, changed or removed since `cursor`.
func (h *History) Changes(snap Snapshot, raw json.RawMessage) (ChangesReply, error) {
	caller, identity, args, err := verbArgs(raw)
	if err != nil {
		return ChangesReply{}, err
	}
	var since string
	if v, ok := args["cursor"]; ok {
		if err := json.Unmarshal(v, &since); err != nil {
			return ChangesReply{}, fmt.Errorf("cursor: %w", err)
		}
		delete(args, "cursor")
	}
	if since == "" {
		return ChangesReply{}, fmt.Errorf("cursor: required; pass the cursor of an earlier minerva_orchview_tree or minerva_orchview_changes reply")
	}
	var ignored []string
	for name := range args {
		ignored = append(ignored, clip(name, 64))
	}
	sort.Strings(ignored)
	if len(ignored) > maxIgnoredEcho {
		ignored = ignored[:maxIgnoredEcho]
	}

	f := buildForest(snap.Records, snap.Sessions, caller)
	out := ChangesReply{Caller: caller.Principal, Scope: "full", Identity: identity, Since: clip(since, 200),
		Cursor: cursorOf(f.included), Changed: []Change{}, IgnoredArguments: ignored}
	if caller.Restricted {
		out.Scope = "restricted"
	}
	before, ok := h.views[historyKey(caller, since)]
	h.remember(caller, out.Cursor, f.included)
	if since == out.Cursor {
		out.Unchanged = true
		return out, nil
	}
	if !ok {
		out.Reset = true
		return out, nil
	}

	now := map[string]*Node{}
	for _, e := range flatten(f.roots, MaxDepth) {
		now[e.node.ID] = shallow(e, allFields())
	}
	changes := []Change{}
	for _, r := range f.included {
		old, existed := before[r.Key()]
		switch {
		case !existed:
			changes = append(changes, Change{ID: r.Key(), Change: "added", Node: now[r.Key()]})
		case old != recordLine(r):
			changes = append(changes, Change{ID: r.Key(), Change: "changed", Node: now[r.Key()]})
		}
	}
	current := map[string]bool{}
	for _, r := range f.included {
		current[r.Key()] = true
	}
	for key := range before {
		if !current[key] {
			changes = append(changes, Change{ID: key, Change: "removed"})
		}
	}
	sort.Slice(changes, func(i, j int) bool { return changes[i].ID < changes[j].ID })
	out.ChangesTotal = len(changes)
	if len(changes) > DefaultMaxNodes {
		changes = changes[:DefaultMaxNodes]
	}
	for count := len(changes); count >= 0; count-- {
		out.Changed = changes[:count]
		out.Truncated = count < out.ChangesTotal
		if len(mustJSON(out)) <= replyTarget {
			break
		}
	}
	return out, nil
}

func allFields() map[string]bool {
	set := map[string]bool{}
	for _, g := range fieldGroups {
		set[g] = true
	}
	return set
}

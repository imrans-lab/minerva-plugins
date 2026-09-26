package readmodel

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

const (
	// ReplyCap is the MCP reply cap, measured on the decoded reply JSON.
	ReplyCap = 64 * 1024
	// replyTarget leaves room under the cap for the host's own wrapping.
	replyTarget = ReplyCap - 2048

	MaxDepth        = 4 // objective(0) → task → attempt → role → actor(4)
	DefaultMaxNodes = 200
	MaxMaxNodes     = 2000

	maxIgnoredEcho = 20
)

// Optional field groups; id, kind, flags and activity are always present.
var fieldGroups = []string{"title", "revision", "stage", "owner", "links", "acceptance", "refs", "metrics"}

// Query is the bounded request. It is parsed from tool arguments, which carry
// no authority: identity arrives separately as a Caller.
type Query struct {
	// Root, when set, is the id of the node whose subtree is returned; Depth
	// then counts levels below it.
	Root         string
	Depth        int
	MaxNodes     int
	Fields       map[string]bool
	Since        string
	Continuation string
}

// ParseQuery reads the bounds from tool arguments. Unknown arguments —
// including any dispatch id, principal or caller a client sends — are
// returned as ignored and never consulted.
func ParseQuery(raw json.RawMessage) (Query, []string, error) {
	q := Query{Depth: MaxDepth, MaxNodes: DefaultMaxNodes, Fields: map[string]bool{}}
	for _, g := range fieldGroups {
		q.Fields[g] = true
	}
	args := map[string]json.RawMessage{}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &args); err != nil {
			return q, nil, fmt.Errorf("arguments must be an object: %w", err)
		}
	}
	var ignored []string
	for name, value := range args {
		var err error
		switch name {
		case "root":
			err = json.Unmarshal(value, &q.Root)
		case "depth":
			err = json.Unmarshal(value, &q.Depth)
		case "max_nodes":
			err = json.Unmarshal(value, &q.MaxNodes)
		case "since":
			err = json.Unmarshal(value, &q.Since)
		case "continuation":
			err = json.Unmarshal(value, &q.Continuation)
		case "fields":
			var names []string
			if err = json.Unmarshal(value, &names); err == nil {
				q.Fields, err = fieldSet(names)
			}
		default:
			ignored = append(ignored, name)
		}
		if err != nil {
			return q, nil, fmt.Errorf("%s: %w", name, err)
		}
	}
	q.Depth = min(max(q.Depth, 0), MaxDepth)
	q.MaxNodes = min(max(q.MaxNodes, 1), MaxMaxNodes)
	sort.Strings(ignored)
	// The echo of ignored names is bounded so junk arguments cannot grow the
	// reply past the cap.
	if len(ignored) > maxIgnoredEcho {
		ignored = append(ignored[:maxIgnoredEcho], fmt.Sprintf("… %d more", len(ignored)-maxIgnoredEcho))
	}
	for i, name := range ignored {
		ignored[i] = clip(name, 64)
	}
	return q, ignored, nil
}

func fieldSet(names []string) (map[string]bool, error) {
	set := map[string]bool{}
	for _, name := range names {
		known := false
		for _, g := range fieldGroups {
			known = known || g == name
		}
		if !known {
			return nil, fmt.Errorf("unknown field group %q (known: %s)", name, strings.Join(fieldGroups, ", "))
		}
		set[name] = true
	}
	return set, nil
}

// Reply is one page of the tree.
type Reply struct {
	// Caller and Scope echo the host-supplied identity the view was cut for.
	Caller string `json:"caller"`
	Scope  string `json:"scope"`
	// Cursor digests the included records' revisions; pass it as `since` to
	// learn cheaply that nothing recorded has changed. Observed activity is
	// not part of it.
	Cursor    string  `json:"cursor"`
	Unchanged bool    `json:"unchanged,omitempty"`
	Tree      []*Node `json:"tree"`

	NodesReturned int  `json:"nodes_returned"`
	NodesTotal    int  `json:"nodes_total"`
	Truncated     bool `json:"truncated"`
	// Continuation resumes after the last node on this page.
	Continuation string `json:"continuation,omitempty"`
	// ContinuationReset says a continuation was cut against records that
	// have since changed, so this page restarts from the first node.
	ContinuationReset bool `json:"continuation_reset,omitempty"`
	// RootNotFound echoes a requested root that is not in this caller's
	// view; the tree is then empty. A root outside the view and a root that
	// does not exist read the same.
	RootNotFound     string   `json:"root_not_found,omitempty"`
	IgnoredArguments []string `json:"ignored_arguments,omitempty"`
}

// Snapshot is everything one read composes: W1 records and the host's
// session evidence.
type Snapshot struct {
	Records  []Record
	Sessions []SessionEvidence
}

// Build returns one bounded page of the tree the caller may see.
func Build(snap Snapshot, caller Caller, q Query, ignored []string) Reply {
	return page(buildForest(snap.Records, snap.Sessions, caller), caller, q, ignored)
}

// page bounds an authorized forest to one reply.
func page(f forest, caller Caller, q Query, ignored []string) Reply {
	reply := Reply{Caller: caller.Principal, Scope: "full", Cursor: cursorOf(f.included), IgnoredArguments: ignored}
	if caller.Restricted {
		reply.Scope = "restricted"
	}
	roots, parent := f.roots, ""
	if q.Root != "" {
		node, above, ok := findNode(f.roots, q.Root, "")
		if !ok {
			reply.RootNotFound = clip(q.Root, 200)
			reply.Tree = []*Node{}
			return reply
		}
		roots, parent = []*Node{node}, above
	}
	flat := flatten(roots, q.Depth)
	if len(flat) > 0 {
		flat[0].parent = parent
	}
	reply.NodesTotal = len(flat)

	offset := 0
	if q.Continuation != "" {
		cursor, at, ok := decodeContinuation(q.Continuation)
		if ok && cursor == reply.Cursor && at <= len(flat) {
			offset = at
		} else {
			reply.ContinuationReset = true
		}
	} else if q.Since != "" && q.Since == reply.Cursor {
		reply.Unchanged = true
		reply.Tree = []*Node{}
		return reply
	}

	count := fitCount(flat[offset:], q)
	for {
		reply.Tree = assemble(flat[offset:offset+count], q.Fields)
		reply.NodesReturned = count
		reply.Truncated = offset+count < len(flat)
		reply.Continuation = ""
		if reply.Truncated {
			reply.Continuation = encodeContinuation(reply.Cursor, offset+count)
		}
		if count <= 1 || replySize(reply) <= ReplyCap {
			break
		}
		count--
	}
	if replySize(reply) > ReplyCap && len(reply.Tree) == 1 {
		// One node alone over the cap: its criteria list is the only
		// unbounded-by-count part, so drop the list and keep the total.
		reply.Tree[0].Remaining = nil
	}
	return reply
}

// flatEntry is a node in preorder with its tree parent's id. atLimit marks
// a node at the depth limit, whose children are hidden.
type flatEntry struct {
	node    *Node
	parent  string
	atLimit bool
}

// flatten lists nodes in preorder down to maxDepth, counting children the
// depth limit hides on their parent.
func flatten(roots []*Node, maxDepth int) []flatEntry {
	var out []flatEntry
	var walk func(n *Node, parent string, depth int)
	walk = func(n *Node, parent string, depth int) {
		out = append(out, flatEntry{node: n, parent: parent, atLimit: depth == maxDepth})
		if depth == maxDepth {
			return
		}
		for _, c := range n.Children {
			walk(c, n.ID, depth+1)
		}
	}
	for _, r := range roots {
		walk(r, "", 0)
	}
	return out
}

// findNode returns the node with the id and its parent's id.
func findNode(nodes []*Node, id, parent string) (*Node, string, bool) {
	for _, n := range nodes {
		if n.ID == id {
			return n, parent, true
		}
		if found, above, ok := findNode(n.Children, id, n.ID); ok {
			return found, above, true
		}
	}
	return nil, "", false
}

// fitCount estimates how many entries fit under max_nodes and the byte
// target; Build then verifies the real size and backs off.
func fitCount(entries []flatEntry, q Query) int {
	budget := replyTarget - 512
	count := 0
	for _, e := range entries {
		if count == q.MaxNodes {
			break
		}
		size := len(mustJSON(shallow(e, q.Fields))) + 16
		if count > 0 && size > budget {
			break
		}
		budget -= size
		count++
	}
	return count
}

// shallow copies a node without children and with only the requested field
// groups.
func shallow(e flatEntry, fields map[string]bool) *Node {
	c := *e.node
	c.Children = nil
	c.Parent = ""
	if e.atLimit {
		c.ChildrenHidden = len(e.node.Children)
	}
	if !fields["title"] {
		c.Title = ""
	}
	if !fields["revision"] {
		c.Revision = nil
	}
	if !fields["stage"] {
		c.Stage = nil
	}
	if !fields["owner"] {
		c.Owner = nil
	}
	if !fields["links"] {
		c.Links = nil
	}
	if !fields["acceptance"] {
		c.Remaining, c.RemainingTotal = nil, 0
	}
	if !fields["refs"] {
		c.Refs = nil
	}
	if !fields["metrics"] {
		c.Metrics = nil
	}
	return &c
}

// assemble nests a page's entries: an entry whose parent is on the page goes
// under it; any other becomes a page root naming its parent.
func assemble(entries []flatEntry, fields map[string]bool) []*Node {
	onPage := map[string]*Node{}
	roots := []*Node{}
	for _, e := range entries {
		c := shallow(e, fields)
		onPage[e.node.ID] = c
		if parent := onPage[e.parent]; parent != nil {
			parent.Children = append(parent.Children, c)
		} else {
			c.Parent = e.parent
			roots = append(roots, c)
		}
	}
	return roots
}

func replySize(r Reply) int { return len(mustJSON(r)) }

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

// cursorOf digests key, revision, status and update time of the included
// records. Records from a Docket without item revisions still change the
// digest through updated_at.
func cursorOf(records []Record) string {
	lines := make([]string, 0, len(records))
	for _, r := range records {
		lines = append(lines, recordLine(r))
	}
	sort.Strings(lines)
	sum := sha256.Sum256([]byte(strings.Join(lines, "\n")))
	return "r1:" + hex.EncodeToString(sum[:16])
}

// recordLine is one record's part of a cursor.
func recordLine(r Record) string {
	rev := "-"
	if r.Revision != nil {
		rev = strconv.Itoa(*r.Revision)
	}
	return strings.Join([]string{r.Key(), rev, r.Status, r.UpdatedAt}, "|")
}

func encodeContinuation(cursor string, offset int) string {
	return base64.RawURLEncoding.EncodeToString([]byte(cursor + "@" + strconv.Itoa(offset)))
}

func decodeContinuation(token string) (string, int, bool) {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return "", 0, false
	}
	cursor, at, found := strings.Cut(string(raw), "@")
	offset, err := strconv.Atoi(at)
	if !found || err != nil || offset < 0 {
		return "", 0, false
	}
	return cursor, offset, true
}

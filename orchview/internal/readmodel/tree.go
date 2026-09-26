package readmodel

import (
	"sort"
	"strings"
)

// Node is one tree entry. Record nodes (objective, task, attempt) carry the
// record's key; role and actor nodes carry a key derived from their attempt.
type Node struct {
	ID       string `json:"id"`
	Kind     Kind   `json:"kind"`
	Title    string `json:"title,omitempty"`
	Revision *int   `json:"revision,omitempty"`

	Stage *Stage      `json:"stage,omitempty"`
	Owner *Ownership  `json:"owner,omitempty"`
	Links *CrossLinks `json:"links,omitempty"`
	// Refs lead to the node's revisions, reviews and runs (refs.go).
	Refs *Refs `json:"refs,omitempty"`
	// Metrics is the process's MEASUREMENTS table on a record node; absent
	// when the record supplies none.
	Metrics *Metrics `json:"metrics,omitempty"`

	// Blocked is the recorded status "blocked"; Unowned is a task or attempt
	// that is not done and has neither an intended holder nor a claim holder.
	Blocked bool `json:"blocked,omitempty"`
	Unowned bool `json:"unowned,omitempty"`
	// OutcomeUnrecorded is a done task without an outcome: tag; its criteria
	// stay remaining because acceptance is the outcome tag, not the status.
	OutcomeUnrecorded bool `json:"outcome_unrecorded,omitempty"`
	// Partial marks an ancestor shown only as the path to what the caller may
	// see; its other children are withheld.
	Partial bool `json:"partial,omitempty"`
	// Orphan marks a task or attempt whose parent is not a loaded W1 record.
	Orphan bool `json:"orphan,omitempty"`

	// Remaining lists unaccepted DONE WHEN criteria (at most
	// maxCriteriaPerNode); RemainingTotal counts them all.
	Remaining      []Criterion `json:"remaining,omitempty"`
	RemainingTotal int         `json:"remaining_total,omitempty"`

	Activity Activity `json:"activity"`

	// Parent is set only on a page root whose parent is outside the page.
	Parent string `json:"parent,omitempty"`
	// ChildrenHidden counts children cut by the depth limit.
	ChildrenHidden int     `json:"children_hidden,omitempty"`
	Children       []*Node `json:"children,omitempty"`
}

// Stage is what the records say, kept apart from observation (W1 KB
// section 3): status plus the result/outcome/review/test/deferred facts.
type Stage struct {
	Status     string   `json:"status"`
	Result     string   `json:"result,omitempty"`
	Outcome    string   `json:"outcome,omitempty"`
	Review     string   `json:"review,omitempty"`
	Test       string   `json:"test,omitempty"`
	Deferred   []string `json:"deferred,omitempty"`
	Resolution string   `json:"resolution,omitempty"`
}

// Ownership keeps intent (assigned_to), the claim and the addressee apart.
type Ownership struct {
	AssignedTo  string `json:"assigned_to,omitempty"`
	ClaimHolder string `json:"claim_holder,omitempty"`
	DirectedTo  string `json:"directed_to,omitempty"`
}

// CrossLinks are the references that are not tree edges: retries
// (follow_up), dependencies (blocks / blocked_by).
type CrossLinks struct {
	RetryOf   []string `json:"retry_of,omitempty"`
	RetriedBy []string `json:"retried_by,omitempty"`
	Blocks    []string `json:"blocks,omitempty"`
	BlockedBy string   `json:"blocked_by,omitempty"`
}

// forest is the full authorized tree before depth, field and page bounds.
type forest struct {
	roots    []*Node
	included []Record
}

// index resolves stored references, which may be full ids or unique prefixes.
type index struct {
	byKey map[string]Record
	keys  []string
}

func newIndex(records []Record) *index {
	ix := &index{byKey: map[string]Record{}}
	for _, r := range records {
		if r.recordKind() == "" {
			continue
		}
		if _, dup := ix.byKey[r.Key()]; !dup {
			ix.keys = append(ix.keys, r.Key())
		}
		ix.byKey[r.Key()] = r
	}
	sort.Strings(ix.keys)
	return ix
}

func (ix *index) resolve(ref, ownProject string) (string, bool) {
	key := qualify(ref, ownProject)
	if key == "" {
		return "", false
	}
	if _, ok := ix.byKey[key]; ok {
		return key, true
	}
	found := ""
	for _, k := range ix.keys {
		if strings.HasPrefix(k, key) {
			if found != "" {
				return "", false
			}
			found = k
		}
	}
	return found, found != ""
}

// parentOf returns the record's tree parent: a task's objective or an
// attempt's task. Any other parent (a DCR, a mis-kinded record) is none.
func (ix *index) parentOf(r Record) (string, bool) {
	key, ok := ix.resolve(r.Parent, r.Project)
	if !ok {
		return "", false
	}
	want := map[Kind]Kind{KindTask: KindObjective, KindAttempt: KindTask}[r.recordKind()]
	if want == "" || ix.byKey[key].recordKind() != want {
		return "", false
	}
	return key, true
}

// authorize returns the keys to include and which of them are partial.
func (ix *index) authorize(caller Caller) (map[string]bool, map[string]bool) {
	included := map[string]bool{}
	partial := map[string]bool{}
	if !caller.Restricted {
		for _, k := range ix.keys {
			included[k] = true
		}
		return included, partial
	}
	visible := map[string]bool{}
	for _, k := range ix.keys {
		// A record is visible when it, or any ancestor, is addressed to the
		// caller. The walk is bounded by the record count against cycles.
		cur := ix.byKey[k]
		for step := 0; step <= len(ix.keys); step++ {
			if caller.addresses(cur) {
				visible[k] = true
				break
			}
			pk, ok := ix.parentOf(cur)
			if !ok {
				break
			}
			cur = ix.byKey[pk]
		}
	}
	for k := range visible {
		included[k] = true
		cur := ix.byKey[k]
		for step := 0; step <= len(ix.keys); step++ {
			pk, ok := ix.parentOf(cur)
			if !ok {
				break
			}
			if !visible[pk] {
				included[pk] = true
				partial[pk] = true
			}
			cur = ix.byKey[pk]
		}
	}
	return included, partial
}

// buildForest composes the authorized records and session evidence into the
// full tree, with remaining criteria and rolled-up activity.
func buildForest(records []Record, sessions []SessionEvidence, caller Caller) forest {
	ix := newIndex(records)
	included, partial := ix.authorize(caller)

	nodes := map[string]*Node{}
	var f forest
	for _, k := range ix.keys {
		if included[k] {
			nodes[k] = recordNode(ix.byKey[k], partial[k])
			f.included = append(f.included, ix.byKey[k])
		}
	}
	retryOf := map[string][]string{}
	for _, k := range ix.keys {
		n := nodes[k]
		if n == nil {
			continue
		}
		r := ix.byKey[k]
		links := &CrossLinks{}
		if r.BlockedBy != "" {
			links.BlockedBy = linkTarget(ix, r.BlockedBy, r.Project, included)
		}
		for _, l := range r.Links {
			target := linkTarget(ix, l.To, r.Project, included)
			if target == "" {
				continue
			}
			switch l.Relation {
			case "follow_up":
				if r.recordKind() == KindAttempt {
					links.RetriedBy = append(links.RetriedBy, target)
					retryOf[target] = append(retryOf[target], k)
				}
			case "blocks":
				links.Blocks = append(links.Blocks, target)
			}
		}
		n.Links = links
		if pk, ok := ix.parentOf(r); ok && nodes[pk] != nil {
			nodes[pk].Children = append(nodes[pk].Children, n)
			// A review is a role:reviewer attempt under the task (W1 KB
			// section 2); only attempts in this view are listed.
			if r.recordKind() == KindAttempt && r.hasTag("role:reviewer") {
				nodes[pk].Refs.Reviews = append(nodes[pk].Refs.Reviews, k)
			}
		} else {
			n.Orphan = r.recordKind() != KindObjective
			f.roots = append(f.roots, n)
		}
	}
	for k, sources := range retryOf {
		if n := nodes[k]; n != nil {
			n.Links.RetryOf = sources
		}
	}
	for _, k := range ix.keys {
		if n := nodes[k]; n != nil && n.Kind == KindAttempt {
			n.Children = append(n.Children, roleNodes(ix.byKey[k], sessions)...)
		}
	}
	for _, root := range f.roots {
		finish(root)
	}
	for _, n := range nodes {
		if l := n.Links; l != nil && len(l.RetryOf)+len(l.RetriedBy)+len(l.Blocks) == 0 && l.BlockedBy == "" {
			n.Links = nil
		}
		if n.Refs.empty() {
			n.Refs = nil
		} else {
			n.Refs.Reviews = firstN(n.Refs.Reviews, maxRefsPerKind)
		}
	}
	return f
}

// linkTarget qualifies a link target, dropping one the caller may not see so
// a restricted view does not leak ids outside it. Unloaded targets (not W1
// records) are kept as stored.
func linkTarget(ix *index, ref, ownProject string, included map[string]bool) string {
	if key, ok := ix.resolve(ref, ownProject); ok {
		if !included[key] {
			return ""
		}
		return key
	}
	return qualify(ref, ownProject)
}

func recordNode(r Record, partial bool) *Node {
	kind := r.recordKind()
	n := &Node{
		ID:       r.Key(),
		Kind:     kind,
		Title:    clip(r.Title, maxTitleRunes),
		Revision: r.Revision,
		Partial:  partial,
		Stage: &Stage{
			Status:     r.Status,
			Result:     r.tagValue("result"),
			Outcome:    r.tagValue("outcome"),
			Review:     r.tagValue("review"),
			Test:       r.tagValue("test"),
			Deferred:   r.tagValues("deferred"),
			Resolution: clip(r.Resolution, maxCriterionRunes),
		},
		Owner:   &Ownership{AssignedTo: r.AssignedTo, ClaimHolder: r.ClaimHolder, DirectedTo: r.DirectedTo},
		Refs:    recordRefs(r),
		Metrics: measurements(r.Description),
		Blocked: r.Status == "blocked",
	}
	if kind == KindTask || kind == KindAttempt {
		n.Unowned = !r.isDone() && strings.TrimSpace(r.AssignedTo) == "" && strings.TrimSpace(r.ClaimHolder) == ""
	}
	if kind == KindTask {
		n.OutcomeUnrecorded = r.isDone() && n.Stage.Outcome == ""
		if n.Stage.Outcome != "accepted" {
			for _, text := range doneWhen(r.Description) {
				n.Remaining = append(n.Remaining, Criterion{Task: r.Key(), Text: clip(text, maxCriterionRunes)})
			}
		}
	}
	return n
}

// roleNodes gives an attempt its role instance and, when it has an intended
// holder, that actor with its observed activity.
func roleNodes(r Record, sessions []SessionEvidence) []*Node {
	role := r.tagValue("role")
	roleNode := &Node{ID: r.Key() + "/role:" + role, Kind: KindRole, Title: role}
	if actor := strings.TrimSpace(r.AssignedTo); actor != "" {
		roleNode.Children = []*Node{{
			ID:       roleNode.ID + "/actor:" + actor,
			Kind:     KindActor,
			Title:    actor,
			Activity: actorActivity(actor, sessions),
		}}
	}
	return []*Node{roleNode}
}

// finish sorts children, rolls activity up, and gathers an objective's
// remaining criteria from the tasks in its (authorized) subtree.
func finish(n *Node) {
	sort.SliceStable(n.Children, func(i, j int) bool { return n.Children[i].ID < n.Children[j].ID })
	for _, c := range n.Children {
		finish(c)
	}
	if n.Kind != KindActor {
		n.Activity = rollUp(n.Children)
	}
	n.RemainingTotal = len(n.Remaining)
	if n.Kind == KindObjective {
		for _, c := range n.Children {
			if c.Kind == KindTask {
				n.Remaining = append(n.Remaining, c.Remaining...)
				n.RemainingTotal += c.RemainingTotal
			}
		}
	}
	if len(n.Remaining) > maxCriteriaPerNode {
		n.Remaining = n.Remaining[:maxCriteriaPerNode]
	}
}

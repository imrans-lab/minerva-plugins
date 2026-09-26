package main

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"github.com/ipeerbhai/plugins/orchview/internal/readmodel"
)

// The agent-facing verbs. They read the same record cache and read model as
// the panel; the caller comes from the arguments' `caller`, which only
// narrows the view (readmodel.verbArgs). The descriptions equal manifest.json's.
const (
	treeTool    = "minerva_orchview_tree"
	changesTool = "minerva_orchview_changes"
)

const treeDescription = "Read the orchestration work tree (objectives, their tasks, each dispatch attempt, the roles in it and the " +
	"agents holding them) from the same read model the Orchestration View panel shows. Each node keeps what the work " +
	"records say (stage, owner, links, remaining acceptance criteria) apart from what Minerva last observed of the " +
	"agent's session (activity, unknown when there is no evidence, never idle). Read-only.\n\n" +
	"Bounds: `root` (a node id from an earlier reply; omit it for every objective) picks one subtree. `depth` (0-4, " +
	"default 4) counts levels below it; a node at the limit reports `children_hidden`. `fields` picks optional groups " +
	"from title, revision, stage, owner, links, acceptance, refs, metrics (default all; id, kind, flags and activity " +
	"always come). `refs` are the commits a record's base:/head:/requires:/integrated: tags name, a task's " +
	"role:reviewer attempts, and the job runs its run:<session>/<job> tags name (read them with " +
	"minerva_agent_session_job_status and _job_log). `metrics` is the MEASUREMENTS table the process recorded in " +
	"the record's description, cell for cell; a record without one has no `metrics`, which means not measured. " +
	"`max_nodes` (1-2000, default 200) caps one page, and every reply also stays under 64 KiB.\n\n" +
	"Cursor: a reply that stops early says `truncated` and carries `continuation`; pass it back as `continuation` " +
	"for the next page. A continuation cut against records that have since changed restarts at the first node and " +
	"says `continuation_reset`. Every reply's `cursor` digests the recorded state of the whole view; pass it to " +
	"minerva_orchview_changes to learn what changed.\n\n" +
	"Identity: `identity` names whom the reply was evaluated for. Minerva passes no caller identity on plugin tool " +
	"calls yet, so a call from the owner's host gets the owner's full view and says so (source host_default_owner). " +
	"Through the agent-container gateway, the gateway stamps `caller` and `caller_role` with the session's " +
	"registered identity and role, and the reply holds only records addressed to them, their descendants, and their " +
	"ancestors as partial context (source caller_argument). A container cannot set `caller` itself, and a `caller` " +
	"only ever narrows a view."

const changesDescription = "Report what changed in the orchestration work tree since an earlier reply, from the same " +
	"read model as minerva_orchview_tree: each record node (objective, task, attempt) that was added, changed or " +
	"removed, with its current stage, owner, links, refs, metrics and activity. Only recorded changes count; observed activity " +
	"alone does not. Read-only.\n\n" +
	"Bounds: at most 200 changes and 64 KiB per reply; `changes_total` counts them all and `truncated` says the " +
	"list stops short, in which case read the tree again.\n\n" +
	"Cursor: pass the `cursor` of an earlier minerva_orchview_tree or minerva_orchview_changes reply. `unchanged` " +
	"says nothing recorded moved. `reset` says the cursor is not one this backend remembers for this caller (too " +
	"old, from before a restart, or cut for another view): read the tree again. Each reply's `cursor` is the next " +
	"one to pass.\n\n" +
	"Identity: as for minerva_orchview_tree. The host path is answered for the owner and says so; through the " +
	"agent-container gateway the reply is evaluated for the gateway-stamped `caller`, and a cursor is only compared " +
	"with the view of the caller it was cut for."

var treeSchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"root":         map[string]any{"type": "string", "description": "Id of the node whose subtree to return; omit for every objective."},
		"depth":        map[string]any{"type": "integer", "minimum": 0, "maximum": readmodel.MaxDepth, "description": "Levels below root to include."},
		"fields":       map[string]any{"type": "array", "items": map[string]any{"type": "string", "enum": []string{"title", "revision", "stage", "owner", "links", "acceptance", "refs", "metrics"}}, "description": "Optional field groups to include."},
		"max_nodes":    map[string]any{"type": "integer", "minimum": 1, "maximum": readmodel.MaxMaxNodes, "description": "Most nodes on one page."},
		"continuation": map[string]any{"type": "string", "description": "Continuation from a truncated reply."},
	},
}

var changesSchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"cursor": map[string]any{"type": "string", "description": "Cursor from an earlier tree or changes reply."},
	},
	"required": []string{"cursor"},
}

func verbSpecs() []any {
	return []any{
		map[string]any{"name": treeTool, "description": treeDescription, "inputSchema": treeSchema},
		map[string]any{"name": changesTool, "description": changesDescription, "inputSchema": changesSchema},
	}
}

// verb answers one agent verb from a fresh snapshot of the shared cache.
func (p *panelService) verb(parent context.Context, tool string, raw json.RawMessage) ([]byte, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	ctx, cancel := context.WithTimeout(parent, callBudget)
	defer cancel()
	got, err := p.read(ctx, time.Now().UTC())
	if err != nil {
		return nil, err
	}
	if tool == changesTool {
		reply, err := p.history.Changes(got.snap, raw)
		if err != nil {
			return nil, err
		}
		log.Printf("changes: caller=%s source=%s reset=%v unchanged=%v changes=%d",
			reply.Identity.Principal, reply.Identity.Source, reply.Reset, reply.Unchanged, reply.ChangesTotal)
		return json.Marshal(reply)
	}
	reply, err := p.history.Tree(got.snap, raw)
	if err != nil {
		return nil, err
	}
	log.Printf("verb tree: caller=%s source=%s nodes=%d/%d root_missing=%v",
		reply.Identity.Principal, reply.Identity.Source, reply.NodesReturned, reply.NodesTotal, reply.RootNotFound != "")
	return json.Marshal(reply)
}

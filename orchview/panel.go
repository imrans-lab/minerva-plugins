package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/ipeerbhai/plugins/orchview/internal/readmodel"
)

// panelTreeTool is the panel's channel. It is the owner's view: the panel
// runs in the owner's Minerva GUI and the host passes no caller identity on
// plugin tool calls, so the caller is fixed here and never read from the
// arguments. The agent-facing verb, with host-supplied identity, is separate.
const panelTreeTool = "minerva_orchview_panel_tree"

// ownerCaller is the principal the panel's view is cut for.
var ownerCaller = readmodel.Caller{Principal: "owner", Restricted: false}

// callBudget bounds one panel read, Docket and session reads included.
const callBudget = 20 * time.Second

func panelTreeSpec() map[string]any {
	return map[string]any{
		"name": panelTreeTool,
		"description": "The Orchestration View panel's read channel; the panel calls it on each refresh and it is not " +
			"meant to be called by hand. Returns one page of the W1 work tree (objectives, tasks, dispatch attempts, " +
			"role instances, actors) as the owner sees it. Pass `since` (the last cursor) and `evidence_since` (the last " +
			"evidence digest) to be told `unchanged` cheaply; pass `continuation` to read the next page.",
		"inputSchema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"since":          map[string]any{"type": "string", "description": "Cursor from the previous reply."},
				"evidence_since": map[string]any{"type": "string", "description": "Evidence digest from the previous reply."},
				"continuation":   map[string]any{"type": "string", "description": "Continuation from a truncated reply."},
				"max_nodes":      map[string]any{"type": "integer", "minimum": 1, "maximum": readmodel.MaxMaxNodes},
			},
		},
	}
}

// panelService answers the panel's reads from one record cache.
type panelService struct {
	mu    sync.Mutex
	host  *hostClient
	cache *readmodel.Cache
}

func newPanelService(host *hostClient) *panelService {
	return &panelService{host: host, cache: readmodel.NewCache(readmodel.DefaultFullReload)}
}

// panelReply is the read model's page plus the session evidence it was built
// with. Evidence digests the observed facts (not their time), so the panel
// learns that activity moved even when no record did.
type panelReply struct {
	readmodel.Reply
	Evidence      string   `json:"evidence"`
	ObservedAt    string   `json:"observed_at"`
	EvidenceError string   `json:"evidence_error,omitempty"`
	Projects      []string `json:"projects"`
}

func (p *panelService) tree(parent context.Context, raw json.RawMessage) ([]byte, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	ctx, cancel := context.WithTimeout(parent, callBudget)
	defer cancel()
	now := time.Now().UTC()

	args := map[string]json.RawMessage{}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fmt.Errorf("arguments must be an object: %w", err)
		}
	}
	var evidenceSince string
	if v, ok := args["evidence_since"]; ok {
		_ = json.Unmarshal(v, &evidenceSince)
		delete(args, "evidence_since")
	}
	rest, _ := json.Marshal(args)
	q, ignored, err := readmodel.ParseQuery(rest)
	if err != nil {
		return nil, err
	}

	projects, err := p.host.projects(ctx)
	if err != nil {
		return nil, err
	}
	stats, err := p.cache.Refresh(ctx, p.host, projects, now)
	if err != nil {
		return nil, err
	}
	out := panelReply{ObservedAt: now.Format(time.RFC3339), Projects: projects}
	sessions, err := p.host.sessions(ctx, now)
	if err != nil {
		// No session evidence at all: every actor reads unknown.
		out.EvidenceError = clipText(err.Error(), 300)
		sessions = nil
	}
	out.Evidence = evidenceDigest(sessions, out.EvidenceError != "")
	if q.Since != "" && evidenceSince != out.Evidence {
		q.Since = ""
	}
	out.Reply = readmodel.Build(readmodel.Snapshot{Records: p.cache.Records(), Sessions: sessions}, ownerCaller, q, ignored)

	if stats.IncrementalError != "" {
		log.Printf("tree: change query failed, reloaded everything: %s", stats.IncrementalError)
	}
	log.Printf("tree: full_reload=%v queries=%d gets=%d removed=%d records=%d sessions=%d unchanged=%v nodes=%d/%d continuation=%v",
		stats.Full, stats.Queries, stats.Gets, stats.Removed, stats.Records, len(sessions),
		out.Unchanged, out.NodesReturned, out.NodesTotal, q.Continuation != "")
	return json.Marshal(out)
}

func evidenceDigest(sessions []readmodel.SessionEvidence, failed bool) string {
	if failed {
		return "e1:unavailable"
	}
	lines := make([]string, 0, len(sessions))
	for _, s := range sessions {
		lines = append(lines, strings.Join([]string{s.Principal, s.Identity, s.Role, s.Liveness}, "|"))
	}
	sort.Strings(lines)
	sum := sha256.Sum256([]byte(strings.Join(lines, "\n")))
	return "e1:" + hex.EncodeToString(sum[:12])
}

func clipText(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

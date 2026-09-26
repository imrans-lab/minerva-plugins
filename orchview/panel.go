package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/ipeerbhai/plugins/orchview/internal/readmodel"
)

// panelTreeTool is the panel's channel. It is the owner's view: the panel
// runs in the owner's Minerva GUI, so the caller is fixed to readmodel.Owner
// and never read from the arguments. The agent-facing verbs are in verbs.go.
const panelTreeTool = "minerva_orchview_panel_tree"

// callBudget bounds one panel read, Docket and session reads included.
const callBudget = 20 * time.Second

func panelTreeSpec() map[string]any {
	return map[string]any{
		"name": panelTreeTool,
		"description": "The Orchestration View panel's read channel; the panel calls it on each refresh and it is not " +
			"meant to be called by hand. Returns one page of the W1 work tree (objectives, tasks, dispatch attempts, " +
			"role instances, actors) as the owner sees it. Pass `since` (the last cursor) and `evidence_since` (the last " +
			"evidence digest) to be told `unchanged` cheaply; pass `continuation` to read the next page. Each reply carries " +
			"`overhead`: the host calls, bytes and backend time that answering it cost.",
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

// panelService answers the panel's reads and the agent verbs from one
// record cache; mu serialises every read, so the cache and the verbs'
// cursor history are touched by one call at a time.
type panelService struct {
	mu      sync.Mutex
	host    *hostClient
	cache   *readmodel.Cache
	history *readmodel.History
}

func newPanelService(host *hostClient) *panelService {
	return &panelService{host: host, cache: readmodel.NewCache(readmodel.DefaultFullReload),
		history: readmodel.NewHistory()}
}

// snapshotRead is one refreshed view of the records and session evidence.
type snapshotRead struct {
	snap     readmodel.Snapshot
	stats    readmodel.RefreshStats
	projects []string
	// evidenceError is why session evidence could not be read; every actor
	// then reads unknown.
	evidenceError string
}

// read refreshes the record cache and reads session evidence. Callers hold mu.
func (p *panelService) read(ctx context.Context, now time.Time) (snapshotRead, error) {
	var out snapshotRead
	projects, err := p.host.projects(ctx)
	if err != nil {
		return out, err
	}
	out.projects = projects
	out.stats, err = p.cache.Refresh(ctx, p.host, projects, now)
	if err != nil {
		return out, err
	}
	if out.stats.IncrementalError != "" {
		log.Printf("change query failed, reloaded everything: %s", out.stats.IncrementalError)
	}
	sessions, err := p.host.sessions(ctx, now)
	if err != nil {
		out.evidenceError = clipText(err.Error(), 300)
		sessions = nil
	}
	out.snap = readmodel.Snapshot{Records: p.cache.Records(), Sessions: sessions}
	return out, nil
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
	// Overhead is what answering this call cost the viewer's side.
	Overhead overhead `json:"overhead"`
}

// overhead is one panel call's cost: the host capability calls it made, the
// cache's refresh kind, the backend's wall time (host waits included), and
// the size of this reply as JSON. It measures the viewer only.
type overhead struct {
	Host       hostMeter `json:"host"`
	FullReload bool      `json:"full_reload"`
	WorkerMS   float64   `json:"worker_ms"`
	ReplyBytes int       `json:"reply_bytes"`
}

func (p *panelService) tree(parent context.Context, raw json.RawMessage) ([]byte, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	ctx, cancel := context.WithTimeout(parent, callBudget)
	defer cancel()
	started := time.Now()
	now := started.UTC()
	p.host.meter = hostMeter{}

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

	got, err := p.read(ctx, now)
	if err != nil {
		return nil, err
	}
	stats, sessions := got.stats, got.snap.Sessions
	out := panelReply{ObservedAt: now.Format(time.RFC3339), Projects: got.projects, EvidenceError: got.evidenceError}
	out.Evidence = evidenceDigest(sessions, out.EvidenceError != "")
	if q.Since != "" && evidenceSince != out.Evidence {
		q.Since = ""
	}
	out.Reply = readmodel.Build(got.snap, readmodel.Owner, q, ignored)
	out.Overhead = overhead{Host: p.host.meter, FullReload: stats.Full}
	out.Overhead.Host.WaitMS = math.Round(out.Overhead.Host.WaitMS*1000) / 1000
	body, err := json.Marshal(out)
	if err != nil {
		return nil, err
	}
	// The second encoding carries the first one's size and the time spent
	// until then; the sizes differ only by the digits of these two numbers.
	out.Overhead.ReplyBytes = len(body)
	out.Overhead.WorkerMS = float64(time.Since(started).Microseconds()) / 1000
	body, err = json.Marshal(out)

	log.Printf("tree: full_reload=%v queries=%d gets=%d removed=%d records=%d sessions=%d unchanged=%v nodes=%d/%d continuation=%v host_calls=%d host_bytes_read=%d host_wait_ms=%.1f worker_ms=%.1f reply_bytes=%d",
		stats.Full, stats.Queries, stats.Gets, stats.Removed, stats.Records, len(sessions),
		out.Unchanged, out.NodesReturned, out.NodesTotal, q.Continuation != "",
		out.Overhead.Host.Calls, out.Overhead.Host.BytesRead, out.Overhead.Host.WaitMS, out.Overhead.WorkerMS, len(body))
	return body, err
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

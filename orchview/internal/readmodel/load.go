package readmodel

import (
	"context"
	"encoding/json"
	"fmt"
)

// Fetcher calls one Docket MCP tool and returns its decoded result JSON (the
// text of the tool result, not the MCP envelope). The backend supplies one
// over whatever route reaches Docket; the loader does not know the transport.
type Fetcher interface {
	Call(ctx context.Context, tool string, args map[string]any) (json.RawMessage, error)
}

// queryLimit is the most records of one kind the loader reads per project. A
// project with more is refused rather than silently cut short.
const queryLimit = 1000

var recordTags = []string{"wr:objective", "wr:task", "wr:attempt"}

// Load reads every W1 record (objective, task, attempt) from each project:
// docket_query by wr: tag for the ids, then docket_get per id for the fields,
// links, revision and claim holder. Reading never claims (docket_get reports
// the holder only).
func Load(ctx context.Context, f Fetcher, projects []string) ([]Record, error) {
	seen := map[string]bool{}
	var out []Record
	for _, project := range projects {
		for _, tag := range recordTags {
			ids, err := queryIDs(ctx, f, project, tag)
			if err != nil {
				return nil, err
			}
			for _, id := range ids {
				rec, err := getRecord(ctx, f, project, id)
				if err != nil {
					return nil, err
				}
				if !seen[rec.Key()] {
					seen[rec.Key()] = true
					out = append(out, rec)
				}
			}
		}
	}
	return out, nil
}

func queryIDs(ctx context.Context, f Fetcher, project, tag string) ([]string, error) {
	args := map[string]any{
		"project": project,
		"filter": map[string]any{"conditions": []any{
			map[string]any{"field": "tags", "op": "eq", "value": tag},
		}},
		"detail": "lean",
		"limit":  queryLimit,
	}
	raw, err := f.Call(ctx, "docket_query", args)
	if err != nil {
		return nil, fmt.Errorf("docket_query %s %s: %w", project, tag, err)
	}
	var reply struct {
		Error string `json:"error"`
		Items []struct {
			ID string `json:"id"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &reply); err != nil {
		return nil, fmt.Errorf("docket_query %s %s: %w", project, tag, err)
	}
	if reply.Error != "" {
		return nil, fmt.Errorf("docket_query %s %s: %s", project, tag, reply.Error)
	}
	if len(reply.Items) >= queryLimit {
		return nil, fmt.Errorf("docket_query %s %s: %d or more records; the read model reads at most %d per kind", project, tag, queryLimit, queryLimit-1)
	}
	ids := make([]string, 0, len(reply.Items))
	for _, item := range reply.Items {
		ids = append(ids, item.ID)
	}
	return ids, nil
}

func getRecord(ctx context.Context, f Fetcher, project, id string) (Record, error) {
	args := map[string]any{"id": id, "project": project, "include": []any{"links"}}
	raw, err := f.Call(ctx, "docket_get", args)
	if err != nil {
		return Record{}, fmt.Errorf("docket_get %s:%s: %w", project, id, err)
	}
	var failure struct {
		Error string `json:"error"`
	}
	if json.Unmarshal(raw, &failure) == nil && failure.Error != "" {
		return Record{}, fmt.Errorf("docket_get %s:%s: %s", project, id, failure.Error)
	}
	var rec Record
	if err := json.Unmarshal(raw, &rec); err != nil {
		return Record{}, fmt.Errorf("docket_get %s:%s: %w", project, id, err)
	}
	rec.Project = project
	return rec, nil
}

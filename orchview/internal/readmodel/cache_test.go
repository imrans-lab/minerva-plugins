package readmodel

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

// fakeHost is a Docket holding wr:task records, answering the loader's lean
// id queries (with or without an updated_at "after" condition) and docket_get,
// and logging every call.
type fakeHost struct {
	tasks map[string]Record // id -> record
	calls []string          // "docket_get <id>" or "docket_query <after value or "">"
}

func (h *fakeHost) Call(_ context.Context, tool string, args map[string]any) (json.RawMessage, error) {
	switch tool {
	case "docket_get":
		id := args["id"].(string)
		h.calls = append(h.calls, "docket_get "+id)
		return mustJSON(h.tasks[id]), nil
	case "docket_query":
		conditions := args["filter"].(map[string]any)["conditions"].([]any)
		tag := conditions[0].(map[string]any)["value"].(string)
		after := ""
		if len(conditions) > 1 {
			after = conditions[1].(map[string]any)["value"].(string)
		}
		h.calls = append(h.calls, "docket_query "+after)
		items := []map[string]string{}
		for id, r := range h.tasks {
			if tag == "wr:task" && (after == "" || r.UpdatedAt > after) {
				items = append(items, map[string]string{"id": id})
			}
		}
		return mustJSON(map[string]any{"items": items}), nil
	}
	return nil, fmt.Errorf("unexpected tool %s", tool)
}

func (h *fakeHost) gets() []string {
	var out []string
	for _, c := range h.calls {
		if id, ok := strings.CutPrefix(c, "docket_get "); ok {
			out = append(out, id)
		}
	}
	return out
}

// TestCacheRefreshChangedRereadsOnlyTheUpdatedRecord: between two incremental
// refreshes the id listing is the same, one record's updated_at moved past the
// held watermark and one did not. Only the moved one is read again, and the
// cache then holds its new fields. Oracle: the fake host's call log.
func TestCacheRefreshChangedRereadsOnlyTheUpdatedRecord(t *testing.T) {
	host := &fakeHost{tasks: map[string]Record{
		"old": {ID: "old", Title: "untouched", Tags: []string{"wr:task"}, UpdatedAt: "2026-09-26T09:00:00"},
		"new": {ID: "new", Title: "before", Tags: []string{"wr:task"}, UpdatedAt: "2026-09-26T10:00:00"},
	}}
	cache := NewCache(DefaultFullReload)
	start := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	if stats, err := cache.Refresh(context.Background(), host, []string{"p"}, start); err != nil || !stats.Full {
		t.Fatalf("first refresh: full=%v err=%v", stats.Full, err)
	}

	changed := host.tasks["new"]
	changed.Title, changed.UpdatedAt = "after", "2026-09-26T10:30:00"
	host.tasks["new"] = changed
	host.calls = nil
	stats, err := cache.Refresh(context.Background(), host, []string{"p"}, start.Add(time.Minute))
	if err != nil || stats.Full {
		t.Fatalf("second refresh: full=%v err=%v", stats.Full, err)
	}
	if gets := host.gets(); len(gets) != 1 || gets[0] != "new" {
		t.Errorf("incremental refresh read %v; want only the updated record [new] (calls %v)", gets, host.calls)
	}
	titles := map[string]string{}
	for _, r := range cache.Records() {
		titles[r.ID] = r.Title
	}
	if titles["new"] != "after" || titles["old"] != "untouched" || len(titles) != 2 {
		t.Errorf("cache holds %v; want the updated title for new and the held one for old", titles)
	}
}

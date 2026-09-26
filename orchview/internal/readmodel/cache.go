package readmodel

import (
	"context"
	"sort"
	"time"
)

// Cache keeps the W1 records between reads so a refresh fetches only what
// changed. Per project and kind a refresh issues one lean id query (which
// reveals added and removed records) and one lean query for records updated
// at or after the newest update time already held; only new or updated ids
// are then read with docket_get. A full reload runs on the first refresh, when
// the project set changes, every fullReload, and whenever a change query
// fails. The periodic reload catches edits that Docket records without
// moving updated_at (links, for one).
//
// A Cache is not safe for concurrent use; the backend serialises refreshes.
type Cache struct {
	records    map[string]Record
	projects   []string
	lastFull   time.Time
	fullReload time.Duration
}

// DefaultFullReload is how often a Cache reloads every record regardless of
// what the change queries report.
const DefaultFullReload = 5 * time.Minute

// NewCache returns an empty cache that reloads everything every fullReload.
func NewCache(fullReload time.Duration) *Cache {
	return &Cache{records: map[string]Record{}, fullReload: fullReload}
}

// RefreshStats says what one refresh read, for the worker log.
type RefreshStats struct {
	Full    bool
	Queries int
	Gets    int
	Removed int
	Records int
	// IncrementalError is why a change query failed; the refresh then fell
	// back to a full reload.
	IncrementalError string
}

// Refresh brings the cache up to date with the projects' W1 records.
func (c *Cache) Refresh(ctx context.Context, f Fetcher, projects []string, now time.Time) (RefreshStats, error) {
	sorted := append([]string(nil), projects...)
	sort.Strings(sorted)
	full := c.lastFull.IsZero() || now.Sub(c.lastFull) >= c.fullReload || !equalStrings(sorted, c.projects)
	if !full {
		stats, err := c.refreshChanged(ctx, f, sorted)
		if err == nil {
			return stats, nil
		}
		if ctx.Err() != nil {
			return stats, err
		}
		reloaded, reloadErr := c.reload(ctx, f, sorted, now)
		reloaded.IncrementalError = err.Error()
		return reloaded, reloadErr
	}
	return c.reload(ctx, f, sorted, now)
}

func (c *Cache) reload(ctx context.Context, f Fetcher, sorted []string, now time.Time) (RefreshStats, error) {
	stats := RefreshStats{Full: true}
	records, err := Load(ctx, f, sorted)
	if err != nil {
		return stats, err
	}
	stats.Queries = len(sorted) * len(recordTags)
	stats.Gets = len(records)
	c.records = map[string]Record{}
	for _, r := range records {
		c.records[r.Key()] = r
	}
	c.projects, c.lastFull = sorted, now
	stats.Records = len(c.records)
	return stats, nil
}

// refreshChanged reads only added and updated records.
func (c *Cache) refreshChanged(ctx context.Context, f Fetcher, sorted []string) (RefreshStats, error) {
	var stats RefreshStats
	next := map[string]Record{}
	for _, project := range sorted {
		watermark := c.newestUpdate(project)
		for _, tag := range recordTags {
			ids, err := queryIDs(ctx, f, project, tag)
			if err != nil {
				return stats, err
			}
			stats.Queries++
			changed := map[string]bool{}
			if watermark != "" {
				// "after" is strict and updated_at has one-second resolution,
				// so the query starts a second early; records updated in the
				// watermark's own second are read again rather than missed.
				since := watermarkMinusSecond(watermark)
				changedIDs, err := queryIDsWhere(ctx, f, project, tag,
					map[string]any{"conj": "and", "field": "updated_at", "op": "after", "value": since})
				if err != nil {
					return stats, err
				}
				stats.Queries++
				for _, id := range changedIDs {
					changed[id] = true
				}
			}
			for _, id := range ids {
				key := project + ":" + id
				if held, ok := c.records[key]; ok && !changed[id] && watermark != "" {
					next[key] = held
					continue
				}
				rec, err := getRecord(ctx, f, project, id)
				if err != nil {
					return stats, err
				}
				stats.Gets++
				next[rec.Key()] = rec
			}
		}
	}
	for key := range c.records {
		if _, kept := next[key]; !kept {
			stats.Removed++
		}
	}
	c.records = next
	stats.Records = len(next)
	return stats, nil
}

// Records returns the held records in key order.
func (c *Cache) Records() []Record {
	keys := make([]string, 0, len(c.records))
	for k := range c.records {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]Record, 0, len(keys))
	for _, k := range keys {
		out = append(out, c.records[k])
	}
	return out
}

// newestUpdate is the latest updated_at held for a project, "" when none.
// Docket writes updated_at in one fixed-width format, so strings compare in
// time order.
func (c *Cache) newestUpdate(project string) string {
	newest := ""
	for _, r := range c.records {
		if r.Project == project && r.UpdatedAt > newest {
			newest = r.UpdatedAt
		}
	}
	return newest
}

func watermarkMinusSecond(updatedAt string) string {
	const layout = "2006-01-02T15:04:05"
	t, err := time.Parse(layout, updatedAt)
	if err != nil {
		return updatedAt
	}
	return t.Add(-time.Second).Format(layout)
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

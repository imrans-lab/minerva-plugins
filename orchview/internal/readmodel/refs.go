package readmodel

import (
	"regexp"
	"strings"
)

// Refs are the places a record node leads to beyond its own record: the
// commits its revision tags name (W1 KB section 2), the reviewer attempts
// under a task, and the job runs recorded on it. The node's id is the record
// reference itself.
type Refs struct {
	Revisions []RevisionRef `json:"revisions,omitempty"`
	// Reviews are the node ids of the task's role:reviewer attempts in this
	// view; the findings themselves are comments on the task record.
	Reviews []string `json:"reviews,omitempty"`
	Runs    []RunRef `json:"runs,omitempty"`
}

// RevisionRef is one base:/head:/requires:/integrated: tag. Branch is empty
// for base and head. A tag that does not parse keeps its text in Tag only.
type RevisionRef struct {
	Kind   string `json:"kind"`
	Repo   string `json:"repo,omitempty"`
	Branch string `json:"branch,omitempty"`
	SHA    string `json:"sha,omitempty"`
	Tag    string `json:"tag"`
}

// RunRef is one `run:<session>/<job>` tag: a planned job of an
// agent-container session (Minerva scripts/agent-container/jobs.py), whose
// status, log and artifacts the host serves by session name and job id. A
// tag that does not parse keeps its text in Tag with Session and Job empty.
type RunRef struct {
	Session string `json:"session,omitempty"`
	Job     string `json:"job,omitempty"`
	Tag     string `json:"tag"`
}

var (
	// jobID and sessionName are jobs.py's JOB_ID and agent.py's NAME.
	jobID       = regexp.MustCompile(`^j[0-9]{8}t[0-9]{6}-[0-9a-f]{6}$`)
	sessionName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)
	hexSHA      = regexp.MustCompile(`^[0-9a-f]{7,64}$`)
)

const (
	maxRefsPerKind = 20
	maxTagRunes    = 200
)

var revisionKinds = []string{"base", "head", "requires", "integrated"}

// recordRefs reads a record's revision and run tags.
func recordRefs(r Record) *Refs {
	refs := &Refs{}
	for _, kind := range revisionKinds {
		for _, value := range r.tagValues(kind) {
			refs.Revisions = append(refs.Revisions, parseRevision(kind, value))
		}
	}
	for _, value := range r.tagValues("run") {
		refs.Runs = append(refs.Runs, parseRun(value))
	}
	refs.Revisions = firstN(refs.Revisions, maxRefsPerKind)
	refs.Runs = firstN(refs.Runs, maxRefsPerKind)
	return refs
}

// parseRevision splits `<repo>@<sha>` (base, head) or
// `<repo>@<branch>@<sha>` (requires, integrated): the repo holds no `@`, the
// branch is everything between the first and last `@`, and the sha is hex
// (older records carry 12-hex prefixes).
func parseRevision(kind, value string) RevisionRef {
	ref := RevisionRef{Kind: kind, Tag: clip(kind+":"+value, maxTagRunes)}
	first, last := strings.Index(value, "@"), strings.LastIndex(value, "@")
	wantBranch := kind == "requires" || kind == "integrated"
	if first <= 0 || (first != last) != wantBranch || !hexSHA.MatchString(value[last+1:]) {
		return ref
	}
	ref.Repo, ref.SHA = value[:first], value[last+1:]
	if wantBranch {
		ref.Branch = value[first+1 : last]
	}
	ref.Repo, ref.Branch, ref.SHA = clip(ref.Repo, maxTagRunes), clip(ref.Branch, maxTagRunes), clip(ref.SHA, 64)
	return ref
}

func parseRun(value string) RunRef {
	ref := RunRef{Tag: clip("run:"+value, maxTagRunes)}
	session, job, found := strings.Cut(value, "/")
	if found && sessionName.MatchString(session) && jobID.MatchString(job) {
		ref.Session, ref.Job = session, job
	}
	return ref
}

func (r *Refs) empty() bool {
	return r == nil || len(r.Revisions)+len(r.Reviews)+len(r.Runs) == 0
}

// Metrics is the MEASUREMENTS table a process recorded in a record's
// description, as the process wrote it: the header row's cells, then each
// row's cells. Nothing is summed or inferred; a cell reading unknown stays
// unknown, and the panel marks it.
type Metrics struct {
	Columns   []string   `json:"columns"`
	Rows      [][]string `json:"rows"`
	RowsTotal int        `json:"rows_total"`
}

const (
	maxMetricRows    = 30
	maxMetricColumns = 8
	maxCellRunes     = 200
)

// measurements reads the first Markdown table in the description's
// MEASUREMENTS section (an all-caps heading line, as DONE WHEN is). Its first
// row is the header; separator rows (|---|) are skipped. nil when the record
// supplies none.
func measurements(description string) *Metrics {
	var table [][]string
	inSection := false
	for _, raw := range strings.Split(description, "\n") {
		line := strings.TrimSpace(raw)
		if isHeading(line) {
			if len(table) > 0 {
				break
			}
			inSection = line == "MEASUREMENTS"
			continue
		}
		if !inSection {
			continue
		}
		if !strings.HasPrefix(line, "|") {
			if len(table) > 0 {
				break
			}
			continue
		}
		cells := splitRow(line)
		if !separatorRow(cells) {
			table = append(table, cells)
		}
	}
	if len(table) == 0 {
		return nil
	}
	m := &Metrics{Columns: firstN(table[0], maxMetricColumns), RowsTotal: len(table) - 1}
	for _, row := range firstN(table[1:], maxMetricRows) {
		m.Rows = append(m.Rows, firstN(row, maxMetricColumns))
	}
	if m.Rows == nil {
		m.Rows = [][]string{}
	}
	return m
}

func splitRow(line string) []string {
	line = strings.TrimSuffix(strings.TrimPrefix(line, "|"), "|")
	cells := strings.Split(line, "|")
	for i, c := range cells {
		cells[i] = clip(strings.TrimSpace(c), maxCellRunes)
	}
	return cells
}

func separatorRow(cells []string) bool {
	for _, c := range cells {
		if strings.Trim(c, "-: ") != "" {
			return false
		}
	}
	return true
}

func firstN[T any](items []T, n int) []T {
	if len(items) > n {
		return items[:n]
	}
	return items
}

package main

import (
	"encoding/csv"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Recorder appends every reading to a CSV while active. One recording at a
// time; the file lives in the plugin's data directory unless the caller
// names a path.
type Recorder struct {
	mu    sync.Mutex
	file  *os.File
	w     *csv.Writer
	path  string
	rows  int
	start time.Time
}

func (r *Recorder) Start(path string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.file != nil {
		return fmt.Errorf("already recording to %s", r.path)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	r.file, r.w, r.path, r.rows, r.start = f, csv.NewWriter(f), path, 0, time.Now()
	return r.w.Write([]string{"timestamp", "value", "unit", "function", "flags", "raw"})
}

func (r *Recorder) Add(rd Reading) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.file == nil {
		return
	}
	value := "OL"
	if !rd.Overload {
		value = strconv.FormatFloat(rd.Value, 'f', -1, 64)
	}
	r.w.Write([]string{
		rd.Timestamp.Format(time.RFC3339Nano), value, rd.Prefix + rd.Unit,
		rd.Function, strings.Join(rd.Flags, "|"), rd.Raw,
	})
	r.rows++
	if r.rows%50 == 0 {
		r.w.Flush()
	}
}

// Stop closes the file and reports what was written.
func (r *Recorder) Stop() (map[string]interface{}, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.file == nil {
		return nil, fmt.Errorf("not recording")
	}
	r.w.Flush()
	err := r.file.Close()
	out := map[string]interface{}{
		"path": r.path, "rows": r.rows, "seconds": time.Since(r.start).Seconds(),
	}
	r.file, r.w = nil, nil
	return out, err
}

// LastPath is the most recent recording, running or finished.
func (r *Recorder) LastPath() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.w != nil {
		r.w.Flush()
	}
	return r.path
}

func (r *Recorder) Status() map[string]interface{} {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.file == nil {
		return map[string]interface{}{"recording": false}
	}
	return map[string]interface{}{
		"recording": true, "path": r.path, "rows": r.rows,
		"seconds": time.Since(r.start).Seconds(),
	}
}

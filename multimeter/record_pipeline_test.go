package main

import (
	"encoding/csv"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRecordingForSheets(t *testing.T) {
	s, h := startPlugin(t)
	path := filepath.Join(t.TempDir(), "recording.csv")
	if output := os.Getenv("MINERVA_RECORDING_FIXTURE"); output != "" {
		path = output
	}
	h.write(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"record_start","arguments":{"path":%q}}}`, path)
	if got := h.expectTool(1); got["success"] != true {
		t.Fatalf("record_start: %v", got)
	}
	for index := 0; index < 3; index++ {
		s.recorder.Add(Reading{Timestamp: time.Unix(1700000000+int64(index), 0).UTC(), Value: float64(index) + 1.25, Unit: "Ω", Function: "Resistance", Raw: "fixture"})
	}
	h.write(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"record_stop","arguments":{}}}`)
	stopped := h.expectTool(2)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := csv.NewReader(strings.NewReader(string(data))).ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	// record_stop.rows counts measurements; Sheets rows_imported includes this CSV header.
	if stopped["success"] != true || stopped["rows"] != float64(len(rows)-1) || len(rows) != 4 || rows[3][2] != "Ω" {
		t.Fatalf("recorded rows/content: %v; %v", stopped, rows)
	}
	if os.Getenv("MINERVA_RECORDING_FIXTURE") != "" {
		receipt, err := json.Marshal(stopped)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path+".json", receipt, 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

// build_from_sheet maps sheet columns → tag rows (empty values omitted), renders
// a preview, and writes the preview PDF + the .mtags doc — in that capability
// order. The written .mtags carries the mapped rows + the preview path.
func TestBuildFromSheetMapsColumns(t *testing.T) {
	host := &seqHost{replies: []json.RawMessage{
		json.RawMessage(`{"success":true,"result":{"bytes_b64":"JVBERg==","byte_size":5,"page_count":1,"content_type":"application/pdf"}}`),
		json.RawMessage(`{"success":true,"result":{"path":"/tmp/x.mtags.preview.pdf","bytes_written":5}}`),
		json.RawMessage(`{"success":true,"result":{"path":"/tmp/x.mtags","bytes_written":100}}`),
	}}
	rows := `[{"Name":"Ada Lovelace","Cabin":"1","Teacher":"Shaw","Notes":""},{"Name":"Bo Diddley","Cabin":"2","Teacher":"Lin","Notes":"VIP"}]`
	args := mustArgs(t, map[string]interface{}{
		"rows_json": rows,
		"mapping": map[string]interface{}{
			"title":    "Name",
			"subtitle": "Cabin",
			"lines": []map[string]interface{}{
				{"label": "Teacher", "column": "Teacher"},
				{"label": "", "column": "Notes"},
			},
		},
		"layout":   "detailed",
		"out_path": "/tmp/x.mtags",
		"title":    "Camp",
	})

	res := toolNametagBuildFromSheet(host, args)
	if res["success"] != true {
		t.Fatalf("expected success, got %+v", res)
	}
	if res["row_count"] != 2 {
		t.Fatalf("row_count: want 2, got %v", res["row_count"])
	}

	wantOrder := []string{"host.pdf.generate", "host.files.write", "host.files.write"}
	if len(host.calls) != len(wantOrder) {
		t.Fatalf("want %d calls, got %d: %+v", len(wantOrder), len(host.calls), host.calls)
	}
	for i, w := range wantOrder {
		if host.calls[i].capability != w {
			t.Fatalf("call %d: want %q got %q", i, w, host.calls[i].capability)
		}
	}

	// The .mtags write content (base64) decodes to a doc with the mapped rows.
	mtagsB64, _ := host.calls[2].args["content"].(string)
	docBytes, err := base64.StdEncoding.DecodeString(mtagsB64)
	if err != nil {
		t.Fatalf("decode .mtags content: %v", err)
	}
	var doc struct {
		PreviewPDFPath string `json:"preview_pdf_path"`
		Generate       struct {
			Layout string `json:"layout"`
			Rows   []struct {
				Title    string `json:"title"`
				Subtitle string `json:"subtitle"`
				Lines    []struct {
					Label string `json:"label"`
					Value string `json:"value"`
				} `json:"lines"`
			} `json:"rows"`
		} `json:"generate"`
	}
	if err := json.Unmarshal(docBytes, &doc); err != nil {
		t.Fatalf(".mtags not valid JSON: %v\n%s", err, docBytes)
	}
	if len(doc.Generate.Rows) != 2 {
		t.Fatalf("doc rows: want 2, got %d", len(doc.Generate.Rows))
	}
	r0 := doc.Generate.Rows[0]
	if r0.Title != "Ada Lovelace" || r0.Subtitle != "1" {
		t.Fatalf("row0 title/subtitle wrong: %+v", r0)
	}
	// Ada: Teacher=Shaw present; Notes empty → omitted (exactly 1 line).
	if len(r0.Lines) != 1 || r0.Lines[0].Label != "Teacher" || r0.Lines[0].Value != "Shaw" {
		t.Fatalf("row0 lines wrong: %+v", r0.Lines)
	}
	// Bo: Teacher=Lin + Notes=VIP (value-only) → 2 lines.
	if len(doc.Generate.Rows[1].Lines) != 2 {
		t.Fatalf("row1 lines: want 2, got %+v", doc.Generate.Rows[1].Lines)
	}
	if doc.PreviewPDFPath != "/tmp/x.mtags.preview.pdf" {
		t.Fatalf("preview_pdf_path: %q", doc.PreviewPDFPath)
	}
}

// preview_first_only renders only the first tag (single-draft review) while the
// .mtags still stores ALL rows.
func TestBuildFromSheetPreviewFirstOnly(t *testing.T) {
	host := &seqHost{replies: []json.RawMessage{
		json.RawMessage(`{"success":true,"result":{"bytes_b64":"JVBERg==","byte_size":5,"page_count":1,"content_type":"application/pdf"}}`),
		json.RawMessage(`{"success":true,"result":{"path":"/tmp/y.mtags.preview.pdf","bytes_written":5}}`),
		json.RawMessage(`{"success":true,"result":{"path":"/tmp/y.mtags","bytes_written":100}}`),
	}}
	rows := `[{"Name":"A"},{"Name":"B"},{"Name":"C"}]`
	args := mustArgs(t, map[string]interface{}{
		"rows_json":          rows,
		"mapping":            map[string]interface{}{"title": "Name"},
		"out_path":           "/tmp/y.mtags",
		"preview_first_only": true,
	})
	res := toolNametagBuildFromSheet(host, args)
	if res["success"] != true {
		t.Fatalf("expected success, got %+v", res)
	}
	// Stored doc keeps all 3 rows.
	if res["row_count"] != 3 {
		t.Fatalf("row_count: want 3, got %v", res["row_count"])
	}
	// The doc rendered to host.pdf.generate (call 0) carries ONLY the first tag.
	genJSON, _ := json.Marshal(host.calls[0].args)
	s := string(genJSON)
	if !strings.Contains(s, `"text":"A"`) {
		t.Fatalf("preview doc should render first tag A: %s", s)
	}
	if strings.Contains(s, `"text":"B"`) || strings.Contains(s, `"text":"C"`) {
		t.Fatalf("preview_first_only must exclude later tags B/C: %s", s)
	}
}

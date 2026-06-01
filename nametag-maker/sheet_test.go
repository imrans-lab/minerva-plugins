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

// shared_back draws one CONSTANT back face behind every tag (e.g. a schedule):
// the rendered Doc gains a second (back) page carrying the schedule text, and
// the stored .mtags carries the shared `back` under generate.
func TestBuildFromSheetSharedBack(t *testing.T) {
	host := &seqHost{replies: []json.RawMessage{
		json.RawMessage(`{"success":true,"result":{"bytes_b64":"JVBERg==","byte_size":5,"page_count":2,"content_type":"application/pdf"}}`),
		json.RawMessage(`{"success":true,"result":{"path":"/tmp/s.mtags.preview.pdf","bytes_written":5}}`),
		json.RawMessage(`{"success":true,"result":{"path":"/tmp/s.mtags","bytes_written":100}}`),
	}}
	rows := `[{"Name":"Ada Lovelace"}]`
	args := mustArgs(t, map[string]interface{}{
		"rows_json": rows,
		"mapping":   map[string]interface{}{"title": "Name"},
		"shared_back": map[string]interface{}{
			"title": "Schedule",
			"columns": []map[string]interface{}{
				{"heading": "Thursday", "lines": []map[string]interface{}{
					{"value": "9:30 Snack"}, {"value": "10:00 Swim"},
				}},
			},
		},
		"out_path": "/tmp/s.mtags",
	})

	res := toolNametagBuildFromSheet(host, args)
	if res["success"] != true {
		t.Fatalf("expected success, got %+v", res)
	}

	// The rendered doc (host.pdf.generate, call 0) gains a back page with the schedule.
	genJSON, _ := json.Marshal(host.calls[0].args)
	s := string(genJSON)
	if !strings.Contains(s, "9:30 Snack") || !strings.Contains(s, "Thursday") {
		t.Fatalf("rendered doc should carry the shared-back schedule: %s", s)
	}
	var doc struct {
		Pages []struct {
			Ops []map[string]interface{} `json:"ops"`
		} `json:"pages"`
	}
	if err := json.Unmarshal(genJSON, &doc); err != nil {
		t.Fatalf("doc not valid JSON: %v", err)
	}
	if len(doc.Pages) != 2 {
		t.Fatalf("shared back → front + back page; want 2 pages, got %d", len(doc.Pages))
	}

	// The stored .mtags carries the shared back under generate.back.
	mtagsB64, _ := host.calls[2].args["content"].(string)
	docBytes, _ := base64.StdEncoding.DecodeString(mtagsB64)
	var stored struct {
		Generate struct {
			Back *struct {
				Title string `json:"title"`
			} `json:"back"`
		} `json:"generate"`
	}
	if err := json.Unmarshal(docBytes, &stored); err != nil {
		t.Fatalf(".mtags not valid JSON: %v", err)
	}
	if stored.Generate.Back == nil || stored.Generate.Back.Title != "Schedule" {
		t.Fatalf("stored .mtags should carry generate.back.title=Schedule: %s", docBytes)
	}
}

// back_mapping builds a DISTINCT per-row back face from columns; each row in the
// stored .mtags carries its own `back`, and a row with no back data has none.
func TestBuildFromSheetPerRowBack(t *testing.T) {
	host := &seqHost{replies: []json.RawMessage{
		json.RawMessage(`{"success":true,"result":{"bytes_b64":"JVBERg==","byte_size":5,"page_count":2,"content_type":"application/pdf"}}`),
		json.RawMessage(`{"success":true,"result":{"path":"/tmp/b.mtags.preview.pdf","bytes_written":5}}`),
		json.RawMessage(`{"success":true,"result":{"path":"/tmp/b.mtags","bytes_written":100}}`),
	}}
	// Ada has an elective; Bo has none → Bo gets no back face.
	rows := `[{"Name":"Ada","Elective":"Archery"},{"Name":"Bo","Elective":""}]`
	args := mustArgs(t, map[string]interface{}{
		"rows_json":    rows,
		"mapping":      map[string]interface{}{"title": "Name"},
		"back_mapping": map[string]interface{}{"lines": []map[string]interface{}{{"label": "Elective", "column": "Elective"}}},
		"out_path":     "/tmp/b.mtags",
	})

	res := toolNametagBuildFromSheet(host, args)
	if res["success"] != true {
		t.Fatalf("expected success, got %+v", res)
	}

	mtagsB64, _ := host.calls[2].args["content"].(string)
	docBytes, _ := base64.StdEncoding.DecodeString(mtagsB64)
	var stored struct {
		Generate struct {
			Rows []map[string]json.RawMessage `json:"rows"`
		} `json:"generate"`
	}
	if err := json.Unmarshal(docBytes, &stored); err != nil {
		t.Fatalf(".mtags not valid JSON: %v", err)
	}
	if len(stored.Generate.Rows) != 2 {
		t.Fatalf("want 2 rows, got %d", len(stored.Generate.Rows))
	}
	if _, ok := stored.Generate.Rows[0]["back"]; !ok {
		t.Fatalf("row0 (Ada) should have a back face: %s", docBytes)
	}
	if _, ok := stored.Generate.Rows[1]["back"]; ok {
		t.Fatalf("row1 (Bo, no elective) should have NO back face: %s", docBytes)
	}
	// The rendered doc carries Ada's elective on a back page.
	genJSON, _ := json.Marshal(host.calls[0].args)
	if !strings.Contains(string(genJSON), "Archery") {
		t.Fatalf("rendered doc should carry per-row back 'Archery': %s", genJSON)
	}
}

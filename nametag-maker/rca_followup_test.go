package main

// Regression tests for the RCA follow-up batch (W1–W3): the "nametag had no
// logo" failure. W1 — an empty front_images:[] must not force the explicit-face
// path. W2 — an icon-less explicit face adopts the shared icon as a side column.
// W3 — a registered-but-undrawn icon is surfaced as a warning, not dropped.

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

// W1: hasNonEmptyJSON treats absent/null/empty-container/blank-string as ABSENT,
// and only genuine content as present.
func TestHasNonEmptyJSON(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{``, false}, {`null`, false},
		{`[]`, false}, {`[ ]`, false}, {`{}`, false}, {`{ }`, false},
		{`""`, false}, {`"  "`, false},
		{`[1]`, true}, {`{"a":1}`, true}, {`"x"`, true},
		{`[{"image_id":"icon"}]`, true}, {`0`, true}, {`false`, true},
	}
	for _, c := range cases {
		if got := hasNonEmptyJSON(json.RawMessage(c.in)); got != c.want {
			t.Errorf("hasNonEmptyJSON(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

// W1 (the actual bug): front_images:[] — the model's natural "unused" default —
// must NOT force the explicit-face path. The row stays flat so the shared icon
// renders as a side column (this is exactly what produced "no logo"), and no
// orphan warning fires because the icon IS drawn.
func TestBuildFromSheetEmptyFrontImagesKeepsIcon(t *testing.T) {
	host := &seqHost{replies: []json.RawMessage{
		json.RawMessage(`{"success":true,"result":{"content":"Zm9v"}}`), // host.files.read (icon)
		json.RawMessage(`{"success":true,"result":{"bytes_b64":"JVBERg==","byte_size":5,"page_count":1,"content_type":"application/pdf"}}`), // host.pdf.generate
		json.RawMessage(`{"success":true,"result":{"path":"/tmp/e.mtags.preview.pdf","bytes_written":5}}`),
		json.RawMessage(`{"success":true,"result":{"path":"/tmp/e.mtags","bytes_written":100}}`),
	}}
	args := mustArgs(t, map[string]interface{}{
		"rows_json":    `[{"Name":"Ada"}]`,
		"mapping":      map[string]interface{}{"title": "Name"},
		"icon_path":    "/tmp/logo.png",
		"front_images": []map[string]interface{}{}, // EMPTY — the footgun
		"out_path":     "/tmp/e.mtags",
	})

	res := toolNametagBuildFromSheet(host, args)
	if res["success"] != true {
		t.Fatalf("expected success, got %+v", res)
	}
	if _, hasWarn := res["warnings"]; hasWarn {
		t.Fatalf("icon should be drawn (no warning), got %+v", res["warnings"])
	}

	// The rendered doc draws the side-column icon.
	genJSON, _ := json.Marshal(host.calls[1].args)
	if !strings.Contains(string(genJSON), `"image_id":"icon"`) {
		t.Fatalf("rendered doc should draw the shared icon: %s", genJSON)
	}

	// The stored row stays FLAT — empty front_images did not force an explicit
	// front face (the W1 root cause).
	mtagsB64, _ := host.calls[3].args["content"].(string)
	docBytes, _ := base64.StdEncoding.DecodeString(mtagsB64)
	var stored struct {
		Generate struct {
			Rows []map[string]interface{} `json:"rows"`
		} `json:"generate"`
	}
	if err := json.Unmarshal(docBytes, &stored); err != nil {
		t.Fatalf(".mtags not valid JSON: %v", err)
	}
	if len(stored.Generate.Rows) != 1 {
		t.Fatalf("want 1 row, got %d", len(stored.Generate.Rows))
	}
	if _, hasFront := stored.Generate.Rows[0]["front"]; hasFront {
		t.Fatalf("empty front_images must keep the row FLAT (no explicit front face): %s", docBytes)
	}
	if stored.Generate.Rows[0]["title"] != "Ada" {
		t.Fatalf("flat row should carry title: %+v", stored.Generate.Rows[0])
	}
}

// W2: an explicit front face with no image of its own adopts the shared icon as
// a side column, so a logo set via icon_path/icon_png_base64 still renders even
// on the explicit-face path (e.g. build_from_sheet with real front_images).
func TestExplicitFaceAdoptsSharedIcon(t *testing.T) {
	rows := []TagRow{{Front: &Face{Title: "Ada", Columns: []Column{{Lines: []DetailLine{{Value: "x"}}}}}}}
	doc := buildDoc(rows, []Image{{ID: imageID, Format: "png", BytesB64: "Zm9v"}}, Options{Layout: "detailed"})
	if !docDrawsImage(doc, imageID) {
		t.Fatalf("an icon-less explicit face should draw the shared icon as a side column")
	}
}

// W2 guard: a face that sets its OWN full_image_id is not overridden — the
// shared icon is not force-added (and, being undrawn, is caught by W3 upstream).
func TestExplicitFaceWithOwnImageKeepsIt(t *testing.T) {
	rows := []TagRow{{Front: &Face{FullImageID: "hero"}}}
	imgs := []Image{
		{ID: imageID, Format: "png", BytesB64: "Zm9v"},
		{ID: "hero", Format: "png", BytesB64: "YmFy"},
	}
	doc := buildDoc(rows, imgs, Options{Layout: "detailed"})
	if !docDrawsImage(doc, "hero") {
		t.Fatalf("face should draw its own full image")
	}
	if docDrawsImage(doc, imageID) {
		t.Fatalf("shared icon must NOT be force-added over a face's own full image")
	}
}

// W3: a registered icon that no face draws (every face uses its own
// full_image_id) is surfaced as a warning rather than silently dropped.
func TestGenerateWarnsOnOrphanedIcon(t *testing.T) {
	host := &seqHost{replies: []json.RawMessage{
		json.RawMessage(`{"success":true,"result":{"bytes_b64":"JVBERg==","byte_size":5,"page_count":1,"content_type":"application/pdf"}}`),
	}}
	args := mustArgs(t, map[string]interface{}{
		"rows": []map[string]interface{}{
			{"front": map[string]interface{}{"full_image_id": "hero", "title": "X"}},
		},
		"icon_png_base64": "Zm9v",
		"images":          []map[string]interface{}{{"id": "hero", "png_base64": "YmFy"}},
		"layout":          "detailed",
	})

	res := toolNametagGenerate(host, args)
	if res["success"] != true {
		t.Fatalf("expected success, got %+v", res)
	}
	warns, ok := res["warnings"].([]string)
	if !ok || len(warns) == 0 {
		t.Fatalf("expected an orphaned-icon warning, got %+v", res["warnings"])
	}
	if !strings.Contains(warns[0], "icon") {
		t.Fatalf("warning should name the icon: %q", warns[0])
	}
}

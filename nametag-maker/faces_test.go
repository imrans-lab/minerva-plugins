package main

import (
	"encoding/json"
	"testing"
)

// lineText is a pure render join: "Label: Value", or the value alone with no
// label. A blank value is the caller's choice (e.g. a fill-in template) and
// just yields "Label: " — no template logic lives in the plugin.
func TestLineTextJoin(t *testing.T) {
	cases := []struct {
		dl   DetailLine
		want string
	}{
		{DetailLine{Label: "Cabin", Value: "1C"}, "Cabin: 1C"},
		{DetailLine{Label: "Cabin", Value: ""}, "Cabin: "},
		{DetailLine{Label: "", Value: "9:30 Snack"}, "9:30 Snack"},
		{DetailLine{Label: "", Value: ""}, ""},
	}
	for _, c := range cases {
		if got := lineText(c.dl); got != c.want {
			t.Fatalf("lineText(%+v) = %q, want %q", c.dl, got, c.want)
		}
	}
}

// rows_path reads a JSON rows array from a file (host.files.read) and splices
// it in as `rows`, so a large roster need not be inlined into the call.
func TestResolveRowsPath(t *testing.T) {
	host := &seqHost{replies: []json.RawMessage{
		json.RawMessage(`{"success":true,"result":{"content":"[{\"title\":\"Ada\"},{\"title\":\"Bo\"}]"}}`),
	}}
	out, fault := resolveRowsPath(host, mustArgs(t, map[string]interface{}{
		"rows_path": "/tmp/roster.json", "layout": "detailed",
	}))
	if fault != nil {
		t.Fatalf("unexpected fault: %+v", fault)
	}
	if len(host.calls) != 1 || host.calls[0].capability != "host.files.read" {
		t.Fatalf("expected one host.files.read call, got %+v", host.calls)
	}
	if host.calls[0].args["path"] != "/tmp/roster.json" {
		t.Fatalf("read path: got %v", host.calls[0].args["path"])
	}
	var parsed struct {
		Rows []struct {
			Title string `json:"title"`
		} `json:"rows"`
		RowsPath string `json:"rows_path"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		t.Fatalf("spliced args not valid JSON: %v", err)
	}
	if parsed.RowsPath != "" {
		t.Fatalf("rows_path should be dropped after splice, got %q", parsed.RowsPath)
	}
	if len(parsed.Rows) != 2 || parsed.Rows[0].Title != "Ada" || parsed.Rows[1].Title != "Bo" {
		t.Fatalf("rows not spliced from file: %+v", parsed.Rows)
	}
}

// A front name face + a shared back schedule face: two pages, the schedule
// lands on the BACK at the column-reversed cell, and never on the front.
func TestBuildDocFacesFrontAndSharedBack(t *testing.T) {
	rows := []TagRow{{Front: &Face{
		ImageID: imageID, ImageSide: "left", Title: "Aadhira", Subtitle: "Aravindakumar",
		Columns: []Column{{Lines: []DetailLine{{Label: "Teacher", Value: "Shaw"}}}},
	}}}
	back := &Face{Columns: []Column{
		{Heading: "Thursday", Lines: []DetailLine{{Value: "9:30 Snack"}}},
		{Heading: "Friday", Lines: []DetailLine{{Value: "7:30 Rise and Shine"}}},
	}}

	doc := buildDoc(rows, testImg, Options{Layout: "detailed", Back: back})
	if len(doc.Pages) != 2 {
		t.Fatalf("front + shared back: want 2 pages, got %d", len(doc.Pages))
	}

	front, bp := doc.Pages[0], doc.Pages[1]
	hasText := func(p Page, s string) bool {
		for _, o := range p.Ops {
			if o.Kind == "draw_text" && o.Text == s {
				return true
			}
		}
		return false
	}
	if !hasText(bp, "Thursday") || !hasText(bp, "Friday") {
		t.Fatalf("back page missing schedule headings")
	}
	if hasText(front, "Thursday") || hasText(front, "Friday") {
		t.Fatalf("schedule leaked onto the front page")
	}
	if !hasText(front, "Aadhira") {
		t.Fatalf("front page missing the name title")
	}

	// Back content must sit at the column-reversed cell.
	layout := cardstock4x2()
	pos := layout.cellPositions()
	frontX := pos[0][0] + padding
	backX := pos[layout.backCellIndex(0)][0] + padding
	if approx(frontX, backX) {
		t.Fatal("reversal is a no-op")
	}
	foundReversed := false
	for _, o := range bp.Ops {
		if o.X != nil && approx(*o.X, backX) {
			foundReversed = true
			break
		}
	}
	if !foundReversed {
		t.Fatalf("back content not at column-reversed cell content X %v", backX)
	}
}

// A full-image back face draws exactly one image (the design) referencing its
// own id — the escape hatch for arbitrary back art.
func TestBuildDocFullImageFace(t *testing.T) {
	imgs := []Image{
		{ID: imageID, Format: "png", BytesB64: "Zm9v"},
		{ID: "backdesign", Format: "png", BytesB64: "YmFy"},
	}
	rows := []TagRow{{
		Front: &Face{Title: "Hi"},
		Back:  &Face{FullImageID: "backdesign"},
	}}
	doc := buildDoc(rows, imgs, Options{Layout: "detailed"})
	if len(doc.Pages) != 2 {
		t.Fatalf("want 2 pages, got %d", len(doc.Pages))
	}
	imgOps := 0
	for _, o := range doc.Pages[1].Ops {
		if o.Kind == "draw_image" {
			imgOps++
			if o.ImageID != "backdesign" {
				t.Fatalf("full-image back references %q, want backdesign", o.ImageID)
			}
		}
	}
	if imgOps != 1 {
		t.Fatalf("full-image back: want 1 draw_image, got %d", imgOps)
	}
}

// A face with a free-placed image emits a draw_image at the right absolute
// coordinates (content-box origin + inches→pt), width, and rotation angle —
// drawn AFTER the structured content (foreground).
func TestBuildDocPlacedImage(t *testing.T) {
	imgs := []Image{
		{ID: imageID, Format: "png", BytesB64: "Zm9v"},
		{ID: "logo", Format: "png", BytesB64: "YmFy"},
	}
	rows := []TagRow{{Front: &Face{
		Title:  "Hi",
		Placed: []PlacedImage{{ImageID: "logo", XIn: 0.5, YIn: 0.25, WidthIn: 0.75, RotationDeg: 30}},
	}}}
	doc := buildDoc(rows, imgs, Options{Layout: "detailed"})

	layout := cardstock4x2()
	pos := layout.cellPositions()
	b := tagBox{x: pos[0][0], y: pos[0][1], w: layout.tagW, h: layout.tagH}
	wantX, wantY, wantW := b.contentX()+inToPt(0.5), b.contentY()+inToPt(0.25), inToPt(0.75)

	var found *Op
	titleIdx, logoIdx := -1, -1
	for i := range doc.Pages[0].Ops {
		o := doc.Pages[0].Ops[i]
		if o.Kind == "draw_text" && o.Text == "Hi" {
			titleIdx = i
		}
		if o.Kind == "draw_image" && o.ImageID == "logo" {
			found = &doc.Pages[0].Ops[i]
			logoIdx = i
		}
	}
	if found == nil {
		t.Fatal("placed logo draw_image missing from front page")
	}
	if found.X == nil || !approx(*found.X, wantX) {
		t.Fatalf("placed X: got %v want %v", found.X, wantX)
	}
	if found.Y == nil || !approx(*found.Y, wantY) {
		t.Fatalf("placed Y: got %v want %v", found.Y, wantY)
	}
	if found.W == nil || !approx(*found.W, wantW) {
		t.Fatalf("placed W: got %v want %v", found.W, wantW)
	}
	if found.Angle == nil || !approx(*found.Angle, 30) {
		t.Fatalf("placed Angle: got %v want 30", found.Angle)
	}
	if !(logoIdx > titleIdx) {
		t.Fatalf("placed image should draw AFTER the title (foreground): title@%d logo@%d", titleIdx, logoIdx)
	}
}

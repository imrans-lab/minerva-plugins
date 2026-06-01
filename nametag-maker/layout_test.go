package main

import (
	"math"
	"testing"
)

// eightRows includes two deliberately long names that must trigger the name
// auto-shrink (effective drawn size < 20 via the `fit` block).
var eightRows = []TagRow{
	{Name: "Ada", Class: "Math 1", Group: "1", Room: "A101"},
	{Name: "Maximilian Hohenzollern-Sigmaringen", Class: "Physics", Group: "2", Room: "B205"},
	{Name: "Bob Smith", Class: "Chem", Group: "3", Room: "C300"},
	{Name: "Grace Hopper", Class: "CS 200", Group: "1", Room: "A101"},
	{Name: "Wolfgang Amadeus Mozart-Beethoven", Class: "Music", Group: "2", Room: "D404"},
	{Name: "Liu", Class: "Art", Group: "3", Room: "E12"},
	{Name: "Katherine Johnson", Class: "Math 2", Group: "1", Room: "A102"},
	{Name: "Bartholomew Featherstonehaugh III", Class: "History", Group: "2", Room: "F555"},
}

func approx(a, b float64) bool { return math.Abs(a-b) < 1e-6 }

func countKind(ops []Op, kind string) int {
	n := 0
	for _, o := range ops {
		if o.Kind == kind {
			n++
		}
	}
	return n
}

func textOps(ops []Op) []Op {
	var out []Op
	for _, o := range ops {
		if o.Kind == "draw_text" {
			out = append(out, o)
		}
	}
	return out
}

func TestBuildDocBackModeSamePageCount(t *testing.T) {
	doc := buildDoc(eightRows, "Zm9v", Options{BackMode: "same"})
	if len(doc.Pages) != 2 {
		t.Fatalf("back_mode same with 8 rows: want 2 pages, got %d", len(doc.Pages))
	}
}

func TestBuildDocBackModeBlankPageCount(t *testing.T) {
	doc := buildDoc(eightRows, "Zm9v", Options{BackMode: "blank"})
	if len(doc.Pages) != 1 {
		t.Fatalf("back_mode blank with 8 rows: want 1 page, got %d", len(doc.Pages))
	}
}

func TestBuildDocIconEmbeddedOnceAndReferenced(t *testing.T) {
	doc := buildDoc(eightRows, "Zm9v", Options{BackMode: "same"})
	if len(doc.Images) != 1 {
		t.Fatalf("want exactly 1 embedded image, got %d", len(doc.Images))
	}
	if doc.Images[0].ID != imageID {
		t.Fatalf("image id: want %q, got %q", imageID, doc.Images[0].ID)
	}
	// One draw_image per tag per page: 8 tags × 2 pages = 16.
	total := 0
	for _, p := range doc.Pages {
		total += countKind(p.Ops, "draw_image")
		for _, o := range p.Ops {
			if o.Kind == "draw_image" && o.ImageID != imageID {
				t.Fatalf("draw_image references unknown image id %q", o.ImageID)
			}
		}
	}
	if total != 16 {
		t.Fatalf("want 16 draw_image ops (8 tags × 2 pages), got %d", total)
	}
}

func TestBuildDocBackPageColumnReversed(t *testing.T) {
	// Front index 0 sits at the top-left cell; its back tag must sit at the
	// column-reversed cell (top-right). We detect a tag by the X of its icon op.
	layout := cardstock4x2()
	pos := layout.cellPositions()
	frontIconX := pos[0][0] + padding
	backIdx := layout.backCellIndex(0)
	backIconX := pos[backIdx][0] + padding

	if approx(frontIconX, backIconX) {
		t.Fatalf("front and back cell-0 share an X (%v) — reversal is a no-op", frontIconX)
	}

	doc := buildDoc(eightRows, "Zm9v", Options{BackMode: "same"})
	front, back := doc.Pages[0], doc.Pages[1]

	// First draw_image on each page is tag 0 (draw order = guides..., icon, ...).
	firstImageX := func(p Page) float64 {
		for _, o := range p.Ops {
			if o.Kind == "draw_image" {
				return *o.X
			}
		}
		t.Fatal("no draw_image on page")
		return 0
	}
	if got := firstImageX(front); !approx(got, frontIconX) {
		t.Fatalf("front tag-0 icon X: want %v, got %v", frontIconX, got)
	}
	if got := firstImageX(back); !approx(got, backIconX) {
		t.Fatalf("back tag-0 icon X (column-reversed): want %v, got %v", backIconX, got)
	}
}

func TestBuildDocLongNamesShrink(t *testing.T) {
	doc := buildDoc(eightRows, "Zm9v", Options{BackMode: "blank"})
	front := doc.Pages[0]

	// Find the name draw_text for the long name "Maximilian Hohenzollern-Sigmaringen".
	const longName = "Maximilian Hohenzollern-Sigmaringen"
	var nameOpFound *Op
	for i := range front.Ops {
		if front.Ops[i].Kind == "draw_text" && front.Ops[i].Text == longName {
			nameOpFound = &front.Ops[i]
			break
		}
	}
	if nameOpFound == nil {
		t.Fatalf("no draw_text for long name %q", longName)
	}
	// The name op must carry a fit block so the sidecar shrinks below 20pt.
	if nameOpFound.Fit == nil {
		t.Fatalf("long name draw_text missing fit block (auto-shrink)")
	}
	if nameOpFound.Fit.MinSize != 12 {
		t.Fatalf("fit.min_size: want 12, got %v", nameOpFound.Fit.MinSize)
	}
	if nameOpFound.Font == nil || nameOpFound.Font.Size != 20 {
		t.Fatalf("name font.size should start at 20 (sidecar shrinks via fit), got %+v", nameOpFound.Font)
	}
	// content width oracle: tagW - 2*padding.
	wantMax := inToPt(3.375) - 2*padding
	if !approx(nameOpFound.Fit.MaxWidth, wantMax) {
		t.Fatalf("fit.max_width: want %v (content width), got %v", wantMax, nameOpFound.Fit.MaxWidth)
	}
}

func TestBuildDocEachPopulatedFieldEmitsText(t *testing.T) {
	// Tag 0 (Ada) has all four fields populated → 4 draw_text ops (name, class,
	// room, group). Use back_mode blank so we look at one page only.
	single := []TagRow{{Name: "Ada", Class: "Math 1", Group: "1", Room: "A101"}}
	doc := buildDoc(single, "Zm9v", Options{BackMode: "blank"})
	got := len(textOps(doc.Pages[0].Ops))
	if got != 4 {
		t.Fatalf("fully-populated tag: want 4 draw_text ops, got %d", got)
	}

	// A tag with only a name emits exactly one draw_text.
	nameOnly := []TagRow{{Name: "Solo"}}
	doc2 := buildDoc(nameOnly, "Zm9v", Options{BackMode: "blank"})
	if got := len(textOps(doc2.Pages[0].Ops)); got != 1 {
		t.Fatalf("name-only tag: want 1 draw_text op, got %d", got)
	}
}

func TestBuildDocCornerMarksVsFullGuides(t *testing.T) {
	single := []TagRow{{Name: "Ada", Class: "Math 1", Group: "1", Room: "A101"}}

	// Default: 8 corner-mark draw_line ops per tag, no draw_rect.
	doc := buildDoc(single, "Zm9v", Options{BackMode: "blank"})
	if got := countKind(doc.Pages[0].Ops, "draw_line"); got != 8 {
		t.Fatalf("corner marks: want 8 draw_line ops, got %d", got)
	}
	if got := countKind(doc.Pages[0].Ops, "draw_rect"); got != 0 {
		t.Fatalf("corner-mark mode should emit no draw_rect, got %d", got)
	}

	// full_guides: a single draw_rect per tag, no corner-mark lines.
	docG := buildDoc(single, "Zm9v", Options{BackMode: "blank", FullGuides: true})
	if got := countKind(docG.Pages[0].Ops, "draw_rect"); got != 1 {
		t.Fatalf("full_guides: want 1 draw_rect op, got %d", got)
	}
	if got := countKind(docG.Pages[0].Ops, "draw_line"); got != 0 {
		t.Fatalf("full_guides should emit no corner-mark draw_line ops, got %d", got)
	}
}

func TestBuildDocIconGeometryOracle(t *testing.T) {
	// Exact-coordinate oracle from the harness geometry: front tag 0's icon
	// sits at (marginLeft+padding, marginTop+padding) with width = 0.40in.
	doc := buildDoc([]TagRow{{Name: "Ada"}}, "Zm9v", Options{BackMode: "blank"})
	var icon *Op
	for i := range doc.Pages[0].Ops {
		if doc.Pages[0].Ops[i].Kind == "draw_image" {
			icon = &doc.Pages[0].Ops[i]
			break
		}
	}
	if icon == nil {
		t.Fatal("no draw_image op")
	}
	// marginLeft = (612 - (2*243 + 14.4))/2 = 55.8 ; +padding(9) = 64.8
	if !approx(*icon.X, 64.8) {
		t.Fatalf("icon X oracle: want 64.8, got %v", *icon.X)
	}
	if !approx(*icon.W, inToPt(0.40)) {
		t.Fatalf("icon W oracle: want %v (0.40in), got %v", inToPt(0.40), *icon.W)
	}
}

func TestBuildDocBackOffsetApplied(t *testing.T) {
	doc := buildDoc([]TagRow{{Name: "Ada"}}, "Zm9v", Options{
		BackMode: "same", BackOffsetX: 5, BackOffsetY: 7,
	})
	layout := cardstock4x2()
	pos := layout.cellPositions()
	backIdx := layout.backCellIndex(0)
	wantX := pos[backIdx][0] + 5 + padding // +offset, +content padding for icon

	var backIcon *Op
	for i := range doc.Pages[1].Ops {
		if doc.Pages[1].Ops[i].Kind == "draw_image" {
			backIcon = &doc.Pages[1].Ops[i]
			break
		}
	}
	if backIcon == nil {
		t.Fatal("no back-page draw_image op")
	}
	if !approx(*backIcon.X, wantX) {
		t.Fatalf("back icon X with offset: want %v, got %v", wantX, *backIcon.X)
	}
}

// nineRows = eightRows + one more, to exercise multi-sheet spill (9 tags need
// 2 sheets of 8 cells each).
var nineRows = append(append([]TagRow{}, eightRows...),
	TagRow{Name: "Ninth Person", Class: "Bio", Group: "3", Room: "G700"})

func TestBuildDocMultiSheetSpillSame(t *testing.T) {
	// 9 rows, back_mode "same": sheet1 front+back + sheet2 front+back = 4 pages.
	doc := buildDoc(nineRows, "Zm9v", Options{BackMode: "same"})
	if len(doc.Pages) != 4 {
		t.Fatalf("9 rows back_mode same: want 4 pages, got %d", len(doc.Pages))
	}
	// Sheet 2's single tag must appear: its front page (page index 2) has exactly
	// one icon draw, and its back page (index 3) also one (column-reversed cell).
	if got := countKind(doc.Pages[2].Ops, "draw_image"); got != 1 {
		t.Fatalf("sheet2 front: want 1 icon draw, got %d", got)
	}
	if got := countKind(doc.Pages[3].Ops, "draw_image"); got != 1 {
		t.Fatalf("sheet2 back: want 1 icon draw, got %d", got)
	}
}

func TestBuildDocMultiSheetSpillBlank(t *testing.T) {
	// 9 rows, back_mode "blank": 2 front pages only.
	doc := buildDoc(nineRows, "Zm9v", Options{BackMode: "blank"})
	if len(doc.Pages) != 2 {
		t.Fatalf("9 rows back_mode blank: want 2 pages, got %d", len(doc.Pages))
	}
}

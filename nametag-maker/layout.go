package main

// layout.go ports the nametag layout from the P1.1 gate harness
// (src/sidecars/host_pdf/cmd/gateharness/harness.go) into pure functions that
// produce a host.pdf `Doc`. The host is a dumb renderer; the plugin owns ALL
// layout/geometry (contract §8): the cardstock 4×2 centered grid, 0.125in
// padding, the 4mm corner marks, the 0.40in icon, the name auto-shrink, and
// the back-page column reversal with registration offsets.
//
// One deliberate divergence from harness.go: the harness instantiates fpdf to
// MEASURE strings and bakes exact x/tw coordinates. This plugin must NOT depend
// on fpdf (host owns drawing; plugin owns layout — DRY guardrail), so:
//
//   - The name field emits a draw_text with `fit` (contract §5): font.size 20,
//     min_size 12, step 1, max_width = content width. The sidecar measures and
//     shrinks with the same font instance it draws with — gate-faithful by
//     construction, and avoids the plugin duplicating font metrics.
//   - The class/room/group fields (DejaVuSans 10pt) can't pre-measure their
//     width to compute `x = right - tw`. Instead they anchor a full-content-
//     width cell and let the renderer align: left field align "L", right
//     fields align "R". The drawn glyphs land in the same corner the harness
//     placed them, without the plugin reimplementing get_string_width.

// ---- unit helpers (mirror generate_tags.py) ----

func inToPt(in float64) float64 { return in * 72.0 }
func mmToPt(mm float64) float64 { return mm * 2.83465 }

// ---- layout (mirror LayoutConfig.cardstock_4x2) ----

type layoutConfig struct {
	pageW, pageH          float64
	tagW, tagH            float64
	marginLeft, marginTop float64
	gutterH, gutterV      float64
	rows, cols            int
}

func cardstock4x2() layoutConfig {
	pageW := inToPt(8.5)
	pageH := inToPt(11)
	tagW := inToPt(3.375)
	tagH := inToPt(2.333)
	rows, cols := 4, 2
	gutterH := inToPt(0.20)
	gutterV := inToPt(0.20)
	totalW := float64(cols)*tagW + float64(cols-1)*gutterH
	totalH := float64(rows)*tagH + float64(rows-1)*gutterV
	return layoutConfig{
		pageW: pageW, pageH: pageH, tagW: tagW, tagH: tagH,
		marginLeft: (pageW - totalW) / 2, marginTop: (pageH - totalH) / 2,
		gutterH: gutterH, gutterV: gutterV, rows: rows, cols: cols,
	}
}

func (l layoutConfig) cellPositions() [][2]float64 {
	var p [][2]float64
	for row := 0; row < l.rows; row++ {
		for col := 0; col < l.cols; col++ {
			x := l.marginLeft + float64(col)*(l.tagW+l.gutterH)
			y := l.marginTop + float64(row)*(l.tagH+l.gutterV)
			p = append(p, [2]float64{x, y})
		}
	}
	return p
}

// backCellIndex maps a front cell index to the column-reversed back cell so a
// duplex print lines the back of each tag up behind its front.
func (l layoutConfig) backCellIndex(front int) int {
	row := front / l.cols
	col := front % l.cols
	backCol := l.cols - 1 - col
	return row*l.cols + backCol
}

// cellsPerSheet is how many tags fit on one physical sheet.
func (l layoutConfig) cellsPerSheet() int { return l.rows * l.cols }

// ---- tag box (mirror TagBox; padding = 0.125in) ----

type tagBox struct{ x, y, w, h float64 }

const padding = 9.0 // inToPt(0.125)

func (b tagBox) contentX() float64 { return b.x + padding }
func (b tagBox) contentY() float64 { return b.y + padding }
func (b tagBox) contentW() float64 { return b.w - 2*padding }
func (b tagBox) contentH() float64 { return b.h - 2*padding }

// ---- public types ----

// TagRow is one tag's data. Empty fields omit their draw (matches harness/
// original).
type TagRow struct {
	Name  string
	Class string
	Group string
	Room  string
}

// Options controls duplex/registration behaviour.
type Options struct {
	// BackMode is "same" (mirror front onto the back, column-reversed) or
	// "blank" (no back page at all). Default "same".
	BackMode string
	// BackOffsetX / BackOffsetY are registration nudges (points) applied to
	// every back-page tag box, to compensate for printer duplex drift.
	BackOffsetX float64
	BackOffsetY float64
	// FullGuides draws a full bounding rectangle per tag instead of the 4
	// corner marks.
	FullGuides bool
	// IconWidthIn is the icon width in inches. Default 0.40.
	IconWidthIn float64
}

const (
	fontFamily = "DejaVuSans"
	imageID    = "icon"
)

func f(v float64) *float64 { return &v }

// ---- per-field op builders (mirror TagRenderer.render_tag draw order) ----

func iconOp(b tagBox, iconWidthPt float64) Op {
	return Op{Kind: "draw_image", ImageID: imageID, X: f(b.contentX()), Y: f(b.contentY()), W: f(iconWidthPt)}
}

// nameOp mirrors _draw_name. The harness baked exact size+width via fpdf
// measurement; here we delegate the shrink to the sidecar via `fit`:
//
//	font.size 20 → shrink (step 1) to min_size 12 until width ≤ content width.
//
// The cell spans the full content width and centers (align "C"), matching the
// original's centered name field.
func nameOp(b tagBox, name string) (Op, bool) {
	if name == "" {
		return Op{}, false
	}
	const lineHeight = 24.0 // size*1.2 at the unshrunk 20pt; renderer reflows vertically within h
	x := b.contentX()
	y := b.contentY() + (b.contentH()-lineHeight)/2
	return Op{
		Kind: "draw_text", Text: name,
		X: f(x), Y: f(y), W: f(b.contentW()), H: f(lineHeight), Align: "C",
		Font: &Font{Family: fontFamily, Style: "B", Size: 20},
		Fit:  &Fit{MaxWidth: b.contentW(), MinSize: 12, Step: 1},
	}, true
}

// classOp mirrors _draw_class: DejaVuSans 10, upper-right corner.
func classOp(b tagBox, classNum string) (Op, bool) {
	if classNum == "" {
		return Op{}, false
	}
	return cornerText(b, "Class: "+classNum, b.contentX(), b.contentY(), b.contentW(), "R"), true
}

// roomOp mirrors _draw_room: DejaVuSans 10, lower-left corner.
func roomOp(b tagBox, room string) (Op, bool) {
	if room == "" {
		return Op{}, false
	}
	y := b.y + b.h - padding - 10
	return cornerText(b, "Room: "+room, b.contentX(), y, b.contentW(), "L"), true
}

// groupOp mirrors _draw_group: DejaVuSans 10, lower-right corner.
func groupOp(b tagBox, group string) (Op, bool) {
	if group == "" {
		return Op{}, false
	}
	y := b.y + b.h - padding - 10
	return cornerText(b, "Group: "+group, b.contentX(), y, b.contentW(), "R"), true
}

// cornerText builds a 10pt regular draw_text anchored at (x,y) spanning width w
// with the given alignment. align "R" pins the glyphs to the right edge of the
// content box; "L" to the left — replicating the harness's per-corner x without
// pre-measuring the string in the plugin.
func cornerText(b tagBox, text string, x, y, w float64, align string) Op {
	return Op{
		Kind: "draw_text", Text: text,
		X: f(x), Y: f(y), W: f(w), H: f(10), Align: align,
		Font: &Font{Family: fontFamily, Style: "", Size: 10},
	}
}

// cornerMarkOps mirrors _draw_corner_marks: 4mm marks, gray 200, width 0.35,
// with the left/top clamps at the page edge. Draw order matches the harness.
func cornerMarkOps(b tagBox) []Op {
	mark := mmToPt(4)
	markLeft := mark
	if b.x < markLeft {
		markLeft = b.x
	}
	markTop := mark
	if b.y < markTop {
		markTop = b.y
	}
	gray := &RGB{200, 200, 200}
	w := 0.35
	xR := b.x + b.w
	yB := b.y + b.h
	line := func(x1, y1, x2, y2 float64) Op {
		return Op{Kind: "draw_line", X1: f(x1), Y1: f(y1), X2: f(x2), Y2: f(y2), Width: f(w), Color: gray}
	}
	return []Op{
		// top-left
		line(b.x-markLeft, b.y, b.x, b.y),
		line(b.x, b.y-markTop, b.x, b.y),
		// top-right
		line(xR, b.y, xR+mark, b.y),
		line(xR, b.y-markTop, xR, b.y),
		// bottom-left
		line(b.x-markLeft, yB, b.x, yB),
		line(b.x, yB, b.x, yB+mark),
		// bottom-right
		line(xR, yB, xR+mark, yB),
		line(xR, yB, xR, yB+mark),
	}
}

// fullGuideOp mirrors _draw_full_guides: a full bounding rect per tag (gray,
// stroke 0.25, no fill) drawn instead of corner marks.
func fullGuideOp(b tagBox) Op {
	return Op{
		Kind: "draw_rect", X: f(b.x), Y: f(b.y), W: f(b.w), H: f(b.h),
		Style: "D", StrokeWidth: f(0.25), StrokeColor: &RGB{200, 200, 200},
	}
}

// renderTagOps emits the ops for one tag box. Draw order matches the harness:
// guides (corner marks OR full rect), icon, class, name, room, group.
func renderTagOps(b tagBox, t TagRow, iconWidthPt float64, fullGuides bool) []Op {
	var ops []Op
	if fullGuides {
		ops = append(ops, fullGuideOp(b))
	} else {
		ops = append(ops, cornerMarkOps(b)...)
	}
	ops = append(ops, iconOp(b, iconWidthPt))
	if op, ok := classOp(b, t.Class); ok {
		ops = append(ops, op)
	}
	if op, ok := nameOp(b, t.Name); ok {
		ops = append(ops, op)
	}
	if op, ok := roomOp(b, t.Room); ok {
		ops = append(ops, op)
	}
	if op, ok := groupOp(b, t.Group); ok {
		ops = append(ops, op)
	}
	return ops
}

// buildDoc ports harness.buildDoc: given tag rows + the icon PNG (base64) +
// options, produce the full host.pdf Doc.
//
// Front pages lay tags out in normal grid order; back pages (back_mode "same")
// place each front-index tag at its column-reversed cell, optionally nudged by
// the registration offset. Rows beyond one sheet (8 cells) spill onto
// additional front/back sheet pairs, preserving the front→back pairing.
func buildDoc(rows []TagRow, iconPNGBase64 string, opts Options) Doc {
	layout := cardstock4x2()
	positions := layout.cellPositions()
	perSheet := layout.cellsPerSheet()

	backMode := opts.BackMode
	if backMode == "" {
		backMode = "same"
	}
	iconWidthIn := opts.IconWidthIn
	if iconWidthIn <= 0 {
		iconWidthIn = 0.40
	}
	iconWidthPt := inToPt(iconWidthIn)

	var pages []Page
	for start := 0; start < len(rows); start += perSheet {
		end := start + perSheet
		if end > len(rows) {
			end = len(rows)
		}
		sheet := rows[start:end]

		frontOps := []Op{}
		backOps := []Op{}
		for i, t := range sheet {
			fx, fy := positions[i][0], positions[i][1]
			fb := tagBox{x: fx, y: fy, w: layout.tagW, h: layout.tagH}
			frontOps = append(frontOps, renderTagOps(fb, t, iconWidthPt, opts.FullGuides)...)

			if backMode == "same" {
				bi := layout.backCellIndex(i)
				bx, by := positions[bi][0], positions[bi][1]
				bb := tagBox{x: bx + opts.BackOffsetX, y: by + opts.BackOffsetY, w: layout.tagW, h: layout.tagH}
				backOps = append(backOps, renderTagOps(bb, t, iconWidthPt, opts.FullGuides)...)
			}
		}
		pages = append(pages, Page{Ops: frontOps})
		if backMode == "same" {
			pages = append(pages, Page{Ops: backOps})
		}
	}
	if len(pages) == 0 {
		pages = append(pages, Page{Ops: []Op{}})
	}

	return Doc{
		Defaults: &Defaults{Format: "Letter", Orientation: "portrait", Unit: "pt"},
		Metadata: &Metadata{
			Title:   "Name Tags",
			Author:  "Name Tag Generator",
			Subject: "Duplex Name Tags",
			Creator: "Minerva host.pdf",
		},
		Images: []Image{{ID: imageID, Format: "png", BytesB64: iconPNGBase64}},
		Pages:  pages,
	}
}

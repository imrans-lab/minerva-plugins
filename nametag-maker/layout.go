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

// DetailLine is one line in a face column. With a Label it renders
// "Label: Value"; with an empty Label it renders Value alone (e.g. a schedule
// row "9:30 Snack"). An entirely empty line is skipped.
type DetailLine struct {
	Label string
	Value string
}

// Column is a vertical stack of lines in a structured face, with an optional
// bold heading (e.g. a day name on a schedule). Multiple columns render
// side-by-side across the face's text region.
type Column struct {
	Heading string
	Lines   []DetailLine
}

// Face is the content of ONE side of a tag — the generic unit both the front
// and back use. Two flavors:
//   - structured: an optional side image (ImageID + ImageSide) + Title +
//     Subtitle + one or more Columns of lines, all auto-shrunk to fit.
//   - full image: FullImageID set → that image fills the tag content box and
//     the structured fields are ignored. The escape hatch for dropping an
//     arbitrary pre-rendered design onto a side.
type Face struct {
	ImageID     string // side image id ("" = none); structured only
	ImageSide   string // "left" (default) | "right"
	Title       string
	Subtitle    string
	Columns     []Column
	FullImageID string // if set, fill the tag with this image (overrides structured)
	// Placed are free-positioned images (a logo, a stamp) drawn ON TOP of the
	// face content. Coordinates are tag-LOCAL inches relative to the content box.
	Placed []PlacedImage
}

// PlacedImage positions one image freely on a face: top-left (XIn, YIn) inches
// from the content-box origin, WidthIn wide (HeightIn 0 → preserve aspect),
// rotated RotationDeg clockwise about its center. The image id must be a
// registered doc image (the shared "icon" or an images[] entry).
type PlacedImage struct {
	ImageID     string
	XIn         float64
	YIn         float64
	WidthIn     float64
	HeightIn    float64
	RotationDeg float64
}

// placedImageOps emits the draw_image ops for a face's free-placed images.
// Tag-local content-box coordinates → absolute points; rotation passes through
// to the host.pdf `angle`. Skips entries with no image id or non-positive width.
func placedImageOps(b tagBox, placed []PlacedImage) []Op {
	var ops []Op
	for _, p := range placed {
		if p.ImageID == "" || p.WidthIn <= 0 {
			continue
		}
		op := Op{
			Kind:    "draw_image",
			ImageID: p.ImageID,
			X:       f(b.contentX() + inToPt(p.XIn)),
			Y:       f(b.contentY() + inToPt(p.YIn)),
			W:       f(inToPt(p.WidthIn)),
		}
		if p.HeightIn > 0 {
			op.H = f(inToPt(p.HeightIn))
		}
		if p.RotationDeg != 0 {
			op.Angle = f(p.RotationDeg)
		}
		ops = append(ops, op)
	}
	return ops
}

// TagRow is one physical tag. The classic layout uses Name/Class/Group/Room.
// The generic layout uses Front (and optional Back) faces; the flat
// Title/Subtitle/Lines are a convenience that map to a single-column Front face.
type TagRow struct {
	// classic layout
	Name  string
	Class string
	Group string
	Room  string

	// flat detailed convenience (→ a 1-column Front face)
	Title    string
	Subtitle string
	Lines    []DetailLine

	// generic faces
	Front *Face
	Back  *Face
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
	// IconWidthIn is the icon/image width in inches. Default 0.40 for the
	// classic layout, 1.0 for the detailed layout.
	IconWidthIn float64
	// Layout selects the tag template: "classic" (icon + class/name/room/group)
	// or "detailed" (image on one side + big Title + Subtitle + detail Lines).
	// Default "classic". Any per-row Front/Back face or a shared Back also
	// switches to the generic faces renderer.
	Layout string
	// ImageSide is "left" (default) or "right" — applies to the flat-detailed
	// front face only (explicit faces carry their own ImageSide).
	ImageSide string
	// Back is a shared back face drawn behind EVERY tag (e.g. a common
	// schedule), aligned per tag for duplex. A per-row TagRow.Back overrides it.
	Back *Face
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

// renderTagOps emits the CONTENT ops for one classic tag box (guides are drawn
// separately by the caller via guideOps, same as the faces path). Draw order
// mirrors the harness: icon, class, name, room, group.
func renderTagOps(b tagBox, t TagRow, iconWidthPt float64) []Op {
	var ops []Op
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

// detailGap is the horizontal gap (pt) between the image column and the text
// region; colGap is the gap between side-by-side columns.
const (
	detailGap = 8.0
	colGap    = 6.0
)

// guideOps draws the per-cell cut guides: 4mm corner marks (default) or a full
// bounding rect. Drawn once per cell, independent of the face content.
func guideOps(b tagBox, fullGuides bool) []Op {
	if fullGuides {
		return []Op{fullGuideOp(b)}
	}
	return cornerMarkOps(b)
}

// textOp builds a left/aligned draw_text op with a fit block.
func textOp(text string, x, y, w, h float64, align, style string, size float64, fit *Fit) Op {
	return Op{
		Kind: "draw_text", Text: text,
		X: f(x), Y: f(y), W: f(w), H: f(h), Align: align,
		Font: &Font{Family: fontFamily, Style: style, Size: size}, Fit: fit,
	}
}

// lineText joins a DetailLine for display: a value with no label renders alone
// (e.g. a schedule row "9:30 Snack"); otherwise it's "Label: Value". This is a
// pure render join — the CALLER decides content, including whether a field is a
// fill-in blank (pass an empty or placeholder value) or carries data.
func lineText(dl DetailLine) string {
	if dl.Label == "" {
		return dl.Value
	}
	return dl.Label + ": " + dl.Value
}

// renderFaceOps draws ONE face's content within tag box b. Guides are drawn
// separately (per cell). Every text field carries a `fit` block so content
// auto-shrinks to its column width — the sidecar measures+shrinks with the same
// font it draws with, so the plugin never reimplements font metrics (DRY).
func renderFaceOps(b tagBox, fc Face, imgWidthPt float64) []Op {
	// Full-image face: fill the content box (renderer scales height by aspect),
	// then any free-placed images on top (e.g. a logo over a background).
	if fc.FullImageID != "" {
		ops := []Op{{Kind: "draw_image", ImageID: fc.FullImageID, X: f(b.contentX()), Y: f(b.contentY()), W: f(b.contentW())}}
		return append(ops, placedImageOps(b, fc.Placed)...)
	}

	var ops []Op

	// Resolve the text region; a side image (if any) reserves a column.
	hasImage := fc.ImageID != ""
	imgX := b.contentX()
	textX := b.contentX()
	textW := b.contentW()
	if hasImage {
		// Clamp the image column so the text region keeps a usable positive
		// width even if the caller passes an oversized icon_width_in.
		if maxImg := b.contentW() * 0.6; imgWidthPt > maxImg {
			imgWidthPt = maxImg
		}
		if fc.ImageSide == "right" {
			imgX = b.x + b.w - padding - imgWidthPt
			textX = b.contentX()
		} else {
			imgX = b.contentX()
			textX = b.contentX() + imgWidthPt + detailGap
		}
		textW = b.contentW() - imgWidthPt - detailGap
	}

	// Base type sizes (the name/Title is the hero). Line height = size * factor.
	titleSz, subSz, headSz, lineSz := 24.0, 14.0, 11.0, 10.0
	const titleFactor, lineFactor, subGap = 1.15, 1.25, 2.0
	titleLH, subLH := titleSz*titleFactor, subSz*titleFactor
	headLH, lineLH := headSz*lineFactor, lineSz*lineFactor

	// Natural height of the whole block: title + subtitle + the tallest column.
	titleH, subH := 0.0, 0.0
	if fc.Title != "" {
		titleH = titleLH
	}
	if fc.Subtitle != "" {
		subH = subLH + subGap
	}
	colNatural := 0.0
	for _, col := range fc.Columns {
		h := 0.0
		if col.Heading != "" {
			h += headLH
		}
		for _, dl := range col.Lines {
			if lineText(dl) != "" {
				h += lineLH
			}
		}
		if h > colNatural {
			colNatural = h
		}
	}
	natural := titleH + subH + colNatural
	availH := b.contentH()

	// Fit-or-center: shrink uniformly when the block would cross the cut line,
	// else center it vertically so short tags aren't top-heavy.
	startY := b.contentY()
	if natural > availH && natural > 0 {
		s := availH / natural
		titleSz *= s
		subSz *= s
		headSz *= s
		lineSz *= s
		titleLH *= s
		subLH *= s
		headLH *= s
		lineLH *= s
	} else if natural > 0 {
		startY = b.contentY() + (availH-natural)/2
	}

	// Image, vertically centered in the content box (offset approximates a
	// square icon — close enough for typical near-square logos).
	if hasImage {
		imgY := b.contentY()
		if off := (b.contentH() - imgWidthPt) / 2; off > 0 {
			imgY += off
		}
		ops = append(ops, Op{Kind: "draw_image", ImageID: fc.ImageID, X: f(imgX), Y: f(imgY), W: f(imgWidthPt)})
	}

	y := startY
	if fc.Title != "" {
		ops = append(ops, textOp(fc.Title, textX, y, textW, titleLH, "L", "B", titleSz, &Fit{MaxWidth: textW, MinSize: min(13.0, titleSz), Step: 1}))
		y += titleLH
	}
	if fc.Subtitle != "" {
		ops = append(ops, textOp(fc.Subtitle, textX, y, textW, subLH, "L", "B", subSz, &Fit{MaxWidth: textW, MinSize: min(10.0, subSz), Step: 1}))
		y += subLH + subGap
	}
	if n := len(fc.Columns); n > 0 {
		colW := (textW - float64(n-1)*colGap) / float64(n)
		for ci, col := range fc.Columns {
			cx := textX + float64(ci)*(colW+colGap)
			cy := y
			if col.Heading != "" {
				ops = append(ops, textOp(col.Heading, cx, cy, colW, headLH, "L", "B", headSz, &Fit{MaxWidth: colW, MinSize: min(6.0, headSz), Step: 0.5}))
				cy += headLH
			}
			for _, dl := range col.Lines {
				txt := lineText(dl)
				if txt == "" {
					continue
				}
				ops = append(ops, textOp(txt, cx, cy, colW, lineLH, "L", "", lineSz, &Fit{MaxWidth: colW, MinSize: min(5.0, lineSz), Step: 0.5}))
				cy += lineLH
			}
		}
	}

	// Free-placed images last, so a logo/stamp sits on top of the structured
	// content rather than behind it.
	ops = append(ops, placedImageOps(b, fc.Placed)...)
	return ops
}

// facesMode reports whether the generic faces renderer applies (vs the classic
// icon/name/class layout): an explicit "detailed" layout, a shared back face,
// or any per-row face / flat-detailed field. Single source of truth shared by
// buildDoc and buildDocFromArgs so the render path and the validation path
// can't disagree about which mode (and which icon requirement) is in effect.
func facesMode(rows []TagRow, opts Options) bool {
	if opts.Layout == "detailed" || opts.Back != nil {
		return true
	}
	for _, r := range rows {
		if r.Front != nil || r.Back != nil || r.Title != "" || r.Subtitle != "" || len(r.Lines) > 0 {
			return true
		}
	}
	return false
}

// buildDoc ports harness.buildDoc: given tag rows + the icon PNG (base64) +
// options, produce the full host.pdf Doc.
//
// Front pages lay tags out in normal grid order; back pages (back_mode "same")
// place each front-index tag at its column-reversed cell, optionally nudged by
// the registration offset. Rows beyond one sheet (8 cells) spill onto
// additional front/back sheet pairs, preserving the front→back pairing.
func buildDoc(rows []TagRow, images []Image, opts Options) Doc {
	layout := cardstock4x2()
	positions := layout.cellPositions()
	perSheet := layout.cellsPerSheet()

	imageSide := opts.ImageSide
	if imageSide == "" {
		imageSide = "left"
	}

	faces := facesMode(rows, opts)

	// Default back side (single source of truth — buildDocFromArgs no longer
	// pre-defaults): faces/detailed tags are single-sided unless a back face is
	// supplied (a separate back is the norm); classic tags mirror the front so
	// the name reads either way. NOTE: an explicit per-row or shared back face
	// is ALWAYS drawn — it overrides back_mode. back_mode only governs the
	// reversible front-mirror when no back face is given.
	backMode := opts.BackMode
	if backMode == "" {
		if faces {
			backMode = "blank"
		} else {
			backMode = "same"
		}
	}

	iconWidthIn := opts.IconWidthIn
	if iconWidthIn <= 0 {
		if faces {
			iconWidthIn = 1.0
		} else {
			iconWidthIn = 0.40
		}
	}
	iconWidthPt := inToPt(iconWidthIn)

	hasIcon := false
	for _, im := range images {
		if im.ID == imageID {
			hasIcon = true
			break
		}
	}

	// frontFace resolves a row's front face; flat Title/Subtitle/Lines map to a
	// single-column face using the shared "icon" image (when one was supplied).
	frontFace := func(t TagRow) Face {
		if t.Front != nil {
			return *t.Front
		}
		fc := Face{Title: t.Title, Subtitle: t.Subtitle, ImageSide: imageSide}
		if hasIcon {
			fc.ImageID = imageID
		}
		if len(t.Lines) > 0 {
			fc.Columns = []Column{{Lines: t.Lines}}
		}
		return fc
	}
	// backFace resolves a row's back face: per-row Back, else shared opts.Back,
	// else (reversible "same" mode) the front face mirrored, else none.
	backFace := func(t TagRow) (Face, bool) {
		if t.Back != nil {
			return *t.Back, true
		}
		if opts.Back != nil {
			return *opts.Back, true
		}
		if backMode == "same" {
			return frontFace(t), true
		}
		return Face{}, false
	}

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

			if faces {
				frontOps = append(frontOps, guideOps(fb, opts.FullGuides)...)
				frontOps = append(frontOps, renderFaceOps(fb, frontFace(t), iconWidthPt)...)
				if bf, ok := backFace(t); ok {
					bi := layout.backCellIndex(i)
					bx, by := positions[bi][0], positions[bi][1]
					bb := tagBox{x: bx + opts.BackOffsetX, y: by + opts.BackOffsetY, w: layout.tagW, h: layout.tagH}
					backOps = append(backOps, guideOps(bb, opts.FullGuides)...)
					backOps = append(backOps, renderFaceOps(bb, bf, iconWidthPt)...)
				}
			} else {
				frontOps = append(frontOps, guideOps(fb, opts.FullGuides)...)
				frontOps = append(frontOps, renderTagOps(fb, t, iconWidthPt)...)
				if backMode == "same" {
					bi := layout.backCellIndex(i)
					bx, by := positions[bi][0], positions[bi][1]
					bb := tagBox{x: bx + opts.BackOffsetX, y: by + opts.BackOffsetY, w: layout.tagW, h: layout.tagH}
					backOps = append(backOps, guideOps(bb, opts.FullGuides)...)
					backOps = append(backOps, renderTagOps(bb, t, iconWidthPt)...)
				}
			}
		}
		pages = append(pages, Page{Ops: frontOps})
		if len(backOps) > 0 {
			pages = append(pages, Page{Ops: backOps})
		}
	}
	if len(pages) == 0 {
		pages = append(pages, Page{Ops: []Op{}})
	}

	if len(images) == 0 {
		images = nil
	}
	return Doc{
		Defaults: &Defaults{Format: "Letter", Orientation: "portrait", Unit: "pt"},
		Metadata: &Metadata{
			Title:   "Name Tags",
			Author:  "Name Tag Generator",
			Subject: "Duplex Name Tags",
			Creator: "Minerva host.pdf",
		},
		Images: images,
		Pages:  pages,
	}
}

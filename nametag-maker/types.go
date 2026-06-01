package main

// Go structs for the host.pdf `Doc` request object (host_pdf_contract.md §4–§5).
//
// The capability `args` to host.pdf.generate ARE this Doc object itself —
// top-level defaults/metadata/images/pages — NOT wrapped in {"doc": …}.
//
// These are defined here (rather than imported from the sidecar) because the
// sidecar's equivalents live in its `package main` and are not importable.
// json tags match the contract field names EXACTLY. Pointer/omitempty is used
// for optional fields so the emitted request only carries keys the contract
// recognizes — the host validates strictly and rejects unknown keys.

// Doc is the whole declarative document submitted in one host.pdf.generate call.
type Doc struct {
	Defaults *Defaults `json:"defaults,omitempty"`
	Metadata *Metadata `json:"metadata,omitempty"`
	Images   []Image   `json:"images,omitempty"`
	Pages    []Page    `json:"pages"`
}

// Defaults are document-level page defaults (§4).
type Defaults struct {
	Format      string `json:"format,omitempty"`      // page size; v1 guarantees "Letter"
	Orientation string `json:"orientation,omitempty"` // "portrait" | "landscape"
	Unit        string `json:"unit,omitempty"`        // v1 guarantees "pt"
}

// Metadata maps to set_title/author/subject/creator (§4).
type Metadata struct {
	Title   string `json:"title,omitempty"`
	Author  string `json:"author,omitempty"`
	Subject string `json:"subject,omitempty"`
	Creator string `json:"creator,omitempty"`
}

// Image embeds an image's bytes once; ops reference it by id (§4).
type Image struct {
	ID       string `json:"id"`
	Format   string `json:"format"` // e.g. "png"
	BytesB64 string `json:"bytes_b64"`
}

// Page is an ordered op list drawn back-to-front (§4).
type Page struct {
	Format      string `json:"format,omitempty"`      // optional per-page override
	Orientation string `json:"orientation,omitempty"` // optional per-page override
	Ops         []Op   `json:"ops"`
}

// Op is a single drawing operation. Every op carries its own style — there is
// no sticky graphics state across ops (§5). A single struct covers all kinds;
// omitempty keeps each emitted op to just the fields its kind uses.
type Op struct {
	Kind string `json:"kind"`

	// draw_text
	Text  string `json:"text,omitempty"`
	Font  *Font  `json:"font,omitempty"`
	Align string `json:"align,omitempty"` // "L" | "C" | "R"
	Fit   *Fit   `json:"fit,omitempty"`

	// draw_image
	ImageID string `json:"image_id,omitempty"`
	// Angle rotates a draw_image about its center, degrees clockwise-positive
	// (host.pdf contract §draw_image). Omit / 0 = no rotation.
	Angle *float64 `json:"angle,omitempty"`

	// draw_line
	X1 *float64 `json:"x1,omitempty"`
	Y1 *float64 `json:"y1,omitempty"`
	X2 *float64 `json:"x2,omitempty"`
	Y2 *float64 `json:"y2,omitempty"`

	// shared rect/text/image geometry
	X *float64 `json:"x,omitempty"`
	Y *float64 `json:"y,omitempty"`
	W *float64 `json:"w,omitempty"`
	H *float64 `json:"h,omitempty"`

	// stroke width — draw_line uses "width"; draw_rect uses "stroke_width"
	Width       *float64 `json:"width,omitempty"`
	StrokeWidth *float64 `json:"stroke_width,omitempty"`

	// colors
	Color       *RGB `json:"color,omitempty"`        // draw_text / draw_line
	StrokeColor *RGB `json:"stroke_color,omitempty"` // draw_rect
	FillColor   *RGB `json:"fill_color,omitempty"`   // draw_rect (style includes "F")

	// draw_rect
	Style string `json:"style,omitempty"` // "D" | "F" | "DF"
}

// Font names the inline font for a draw_text op (§4 — no handle, no doc-level
// table). Only (DejaVuSans, "") and (DejaVuSans, "B") are guaranteed in v1.
type Font struct {
	Family string  `json:"family"`
	Style  string  `json:"style"` // "" regular | "B" bold
	Size   float64 `json:"size"`
}

// Fit is the optional auto-shrink block on draw_text (§5). The sidecar
// shrinks font.size until the measured text width ≤ MaxWidth, stopping at
// MinSize. This replaces the original's get_string_width loop and keeps the
// font metrics that *choose* the size identical to those that *draw* it.
type Fit struct {
	MaxWidth float64 `json:"max_width"`
	MinSize  float64 `json:"min_size"`
	Step     float64 `json:"step,omitempty"`
}

// RGB is an [r,g,b] color, integers 0–255 (§2). It marshals as a 3-element
// JSON array to match the contract's "color": [r, g, b] shape.
type RGB [3]int

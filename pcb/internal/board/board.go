// Package board defines the canonical PCB board-source contract for the PCB
// plugin migration. This is the schema every downstream child consumes — the
// Python geometry worker, the gerber exporter, and the panel port. Durability
// of this contract matters more than feature breadth: field names are explicit
// and unit-suffixed (_mm / _deg) so no consumer has to guess units, and unknown
// fields survive round-trips instead of being silently dropped.
//
// # Three source dialects
//
// This model reconciles three pre-existing dialects (see docs/board-yaml.md for
// the full mapping table):
//
//   - Legacy .minpcb JSON — the in-tree Godot editor's PCBData.to_dict() shape
//     (board_name, board_width, components as an id→object map, nets with
//     {component_id, pin_name} pins, traces with waypoints, inline annotations
//     and route_hints maps). Imported via minpcb.go.
//   - PCBData.to_yaml() — the in-tree one-way YAML emitter (board:{name,width},
//     components:[{id,position:[x,y]}]). Field naming aligned where sane.
//   - pcb-architect YAML — the external toolchain format documented in the
//     pcb-maker skill (name, outline:{width,height}, components with
//     footprint/position/rotation, nets with "U1.VCC" pin refs, constraints).
//
// Where the dialects conflict, this contract prefers explicit, unit-tagged
// names (a superset choice, documented in board-yaml.md): e.g. canonical
// `width_mm` unifies legacy `board_width` and pcb-architect `outline.width`;
// canonical `ref` unifies the reference designator that both dialects call
// `id`. Net pins use the pcb-architect "U1.1" string form (flat, gerber- and
// diff-friendly) rather than the legacy {component_id, pin_name} object form.
//
// # Opaque passthrough
//
// Annotations and RouteHints are carried as opaque blobs ([]Blob). This
// contract transports them losslessly but does NOT interpret their semantics —
// the annotation-migration child owns that. Any struct in this package also
// carries an `Extra` inline map that captures unmodeled fields so a newer
// producer can add fields an older consumer preserves rather than drops.
package board

// Blob is an opaque, uninterpreted map. Used for Annotations and RouteHints,
// which this contract carries losslessly but does not model. Downstream
// children own their semantics.
type Blob = map[string]interface{}

// Board is the root of the canonical board-source contract.
//
// Marshaling is deterministic: struct fields emit in declaration order and
// yaml.v3 sorts inline/map keys, so a given Board always produces byte-identical
// YAML. That determinism is why this is the pcb.serialize payload format.
type Board struct {
	Version int `json:"version" yaml:"version"`
	// ID is the persistent, mint-once board identity (schema v2+). It is an
	// opaque token ("board:<hex>") assigned exactly once by the v1→v2 migration
	// and never recomputed — unlike a content hash it survives edits to the
	// board's name or geometry, which is the whole point: identity-dependent
	// consumers (DRC, routing) key off it and must not have the key move when a
	// user renames the board or reorders its children. Empty on a v1 board;
	// omitempty so a pre-migration board still round-trips byte-identically.
	// See docs/board-yaml.md "Persistent identity (v2)".
	ID          string      `json:"id,omitempty" yaml:"id,omitempty"`
	Name        string      `json:"name" yaml:"name"`
	WidthMM     float64     `json:"width_mm" yaml:"width_mm"`
	HeightMM    float64     `json:"height_mm" yaml:"height_mm"`
	GridMM      float64     `json:"grid_mm,omitempty" yaml:"grid_mm,omitempty"`
	Layers      []string    `json:"layers,omitempty" yaml:"layers,omitempty"`
	Origin      *Point      `json:"origin,omitempty" yaml:"origin,omitempty"`
	DesignRules DesignRules `json:"design_rules" yaml:"design_rules"`
	Components  []Component `json:"components" yaml:"components"`
	Nets        []Net       `json:"nets" yaml:"nets"`
	Traces      []Trace     `json:"traces,omitempty" yaml:"traces,omitempty"`
	Vias        []Via       `json:"vias,omitempty" yaml:"vias,omitempty"`

	// MountingHoles are board-level drilled holes not attached to a pad — the
	// mechanical mounting / non-plated holes the gerber exporter routes into
	// PTH.drl or NPTH.drl by their Plated flag. Formalises the field the gerber
	// spike carried through Extra (docket 019eb47ddebc, comment 508). The worker
	// additionally accepts `npth_holes` / `pth_holes` aliases via Extra
	// passthrough for producers that split the two lists (see docs/gerbers.md).
	MountingHoles []Hole `json:"mounting_holes,omitempty" yaml:"mounting_holes,omitempty"`

	// Annotations and RouteHints are opaque passthrough — carried losslessly,
	// never interpreted here.
	Annotations []Blob `json:"annotations,omitempty" yaml:"annotations,omitempty"`
	RouteHints  []Blob `json:"route_hints,omitempty" yaml:"route_hints,omitempty"`

	// Extra captures unmodeled top-level keys for lossless YAML round-trips
	// (forward compatibility). json:"-" keeps it out of the JSON board dict —
	// encoding/json has no inline support, so extras are a YAML-side durability
	// affordance only (documented in board-yaml.md).
	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

// Point is a 2D coordinate in board millimetres.
type Point struct {
	XMM float64 `json:"x_mm" yaml:"x_mm"`
	YMM float64 `json:"y_mm" yaml:"y_mm"`
}

// DesignRules holds board-wide manufacturing constraints. Unifies the
// pcb-architect `constraints` block. All fields omitempty so a board that omits
// rules serializes cleanly.
type DesignRules struct {
	ClearanceMM     float64 `json:"clearance_mm,omitempty" yaml:"clearance_mm,omitempty"`
	TraceWidthMM    float64 `json:"trace_width_mm,omitempty" yaml:"trace_width_mm,omitempty"`
	ViaDiameterMM   float64 `json:"via_diameter_mm,omitempty" yaml:"via_diameter_mm,omitempty"`
	ViaDrillMM      float64 `json:"via_drill_mm,omitempty" yaml:"via_drill_mm,omitempty"`
	DiffPairGapMM   float64 `json:"diff_pair_gap_mm,omitempty" yaml:"diff_pair_gap_mm,omitempty"`
	DiffPairWidthMM float64 `json:"diff_pair_width_mm,omitempty" yaml:"diff_pair_width_mm,omitempty"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

// Component is a placed part. Ref is the reference designator (legacy/
// pcb-architect `id`). Position is the footprint origin (pin-1 location,
// KiCAD convention) — NOT the geometric centre.
type Component struct {
	Ref         string  `json:"ref" yaml:"ref"`
	Footprint   string  `json:"footprint" yaml:"footprint"`
	Value       string  `json:"value,omitempty" yaml:"value,omitempty"`
	XMM         float64 `json:"x_mm" yaml:"x_mm"`
	YMM         float64 `json:"y_mm" yaml:"y_mm"`
	RotationDeg float64 `json:"rotation_deg" yaml:"rotation_deg"`
	Layer       string  `json:"layer,omitempty" yaml:"layer,omitempty"`
	Pins        []Pin   `json:"pins,omitempty" yaml:"pins,omitempty"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

// Pin is a component-relative pad location. Number is the pad identifier
// ("1", "A3"); Name is the optional symbolic name ("VCC", "GPIO8"). X/Y are
// offsets from the component origin.
//
// DrillMM / AnnulusDiameterMM / Plated formalise through-hole pad geometry the
// gerber spike carried through Extra (docket 019eb47ddebc, comment 508). A pin
// with DrillMM > 0 is a through-hole pad: it gets a copper annulus on every
// copper layer, a mask opening, and a drilled hole (plated unless Plated is
// explicitly false — Plated is a pointer so "unspecified" means plated).
//
// PadWidthMM / PadHeightMM formalise SMD pad geometry the same way (docket
// PLG board-load gap): an SMD pad (DrillMM == 0) carries an explicit rectangular
// copper size. These were previously parked in Extra (yaml inline) and so
// survived YAML round-trips but were dropped on JSON marshal (Extra is json:"-"),
// which silently lost SMD pad dimensions over the pcb.deserialize IPC reply.
// First-classing them keeps the JSON boundary lossless. A pad with neither drill
// nor pad_width/height is a bare positional pin.
//
// # Pin-geometry authority (schema v2, item 019f802ca3af / K2 review 627.1)
//
// The inline geometry fields (DrillMM, AnnulusDiameterMM, PadWidthMM,
// PadHeightMM, Plated) DUPLICATE what the locked footprint already defines, and
// a board that carries both (smart_remote does) forces every consumer to guess
// which wins. The v2 authority rule: the LOCKED FOOTPRINT is authoritative;
// these inline fields are DEPRECATED. A v2 board expresses an intentional
// deviation only through the explicit typed Override sub-struct below. The
// inline fields remain modeled (not deleted) so pre-migration v1 boards still
// round-trip losslessly.
//
// Authority is enforced by the Python v2 COMPILER (Round C), not by the Go
// identity migration: the fold — inline geometry that DIFFERS from the footprint
// becomes an Override, geometry that MATCHES is dropped — needs the resolved
// footprint, which lives in the worker. So the Go v1→v2 migration (Round B)
// bumps a board to v2 and mints ids but LEAVES inline geometry in place; a board
// can therefore be v2 and still carry inline fields until the compiler
// normalizes it. Round C's fold must run per-compile (not gated on the version)
// for exactly this reason.
type Pin struct {
	Number string  `json:"number" yaml:"number"`
	Name   string  `json:"name,omitempty" yaml:"name,omitempty"`
	XMM    float64 `json:"x_mm" yaml:"x_mm"`
	YMM    float64 `json:"y_mm" yaml:"y_mm"`

	// Override is the ONLY v2-sanctioned way to deviate from the footprint's pad
	// geometry — an explicit, typed, intentional deviation. Nil (the common case)
	// means "use the footprint verbatim". omitempty keeps footprint-faithful pins
	// clean in YAML.
	Override *PinOverride `json:"override,omitempty" yaml:"override,omitempty"`

	// Deprecated inline geometry (schema v1). Authoritative source is the locked
	// footprint; use Override for intentional deviations. Retained for lossless
	// v1 round-trip and as the Round C compiler's fold input. Target end-state:
	// a fully-normalized v2 board carries none of these (only Override) — but the
	// Go identity migration does not strip them, so a freshly-migrated v2 board
	// may still have them until the compiler folds. See the type doc.
	DrillMM           float64 `json:"drill_mm,omitempty" yaml:"drill_mm,omitempty"`
	AnnulusDiameterMM float64 `json:"annulus_diameter_mm,omitempty" yaml:"annulus_diameter_mm,omitempty"`
	PadWidthMM        float64 `json:"pad_width_mm,omitempty" yaml:"pad_width_mm,omitempty"`
	PadHeightMM       float64 `json:"pad_height_mm,omitempty" yaml:"pad_height_mm,omitempty"`
	Plated            *bool   `json:"plated,omitempty" yaml:"plated,omitempty"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

// PinOverride is an intentional, typed per-pad deviation from the locked
// footprint's pad geometry (schema v2, item 019f802ca3af). It carries the same
// fabrication dimensions as the deprecated inline Pin fields, but its PRESENCE
// is the signal that the deviation is deliberate rather than a stale duplicate
// of the footprint. Every field is a pointer so "unset" (use the footprint's
// value for this dimension) is distinguishable from "explicitly zero"; omitempty
// keeps an override that touches one dimension from serializing the rest.
type PinOverride struct {
	DrillMM           *float64 `json:"drill_mm,omitempty" yaml:"drill_mm,omitempty"`
	AnnulusDiameterMM *float64 `json:"annulus_diameter_mm,omitempty" yaml:"annulus_diameter_mm,omitempty"`
	PadWidthMM        *float64 `json:"pad_width_mm,omitempty" yaml:"pad_width_mm,omitempty"`
	PadHeightMM       *float64 `json:"pad_height_mm,omitempty" yaml:"pad_height_mm,omitempty"`
	Plated            *bool    `json:"plated,omitempty" yaml:"plated,omitempty"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

// Hole is a board-level drilled hole not attached to a component pad (mounting
// / mechanical holes). DiameterMM is the finished drill size; Plated selects
// PTH vs NPTH output (default non-plated — mounting holes are typically NPTH).
//
// Plated is a plain bool (unlike Pin.Plated's tri-state pointer) because the
// default here IS false, so omitempty dropping a false on marshal is lossless.
// Deliberate asymmetry — do not "fix" one to match the other.
type Hole struct {
	// ID is the persistent, mint-once mounting-hole identity (schema v2+) — same
	// rationale as Trace.ID. Opaque token ("hole:<hex>"); empty on v1; omitempty.
	ID         string  `json:"id,omitempty" yaml:"id,omitempty"`
	XMM        float64 `json:"x_mm" yaml:"x_mm"`
	YMM        float64 `json:"y_mm" yaml:"y_mm"`
	DiameterMM float64 `json:"diameter_mm,omitempty" yaml:"diameter_mm,omitempty"`
	DrillMM    float64 `json:"drill_mm,omitempty" yaml:"drill_mm,omitempty"`
	Plated     bool    `json:"plated,omitempty" yaml:"plated,omitempty"`
	// AnnulusMM is the AUTHORED copper-ring diameter for a PLATED board hole
	// (finding 019f8dbb7104). The Python compiler fail-closes a plated hole without
	// it and both fab emitters emit exactly this ring — no invented copper. Absent
	// on an unplated hole. Modeled first-class (not Extra) so it is a documented,
	// known source key on both sides of the codec.
	AnnulusMM float64 `json:"annulus_mm,omitempty" yaml:"annulus_mm,omitempty"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

// Net is an electrical connection. Pins are "Ref.PadNumber" strings
// (e.g. "U1.1", "C3.2") — the flat pcb-architect form.
type Net struct {
	Name string   `json:"name" yaml:"name"`
	Pins []string `json:"pins" yaml:"pins"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

// Trace is a routed copper polyline. Points are the ordered waypoints; a trace
// with N points has N-1 segments. (The legacy model's `waypoints` map 1:1 onto
// Points.)
type Trace struct {
	// ID is the persistent, mint-once trace identity (schema v2+). Traces are
	// reorderable and insertable, so the pre-migration ordinal-derived id was
	// unstable (Sol K2 review, item 019f802ca3af): inserting a trace shifted
	// every later trace's ordinal and thus its id. A minted opaque token
	// ("trace:<hex>") is stable under reorder/insert AND under editing this
	// trace's own Points. Empty on a v1 board; omitempty for lossless round-trip.
	ID      string  `json:"id,omitempty" yaml:"id,omitempty"`
	Net     string  `json:"net" yaml:"net"`
	Layer   string  `json:"layer,omitempty" yaml:"layer,omitempty"`
	WidthMM float64 `json:"width_mm,omitempty" yaml:"width_mm,omitempty"`
	Points  []Point `json:"points" yaml:"points"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

// Via is a layer-transition plated hole.
type Via struct {
	// ID is the persistent, mint-once via identity (schema v2+) — same rationale
	// as Trace.ID: vias are reorderable, so the ordinal-derived id was unstable.
	// Opaque token ("via:<hex>"); empty on v1; omitempty for lossless round-trip.
	ID         string  `json:"id,omitempty" yaml:"id,omitempty"`
	XMM        float64 `json:"x_mm" yaml:"x_mm"`
	YMM        float64 `json:"y_mm" yaml:"y_mm"`
	DrillMM    float64 `json:"drill_mm,omitempty" yaml:"drill_mm,omitempty"`
	DiameterMM float64 `json:"diameter_mm,omitempty" yaml:"diameter_mm,omitempty"`
	Net        string  `json:"net,omitempty" yaml:"net,omitempty"`
	FromLayer  string  `json:"from_layer,omitempty" yaml:"from_layer,omitempty"`
	ToLayer    string  `json:"to_layer,omitempty" yaml:"to_layer,omitempty"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

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
// LibraryLockEntry is one pinned footprint: the content the board consumed and
// enough provenance to reacquire or explain it.
//
// SHA256 is the identity and the only field that decides pass/fail. Layer and
// Source are PROVENANCE — they make a mismatch actionable ("the seed supplied
// this, your user layer now overrides it") but never adjudicate, because a
// board that refused on a changed layer NAME would break the moment someone
// reorganised their libraries without touching a byte of copper.
type LibraryLockEntry struct {
	SHA256 string `json:"sha256" yaml:"sha256"`
	// Layer that supplied the bytes when the lock was taken.
	Layer string `json:"layer,omitempty" yaml:"layer,omitempty"`
	// Where the content can be reacquired from, when it is not local.
	Source string `json:"source,omitempty" yaml:"source,omitempty"`
}

// Board.FabricationStage tokens. See the field's own comment for what they
// mean and why an unknown one is refused rather than defaulted.
const (
	FabStageRouted          = "routed"
	FabStageRoutingDeferred = "routing_deferred"
	FabStageViasOnly        = "vias_only"
)

// RoutingIsDeferred reports whether this board's declared stage says its nets
// are meant to be unrouted for now. The ONE predicate behind that question, so
// adding a future deferred stage cannot leave one consumer judging by an
// out-of-date list of tokens. Its Python mirror is drc.routing_is_deferred.
func (b *Board) RoutingIsDeferred() bool {
	return b.FabricationStage == FabStageRoutingDeferred ||
		b.FabricationStage == FabStageViasOnly
}

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
	ID       string  `json:"id,omitempty" yaml:"id,omitempty"`
	Name     string  `json:"name" yaml:"name"`
	WidthMM  float64 `json:"width_mm" yaml:"width_mm"`
	HeightMM float64 `json:"height_mm" yaml:"height_mm"`
	GridMM   float64 `json:"grid_mm,omitempty" yaml:"grid_mm,omitempty"`

	// Layers is the OPTIONAL copper stack, and its ORDER *IS* the physical
	// stack order: "top" first, "bottom" last, inner layers "in1".."in30" in
	// index order between them (KiCad F.Cu / In<k>.Cu / B.Cu — the canon↔KiCad
	// mapping lives in worker/agent_router/layers.py and its GDScript mirror).
	// Nothing in this codec sorts or dedupes the list, so what an author writes
	// is what every consumer sees; validateLayers enforces the shape.
	//
	// Inner layers are AUTHORABLE AND FABRICABLE as of epoch GA. This comment
	// previously said they were not, and cited compile_board._require_two_layer
	// as the refusal — a symbol that no longer exists (GA-1/GA-3 shipped the
	// N-layer model, router, per-layer DRC and emission). A board that declares
	// NO layers is a 2-layer board by convention; this contract does not invent
	// a stack for it.
	// See docs/board-yaml.md "Layer stack".
	Layers []string `json:"layers,omitempty" yaml:"layers,omitempty"`

	// FabricationStage is the board's DECLARED manufacturing intent, and it
	// exists so an incomplete board can say it is incomplete ON PURPOSE
	// (DCR 01a0033a12a9 change 3).
	//
	// THE PROBLEM IT SOLVES. A via-only board has every net unrouted BY DESIGN:
	// fiber-laser users cannot drill, so they order a drilled, plated board with
	// no copper runs and lase the traces themselves in a second step. The
	// connectivity census reports each of those nets as missing_copper, so the
	// customer's CORRECT board reads as a wall of incompleteness and there is no
	// way to tell it apart from a job someone abandoned half-routed.
	//
	// A DECLARATION, NOT A SUPPRESSION. Nothing here turns a check off — every
	// unrouted and fragmented net is still computed and still listed, and the
	// stage rides beside them in every reply that carries a completeness
	// verdict. What changes is only whether "not routed" counts as a DEFECT,
	// which is a question about intent that only the board can answer. Muting
	// checks hides real defects; stating what the board IS does not.
	//
	// VALUES (validateFabricationStage owns the refusal):
	//   ""                  same as "routed" — every existing board, unchanged.
	//   "routed"            the board is meant to be fully routed. Today's
	//                       behaviour exactly.
	//   "routing_deferred"  routing happens in a later step; some copper may
	//                       already exist. Unrouted nets are intended.
	//   "vias_only"         drilled and plated, no copper runs intended at all.
	//                       A STRICT subset of routing_deferred: a board that
	//                       declares it and carries traces is refused, because
	//                       the declaration would be false. That refusal is what
	//                       keeps the two values from being synonyms.
	//
	// omitempty so a board that never declares a stage round-trips
	// byte-identically and no existing golden moves.
	FabricationStage string `json:"fabrication_stage,omitempty" yaml:"fabrication_stage,omitempty"`

	Origin      *Point      `json:"origin,omitempty" yaml:"origin,omitempty"`
	DesignRules DesignRules `json:"design_rules" yaml:"design_rules"`

	// LibraryLock pins the exact library CONTENT this board consumed, keyed by
	// footprint ref (acceptance check K20, DCR 019ffc52c358).
	//
	// WHY A NAME IS NOT ENOUGH. Component.Footprint is a NAME, and since the
	// library became layered (epoch LIB1/LIB2) a user layer may legitimately
	// override a seed footprint with different geometry under the same name.
	// That is a feature — it is how a user fixes a bad seed part — but it means
	// a board rebuilt months later can resolve the same names to DIFFERENT
	// copper without anything saying so. This block is what makes that
	// detectable: it records what the board actually consumed, so a rebuild
	// either reproduces it or REFUSES BY NAME.
	//
	// SCOPED TO WHAT THE BOARD USES, deliberately. Only refs this board
	// resolves appear here, so an unrelated library change cannot invalidate
	// it — the failure mode of a whole-chain digest, which goes red when
	// anything anywhere moves and teaches everyone to regenerate it unread.
	//
	// OPTIONAL AND OMITEMPTY: a board without this block compiles exactly as
	// before. Locking is something a board GAINS, never a precondition, so no
	// existing board is invalidated by this field's introduction.
	LibraryLock map[string]LibraryLockEntry `json:"library_lock,omitempty" yaml:"library_lock,omitempty"`
	Components  []Component                 `json:"components" yaml:"components"`
	Nets        []Net                       `json:"nets" yaml:"nets"`
	Traces      []Trace                     `json:"traces,omitempty" yaml:"traces,omitempty"`
	Vias        []Via                       `json:"vias,omitempty" yaml:"vias,omitempty"`

	// Zones are authored copper-pour or keepout regions. They round-trip here and
	// compile into ResolvedZone entries. The final compile pass computes a solid
	// pour fill (or fails closed); Gerber/KiCad emit it, geometric DRC checks it,
	// and routing treats keepouts as polygon obstacles. See docs/board-yaml.md for
	// the deliberately conservative limits (thermal relief and keepout net scope).
	// See docs/board-yaml.md "Zones".
	Zones []Zone `json:"zones,omitempty" yaml:"zones,omitempty"`

	// Cutouts are authored openings THROUGH the whole board — an internal slot
	// or window milled out of the substrate (docket 019fb92108 campaign 2,
	// epoch B). They round-trip here and compile into ProfileOutline.cutouts.
	// Both fab emitters draw every opening as a closed Edge.Cuts contour;
	// geometric DRC, routing, and zone fill use the same cutout geometry. The
	// compiler validates that contours are strictly interior, simple, nonzero,
	// and conservatively disjoint before any consumer sees them.
	Cutouts []Cutout `json:"cutouts,omitempty" yaml:"cutouts,omitempty"`

	// MountingHoles are board-level drilled holes not attached to a pad — the
	// mechanical mounting / non-plated holes the gerber exporter routes into
	// PTH.drl or NPTH.drl by their Plated flag. Formalises the field the gerber
	// spike carried through Extra (docket 019eb47ddebc, comment 508).
	MountingHoles []Hole `json:"mounting_holes,omitempty" yaml:"mounting_holes,omitempty"`

	// PTHHoles / NPTHHoles are producer INPUT aliases that pre-split plating. They
	// are NORMALIZED into MountingHoles (Plated true / false) at every parse
	// boundary (NormalizeHoles) — modeled first-class ONLY so a v2 source can't ship
	// id-less / null holes through Extra that bypass id-minting + structural
	// validation (finding 019f8b7fb07e comment 689). After normalization they are
	// empty, so a board always round-trips as canonical `mounting_holes`.
	PTHHoles  []Hole `json:"pth_holes,omitempty" yaml:"pth_holes,omitempty"`
	NPTHHoles []Hole `json:"npth_holes,omitempty" yaml:"npth_holes,omitempty"`

	// BoardGraphics is artwork owned by the BOARD rather than by a component:
	// silk legend (a copyright line, a board name, a polarity mark) and
	// courtyard documentation.
	//
	// WHY IT HAD TO BE TYPED. Before this field, a top-level `board_graphics:`
	// key rode Board.Extra — it survived a round trip, but it was invisible to
	// id minting, to the entity-list probe, and to Validate. The consequence was
	// not theoretical: smart-remote-v2's back-side copyright line is 65 B.SilkS
	// polylines hung off TP1, a test point, in absolute board coordinates,
	// because the board had no legal owner for them and a component did. An
	// untyped ride-along would have kept it that way.
	//
	// A `text` graphic stores WHAT IT SAYS, not its strokes — the worker's font
	// derives those on every compile (worker/pcb_worker/board_graphics.py). That
	// is why this struct has no geometry field for text: there is nothing to
	// carry, and a baked copy is a copy that goes stale.
	//
	// omitempty so a board without artwork round-trips byte-identically.
	BoardGraphics []Graphic `json:"board_graphics,omitempty" yaml:"board_graphics,omitempty"`

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

	// Zone-fill minima — the two rules that decide what a pour fill may keep
	// (see "Zone minima" in docs/board-yaml.md). Typed rather than left to
	// Extra because Validate judges them.
	//
	// POINTERS, unlike the plain float64s above, because "unset" and an
	// authored value are different states here. Nil means the compiler derives
	// the default (the profile's min_trace_width_mm; the area of one default
	// via land). An authored 0 is a stated policy — legal for the island area
	// ("cull no island by size"), refused for the thickness (a pour with no
	// minimum width is a missing rule, not a rule). A plain float64 would
	// collapse the two states, and omitempty would drop an authored 0 on
	// marshal.
	//
	// Ranges are enforced by Validate; the VALUE TYPE is enforced at unmarshal
	// (probeDesignRules) so a mistyped value carries the shared code instead of
	// yaml.v3's native decode error.
	ZoneMinThicknessMM   *float64 `json:"zone_min_thickness_mm,omitempty" yaml:"zone_min_thickness_mm,omitempty"`
	ZoneMinIslandAreaMM2 *float64 `json:"zone_min_island_area_mm2,omitempty" yaml:"zone_min_island_area_mm2,omitempty"`

	// The board's ROUTING-DIRECTION constraint: the trace directions, in
	// degrees, this board's copper may run at. BOARD state, not rule-profile
	// state — no board house requires orthogonal routing; the routing style is
	// the author's choice. The worker's compiler folds each entry into [0, 180)
	// (a direction and its reverse are one constraint) and the geometric DRC
	// checks every trace segment against the result.
	//
	// Typed rather than left riding in Extra: a SEMANTIC field a consumer
	// branches on deserves a home in the struct, the same reason the zone-fill
	// minima above were promoted.
	//
	// A POINTER, for the same reason those minima are pointers: "unset" and an
	// authored value are DIFFERENT STATES here, and the difference is
	// load-bearing. Free routing is spelled by the key's ABSENCE, while an
	// authored EMPTY LIST is malformed and the worker's compiler refuses the
	// board for it (bad_trace_angles — see docs/board-yaml.md "Trace angles"),
	// precisely so a board that asks for a direction constraint cannot silently
	// get none. A plain []float64 with omitempty would collapse the two: an
	// authored `[]` would marshal back out as an absent key, turning that
	// refusal into free routing — the invisible fail-open the rule exists to
	// prevent. Nil omits the key; a non-nil empty slice round-trips as `[]` and
	// stays refusable downstream.
	AllowedTraceAnglesDeg *[]float64 `json:"allowed_trace_angles_deg,omitempty" yaml:"allowed_trace_angles_deg,omitempty"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

// Component is a placed part. Ref is the reference designator (legacy/
// pcb-architect `id`). Position is the footprint's OWN origin — the datum the
// `.kicad_mod` places its pads relative to, applied verbatim by the compiler's
// PlacementTransform — NOT the geometric centre and NOT necessarily pin 1. It
// coincides with pin 1 only in footprints authored that way (most through-hole
// connectors and DIPs); KiCad's SMD chip footprints put it at the body centre.
// See docs/board-yaml.md "Where x_mm / y_mm actually put a footprint".
type Component struct {
	Ref         string  `json:"ref" yaml:"ref"`
	Footprint   string  `json:"footprint" yaml:"footprint"`
	Value       string  `json:"value,omitempty" yaml:"value,omitempty"`
	XMM         float64 `json:"x_mm" yaml:"x_mm"`
	YMM         float64 `json:"y_mm" yaml:"y_mm"`
	RotationDeg float64 `json:"rotation_deg" yaml:"rotation_deg"`
	Layer       string  `json:"layer,omitempty" yaml:"layer,omitempty"`
	Pins        []Pin   `json:"pins,omitempty" yaml:"pins,omitempty"`

	// Assembly is what an assembly house has to buy and place for this
	// component: populate/DNP, part identity, house catalogue numbers, paste
	// policy, and the authored designators of any synthetic expansion. Nil
	// means nothing was authored, which is "populated, identity unstated" —
	// the state every board that predates the block is in.
	//
	// The field was originally a bare string carrying the single token
	// "exclude" (board furniture: fiducials, silk logos). That scalar is still
	// accepted and MIGRATED at decode into the structured non-populated state,
	// so only one shape reaches any reader. See assembly.go.
	Assembly *ComponentAssembly `json:"assembly,omitempty" yaml:"assembly,omitempty"`

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
// NormalizeHoles folds the pth_holes / npth_holes producer INPUT aliases into the
// single canonical MountingHoles collection (Plated set from the alias key), then
// clears them — so a board carries exactly ONE hole collection that id-minting,
// Validate, and the raw null-probe already cover uniformly, and a v2 source can no
// longer smuggle id-less / null holes through the aliases (finding 019f8b7fb07e
// comment 689). Idempotent: a board with no aliases is unchanged. Order preserves
// the historical mounting → npth → pth fabrication sequence. Called at the canonical
// ingest boundaries (UnmarshalYAML, the serialize board decode) so a board is
// canonical before migration / validation. (ImportMinpcb maps only its known
// fields; a legacy .minpcb's holes ride through Extra as v1 and fold on the next
// canonical re-ingest.) The alias key is AUTHORITATIVE for plating — an explicit
// `plated` on an alias hole is overridden by the key (Fable D2), matching the
// worker's compile_board / gerber so the two paths cannot diverge on the flag.
func NormalizeHoles(b *Board) {
	if len(b.NPTHHoles) == 0 && len(b.PTHHoles) == 0 {
		return
	}
	for i := range b.NPTHHoles {
		h := b.NPTHHoles[i]
		h.Plated = false // the npth alias key IS the (non-)plating declaration
		b.MountingHoles = append(b.MountingHoles, h)
	}
	for i := range b.PTHHoles {
		h := b.PTHHoles[i]
		h.Plated = true // the pth alias key IS the plating declaration
		b.MountingHoles = append(b.MountingHoles, h)
	}
	b.PTHHoles = nil
	b.NPTHHoles = nil
}

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
	// Tented authors the via's solder-mask tenting (finding 019f8fe7cbaf). A pointer
	// so "unset" (nil → DEFAULT TENTED, the historical CAM behavior) is distinct from
	// an explicit `tented: false` (untented — the via annulus is exposed). The Python
	// compiler reads it (default true) into ResolvedVia.tented_front/back.
	Tented *bool `json:"tented,omitempty" yaml:"tented,omitempty"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

// Zone is an authored region on a single layer: either a copper fill tied to one
// net — most commonly a ground or power pour — or a keepout, a KiCad-style rule
// area that forbids copper and needs no net at all (see Kind and Net below).
// It carries the AUTHORED outline only; the Python compiler computes the actual
// pour after pads, traces, holes, cutouts, and keepouts exist. This mirrors the
// IR's split between ResolvedZone.authored_outline and .fill. See
// docs/board-yaml.md "Zones" for the fill and refusal rules.
//
// Field-naming choices: Net/Layer match Trace.Net/Trace.Layer. ClearanceMM
// matches DesignRules.ClearanceMM (this file) and the Python IR's
// ResolvedZone.clearance_mm. ThermalGapMM / ThermalBridgeWidthMM match the
// Python IR's ThermalSettings.gap_mm / .bridge_width_mm (same file), with a
// `thermal_` prefix added because this struct stays FLAT like Trace/Via/Hole
// rather than nesting a sub-struct the way Python's ThermalSettings does —
// no other top-level board entity in this contract nests a settings sub-struct
// for its own fields (PinOverride nests because it needs pointer semantics to
// distinguish "unset" from "explicit zero"; that distinction is not asked for
// here, so the flat, omitempty-float64 idiom used throughout Trace/Via/Hole/
// DesignRules applies instead).
type Zone struct {
	// ID is the persistent, mint-once zone identity (schema v2+) — same
	// rationale as Trace.ID: zones are reorderable, so an ordinal-derived id
	// would be unstable. Opaque token ("zone:<hex>"); empty on v1; omitempty
	// for lossless round-trip. docs/board-yaml.md already reserved the "zone"
	// id kind for this before a Zone struct existed.
	ID string `json:"id,omitempty" yaml:"id,omitempty"`
	// Kind is what this region IS: a copper pour ("copper_pour", the default) or
	// a KiCad-style rule area that forbids copper ("keepout"). Empty means
	// copper_pour — the historical shape, so every board authored before this
	// field existed keeps its meaning. Validate accepts only "", "copper_pour"
	// and "keepout", canonical lowercase (invalid_zone_kind); the UI's
	// PCBData.zone_kind() normalises case before it ever reaches here, so a
	// stray "Keepout" in hand-written source is a typo worth reporting rather
	// than a spelling to silently accept.
	//
	// FIRST-CLASS, not Extra (owner ruling 2026-07-30, docket 019fb5ad6d20).
	// Kind now DECIDES the net requirement below, and a rule that branches on a
	// value cannot read it out of the forward-compat junk drawer: Extra is
	// json:"-" and only reaches JSON through the inline marshalers in json.go,
	// which by design let a modeled key win — so a validator reading
	// Extra["kind"] would be reading a key the codec is entitled to drop. A
	// modeled field also means knownJSONKeys() claims "kind", so splitExtra
	// never parks it in Extra and mergeExtra never re-emits it: exactly one
	// `kind` key on the wire, in YAML and JSON alike.
	Kind string `json:"kind,omitempty" yaml:"kind,omitempty"`
	// Layer is NOT omitempty: a zone with no stated layer is underspecified, not
	// merely terse, so Validate requires it non-empty and (when the board
	// declares a layer stack) a member of it.
	//
	// Net IS omitempty, and that asymmetry is the owner ruling above: a
	// copper_pour must name a declared net (Validate: zone_unknown_net), but a
	// keepout is a geometric prohibition, not copper, so it may name no net at
	// all — matching KiCad, where a rule area needs no net. omitempty is what
	// makes "no net" round-trip as an ABSENT key rather than as `net: ""`, a
	// value that reads like a net whose name is the empty string. A pour can
	// never hit it: Validate rejects a pour with an empty net, so the key is
	// omitted only for the case that is allowed to lack one. A keepout that DOES
	// name a net stays valid and stays checked — net-scoped keepouts remain
	// expressible, and the named net must still be declared.
	Net   string `json:"net,omitempty" yaml:"net,omitempty"`
	Layer string `json:"layer" yaml:"layer"`

	// ClearanceMM is this zone's copper clearance from foreign-net copper.
	// Zero/omitted defers to the board's blanket design_rules.clearance_mm.
	ClearanceMM float64 `json:"clearance_mm,omitempty" yaml:"clearance_mm,omitempty"`
	// ThermalGapMM is the copper gap left around a same-net pad that is NOT
	// thermally relieved; ThermalBridgeWidthMM is the spoke width connecting a
	// relieved pad to the pour. Zero/omitted selects the v1 solid-connect fill;
	// authoring thermal dimensions currently fails closed because thermal-spoke
	// geometry is not implemented. See docs/board-yaml.md "Zones".
	ThermalGapMM         float64 `json:"thermal_gap_mm,omitempty" yaml:"thermal_gap_mm,omitempty"`
	ThermalBridgeWidthMM float64 `json:"thermal_bridge_width_mm,omitempty" yaml:"thermal_bridge_width_mm,omitempty"`

	// Outline is the ordered polygon boundary the zone pours within. Unlike
	// Trace.Points (an open polyline), an outline describes a closed region,
	// so it needs at least 3 points to be a polygon at all; Validate rejects
	// fewer. Not omitempty, matching Trace.Points — a zone's geometry is core
	// content, not an optional extra.
	Outline []Point `json:"outline" yaml:"outline"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

// Cutout is an opening through the ENTIRE board — an internal slot or window
// milled out of the substrate. It is deliberately the SIMPLEST entity in this
// contract, and each absence below is a decision, not an oversight:
//
//   - No Layer. A cutout goes through every layer; "which layer" is the one
//     question a cutout cannot be asked. This is the whole reason it is a
//     separate entity from Zone rather than a third Zone.Kind — a keepout is a
//     per-layer prohibition on copper, a cutout is the absence of board.
//   - No Net. Nothing is connected to a hole in the substrate.
//   - No Kind. v1 has exactly one thing a cutout can be. A kind field with one
//     legal value teaches nothing and would have to be validated anyway.
//   - No circle/arc variant. The Python IR's Contour already admits arc
//     segments, so circles are a later WIDENING of Outline, not a competing
//     shape; and a round opening the fab will drill is already expressible as
//     a mounting hole (Hole carries diameter_mm). Two shape variants would
//     double the validator, the renderer, the hit-test and the MCP surface for
//     a case nothing needs yet. If circles are wanted later, PTHHoles /
//     NPTHHoles (NormalizeHoles) is the precedent: an input alias normalized
//     into the canonical form at every parse boundary.
//
// Validate checks STRUCTURE only (outline point count, minted+unique v2 id).
// It does NOT check that a cutout lies inside the board outline, that it avoids
// pads/traces/vias/zones, that it is non-self-intersecting, or that another
// cutout does not overlap it. That is not an oversight either: containment is a
// check class NOTHING in this contract has — neither Go nor Python bounds-checks
// a mounting hole or a zone — so adding it for cutouts alone would make a hole
// 3 mm off the board edge legal while a cutout there is not. Containment should
// arrive once, applied to holes+zones+cutouts together.
// Graphic is one piece of BOARD-LEVEL artwork — see Board.BoardGraphics.
//
// ONE STRUCT, SIX KINDS, and the geometry fields are a union discriminated by
// Kind rather than six structs behind an interface. That is deliberate: YAML and
// JSON both decode a flat mapping far more simply than a tagged union, every
// other entity in this codec is a flat struct, and the SEMANTIC validation that
// would justify the extra machinery ("a circle needs a radius") lives in the
// worker's compiler, which owns the font and the layer rule anyway. This codec's
// job is lossless carriage plus identity, and a flat struct does that.
//
// Kind is one of: text, line, circle, poly, polyline, rect.
//   - text            Text + Position + SizeMM + RotationDeg
//   - line            Start + End
//   - circle          Center + Radius
//   - poly            Points, CLOSED (>= 3)
//   - polyline        Points, OPEN (>= 2) — what a glyph stroke is
//   - rect            Start + End (opposite corners)
//
// Points are the canonical board-level {x_mm, y_mm} mapping, the same shape
// Trace.Points / Zone.Outline / Cutout.Outline use — NOT the bare [x, y] pair
// component graphics ride with. The worker's parser is strict about this for
// the same reason: one shape on both sides, or a board parses in one language
// and is refused in the other.
type Graphic struct {
	// ID is the persistent, mint-once graphic identity (schema v2+) — same
	// rationale as Zone.ID and Cutout.ID. Opaque token ("graphic:<32 hex>");
	// empty on v1; omitempty for lossless round-trip.
	ID string `json:"id,omitempty" yaml:"id,omitempty"`

	// Layer is a silk or courtyard layer ("F.SilkS", "B.SilkS", "F.CrtYd",
	// "B.CrtYd"). Copper and Edge.Cuts are refused by the worker's compiler,
	// not here: this codec does not own the layer vocabulary.
	//
	// Not omitempty. A graphic with no layer is not a terse graphic, it is a
	// broken one, and it must not serialize as if the field were optional —
	// the same reasoning as Zone.Layer.
	Layer string `json:"layer" yaml:"layer"`
	Kind  string `json:"kind" yaml:"kind"`

	// Width is the stroke width in mm. Omitempty: absent means "take the
	// silk default", which the worker resolves from silk_source's constants so
	// board legend and footprint legend cannot drift onto different floors.
	Width float64 `json:"width,omitempty" yaml:"width,omitempty"`

	// --- text ---
	Text        string  `json:"text,omitempty" yaml:"text,omitempty"`
	Position    *Point  `json:"position,omitempty" yaml:"position,omitempty"`
	SizeMM      float64 `json:"size_mm,omitempty" yaml:"size_mm,omitempty"`
	RotationDeg float64 `json:"rotation_deg,omitempty" yaml:"rotation_deg,omitempty"`
	// Mirror overrides the layer-derived mirroring of text glyphs. A POINTER
	// because unset and false are different states: unset means "derive from the
	// layer" (back-side text is mirror-written so it reads correctly through the
	// board), while an explicit false is a deliberate exception. A plain bool
	// would collapse the two and omitempty would drop an authored false.
	Mirror *bool `json:"mirror,omitempty" yaml:"mirror,omitempty"`

	// --- geometry ---
	Start  *Point  `json:"start,omitempty" yaml:"start,omitempty"`
	End    *Point  `json:"end,omitempty" yaml:"end,omitempty"`
	Center *Point  `json:"center,omitempty" yaml:"center,omitempty"`
	Radius float64 `json:"radius,omitempty" yaml:"radius,omitempty"`
	Points []Point `json:"points,omitempty" yaml:"points,omitempty"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

type Cutout struct {
	// ID is the persistent, mint-once cutout identity (schema v2+) — same
	// rationale as Trace.ID and Zone.ID: cutouts are reorderable, so an
	// ordinal-derived id would be unstable. Opaque token ("cutout:<32 hex>");
	// empty on v1; omitempty for lossless round-trip.
	ID string `json:"id,omitempty" yaml:"id,omitempty"`

	// Outline is the ordered polygon boundary of the opening. Like Zone.Outline
	// it describes a CLOSED region, so it needs at least 3 points to be a
	// polygon at all; Validate rejects fewer (invalid_cutout_outline). Not
	// omitempty, matching Zone.Outline and Trace.Points — the geometry IS the
	// entity here, not an optional extra, and a cutout with no outline is the
	// one shape that must never serialize as if it were merely terse.
	Outline []Point `json:"outline" yaml:"outline"`

	Extra map[string]interface{} `json:"-" yaml:",inline"`
}

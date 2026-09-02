// Package board — legacy .minpcb JSON importer.
//
// The in-tree Godot editor persists boards as .minpcb JSON produced by
// PCBData.to_dict() (Minerva src/Scripts/UI/Controls/PCBEditor/PCBData.gd).
// ImportMinpcb maps that shape onto the canonical Board model.
//
// Losslessness contract: no source field is silently dropped. Each field is
// either (a) mapped to a canonical field, (b) parked in a struct's inline
// Extra map so it round-trips into the emitted YAML, or (c) reported in the
// returned warnings slice. Fields that are known-legacy-but-non-canonical
// (render details like color, pads, local_bounds) are parked in Extra quietly;
// genuinely unrecognized fields are parked in Extra AND flagged as a warning so
// the surprise is visible.
package board

import (
	"encoding/json"
	"fmt"
	"sort"
)

// knownRootFields are the top-level keys ImportMinpcb explicitly understands.
// Anything else at the root is preserved in Board.Extra and warned about.
//
// MEMBERSHIP HERE IS A PROMISE, NOT A LABEL: this map is consulted ONLY as the
// skip-list of the passthrough loop below, so a key listed here with no import
// branch above is neither mapped NOR parked in Extra NOR warned — it is silently
// dropped. Every entry must therefore have a branch. (Parking a MODELED key in
// Extra instead is not an option either: mergeExtra lets the modeled field win,
// so the Extra copy vanishes on the next JSON marshal — that is exactly how the
// holes were lost in finding 019f8b7fb07e.)
var knownRootFields = map[string]bool{
	"version": true, "board_name": true, "board_width": true,
	"board_height": true, "grid_size": true, "layers": true,
	"components": true, "nets": true, "traces": true, "vias": true,
	"mounting_holes": true, "pth_holes": true, "npth_holes": true,
	"cutouts": true, "annotations": true, "route_hints": true,
}

// knownComponentFields are the per-component keys mapped or intentionally
// carried (render/geometry detail the canonical model does not surface). Keys
// outside this set are still preserved in Component.Extra but also warned.
var knownComponentFields = map[string]bool{
	"id": true, "footprint": true, "footprint_id": true, "position": true,
	"rotation": true, "layer": true, "pins": true, "pads": true, "value": true,
	"properties": true, "width": true, "height": true, "local_bounds": true,
	"has_pad_geometry": true, "bbox_center_offset": true, "color": true,
	"label_visible": true, "locked": true,
	// AUTHORED, and pointedly NOT in DerivedComponentKeys below: WHERE a human
	// or an agent SET this component's designator. It is board source like a
	// placement or a net, so it survives import, deserialize and the emitted
	// YAML untouched. See docs/board-yaml.md "The authored designator
	// placement".
	"refdes_placement": true,
	// DERIVED keys (DerivedComponentKeys below). A document carrying one is
	// stating a fact about the machine that resolved it, not board source —
	// pcb.deserialize drops them and re-derives. Warning on a key we are about
	// to delete would put one line of noise per component in front of the user
	// for something no author wrote and nobody can fix.
	"footprint_resolved": true, "refdes_anchor": true, "refdes_graphics": true,
}

// DerivedComponentKeys are per-component keys a RESOLVE derives, never
// something a board authors. They are preserved silently on import (above) and
// DROPPED at the deserialize boundary (internal/tools), so the only such keys a
// reply carries are the ones this host's own resolve just stamped.
//
//   - footprint_resolved: "a resolve succeeded against this library".
//   - refdes_anchor: WHERE the fab prints the designator, as THIS host's
//     resolve computed it — the board's own authored refdes_placement, else the
//     footprint's reference text, else its courtyard. A stale one saved by an
//     older resolve would outlive the rule that produced it, and the adoption is
//     absent-only, so it would win over the fresh value. The AUTHORED half
//     (refdes_placement) is the input to that computation and is never dropped:
//     dropping it would delete the only thing a person actually chose.
//   - refdes_graphics: a picture of one particular designator, written by
//     pre-anchor boards. It is a copy of a ref, so a component copied from
//     another carried the SOURCE's designator strokes and drew them forever
//     after; the renderer strokes the live ref at refdes_anchor now.
var DerivedComponentKeys = []string{
	"footprint_resolved", "refdes_anchor", "refdes_graphics",
}

// knownNetFields are the per-net keys mapped (name, pins) or intentionally
// carried in Extra (color, properties, is_power_net). Keys outside this set
// are still preserved in Net.Extra but also warned.
var knownNetFields = map[string]bool{
	"name": true, "pins": true, "color": true, "properties": true,
	"is_power_net": true,
}

// knownTraceFields are the per-trace keys mapped (net_name, waypoints, width,
// layer) or intentionally carried in Extra (id, locked). Keys outside this set
// are still preserved in Trace.Extra but also warned.
var knownTraceFields = map[string]bool{
	"id": true, "net_name": true, "waypoints": true, "width": true,
	"layer": true, "locked": true,
}

// ImportMinpcb parses the in-tree .minpcb JSON shape into a canonical Board.
// The returned warnings slice is non-empty when the source carried fields the
// importer did not recognize (all still preserved losslessly — never dropped).
func ImportMinpcb(data []byte) (*Board, []string, error) {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return nil, nil, fmt.Errorf("board: parse minpcb json: %w", err)
	}

	var warnings []string
	b := &Board{Version: 1}

	// --- scalar board fields ---
	getFloat(root, "board_width", &b.WidthMM)
	getFloat(root, "board_height", &b.HeightMM)
	getFloat(root, "grid_size", &b.GridMM)
	getString(root, "board_name", &b.Name)
	// A .minpcb's `version` is the legacy Godot editor's schema version, NOT the
	// canonical board-contract version — a different namespace. Any .minpcb is by
	// definition a pre-v2 source, so the canonical Version stays 1 here and the
	// v1→v2 identity migration mints its persistent ids at pcb.deserialize. (Were
	// we to trust a legacy file claiming `version: 2`, its ordinal-shaped ids
	// like "trace_1" would skip the mint and persist forever — item 019f802ca3af,
	// Fable Round B note.) The legacy value is consumed, not carried across.
	// FAIL CLOSED (docket 019fb5869f3f): a malformed `layers` used to be
	// silently discarded, leaving an empty stack — which then made
	// validateZones' declared-layer check skip entirely. A source that
	// declares layers it cannot parse is a refusal, same as components/nets.
	if v, ok := root["layers"]; ok {
		if err := json.Unmarshal(v, &b.Layers); err != nil {
			return nil, nil, fmt.Errorf("board: parse minpcb layers: %w", err)
		}
	}

	// --- components (id→object map → sorted slice) ---
	if raw, ok := root["components"]; ok {
		comps, w, err := importComponents(raw)
		if err != nil {
			return nil, nil, err
		}
		b.Components = comps
		warnings = append(warnings, w...)
	}

	// --- nets (name→object map → sorted slice) ---
	if raw, ok := root["nets"]; ok {
		nets, w, err := importNets(raw)
		if err != nil {
			return nil, nil, err
		}
		b.Nets = nets
		warnings = append(warnings, w...)
	}

	// --- traces (id→object map → sorted slice) ---
	if raw, ok := root["traces"]; ok {
		traces, w, err := importTraces(raw)
		if err != nil {
			return nil, nil, err
		}
		b.Traces = traces
		warnings = append(warnings, w...)
	}

	// --- vias (array of loosely-structured dicts) ---
	if raw, ok := root["vias"]; ok {
		vias, err := importVias(raw)
		if err != nil {
			return nil, nil, err
		}
		b.Vias = vias
	}

	// --- board-level holes: map into the TYPED collections, not Extra. A .minpcb's
	// holes were parked in Extra under mounting_holes/pth_holes/npth_holes, but those
	// are now modeled keys, so mergeExtra drops the Extra copy (modeled field wins) —
	// the holes vanished on the next JSON marshal (finding 019f8b7fb07e). NormalizeHoles
	// (below) then folds the aliases into the canonical MountingHoles.
	for _, hk := range []struct {
		key string
		dst *[]Hole
	}{{"mounting_holes", &b.MountingHoles}, {"pth_holes", &b.PTHHoles}, {"npth_holes", &b.NPTHHoles}} {
		if raw, ok := root[hk.key]; ok {
			// Decode via POINTERS so a JSON `null` array item is a nil element we
			// REJECT — not a zero-valued phantom hole (which NormalizeHoles would
			// fold and v1->v2 id-minting would mint, finding 019f8b7fb07e). This
			// JSON import bypasses UnmarshalYAML's null-item probe, so it must carry
			// the same fail-closed rule itself.
			var ptrs []*Hole
			if err := json.Unmarshal(raw, &ptrs); err != nil {
				return nil, nil, fmt.Errorf("board: parse minpcb %s: %w", hk.key, err)
			}
			holes := make([]Hole, 0, len(ptrs))
			for i, p := range ptrs {
				if p == nil {
					return nil, nil, fmt.Errorf(
						"board: import minpcb: invalid_board_structure: %s[%d] is a null item",
						hk.key, i)
				}
				holes = append(holes, *p)
			}
			*hk.dst = holes
		}
	}

	// --- cutouts: map into the TYPED collection, for the same reason the holes
	// above are. `cutouts` is a modeled key, so parking it in Extra would let
	// mergeExtra drop it on the next JSON marshal (finding 019f8b7fb07e), and
	// listing it in knownRootFields WITHOUT this branch would drop it outright.
	// Decoded through POINTERS so a JSON `null` item is rejected rather than
	// becoming a phantom outline-less cutout that v1->v2 minting would then mint
	// an id for — the same fail-closed rule UnmarshalYAML's null-item probe
	// applies on the YAML path, which this JSON import bypasses.
	if raw, ok := root["cutouts"]; ok {
		var ptrs []*Cutout
		if err := json.Unmarshal(raw, &ptrs); err != nil {
			return nil, nil, fmt.Errorf("board: parse minpcb cutouts: %w", err)
		}
		cutouts := make([]Cutout, 0, len(ptrs))
		for i, p := range ptrs {
			if p == nil {
				return nil, nil, fmt.Errorf(
					"board: import minpcb: invalid_board_structure: cutouts[%d] is a null item", i)
			}
			cutouts = append(cutouts, *p)
		}
		b.Cutouts = cutouts
	}

	// --- annotations / route_hints: opaque passthrough (id→object → []Blob) ---
	if raw, ok := root["annotations"]; ok {
		blobs, err := importBlobMap(raw)
		if err != nil {
			return nil, nil, fmt.Errorf("board: annotations: %w", err)
		}
		b.Annotations = blobs
	}
	if raw, ok := root["route_hints"]; ok {
		blobs, err := importBlobMap(raw)
		if err != nil {
			return nil, nil, fmt.Errorf("board: route_hints: %w", err)
		}
		b.RouteHints = blobs
	}

	// --- unknown top-level keys: preserve + warn ---
	for k, v := range root {
		if knownRootFields[k] {
			continue
		}
		if b.Extra == nil {
			b.Extra = map[string]interface{}{}
		}
		var val interface{}
		_ = json.Unmarshal(v, &val)
		b.Extra[k] = val
		warnings = append(warnings, fmt.Sprintf("non-canonical top-level field %q preserved as passthrough", k))
	}

	// Fold the pth_holes / npth_holes aliases into canonical mounting_holes so an
	// imported board carries ONE validated hole collection (finding 019f8b7fb07e).
	NormalizeHoles(b)
	return b, warnings, nil
}

func importComponents(raw json.RawMessage) ([]Component, []string, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, nil, fmt.Errorf("board: components: %w", err)
	}
	var warnings []string
	comps := make([]Component, 0, len(m))
	for _, id := range sortedKeys(m) {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(m[id], &obj); err != nil {
			return nil, nil, fmt.Errorf("board: component %q: %w", id, err)
		}
		c := Component{Ref: id}
		getString(obj, "id", &c.Ref) // prefer explicit id if present
		getString(obj, "footprint", &c.Footprint)
		getFloat(obj, "rotation", &c.RotationDeg)
		getString(obj, "layer", &c.Layer)
		getPoint(obj, "position", &c.XMM, &c.YMM)

		getString(obj, "value", &c.Value)

		// ONE HOME FOR THE COMPONENT VALUE, the same rule the YAML boundary
		// enforces. `properties` is parked in Extra verbatim, so a value hiding
		// there would be re-emitted into the canonical document beside the
		// `value` key and reintroduce the two-homes ambiguity by import.
		if pv, ok := obj["properties"]; ok {
			var props map[string]interface{}
			if json.Unmarshal(pv, &props) == nil {
				if _, dup := props["value"]; dup {
					return nil, nil, fmt.Errorf("board: component %q: properties.value "+
						"is not a home for the component value; delete it and author "+
						"the top-level \"value\" key", id)
				}
			}
		}

		// pins: {name -> {x,y}} → []Pin (sorted by pin key for determinism)
		if pv, ok := obj["pins"]; ok {
			pins, err := importPins(pv)
			if err != nil {
				return nil, nil, fmt.Errorf("board: component %q pins: %w", id, err)
			}
			c.Pins = pins
		}

		// preserve every other component field in Extra; warn on the unknown.
		for k, v := range obj {
			if k == "id" || k == "footprint" || k == "rotation" ||
				k == "layer" || k == "position" || k == "pins" || k == "value" {
				continue // already mapped
			}
			if c.Extra == nil {
				c.Extra = map[string]interface{}{}
			}
			var val interface{}
			_ = json.Unmarshal(v, &val)
			c.Extra[k] = val
			if !knownComponentFields[k] {
				warnings = append(warnings, fmt.Sprintf("component %q: non-canonical field %q preserved as passthrough", id, k))
			}
		}
		comps = append(comps, c)
	}
	return comps, warnings, nil
}

func importPins(raw json.RawMessage) ([]Pin, error) {
	var m map[string]struct {
		X float64 `json:"x"`
		Y float64 `json:"y"`
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, err
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	pins := make([]Pin, 0, len(m))
	for _, k := range keys {
		pins = append(pins, Pin{Number: k, XMM: m[k].X, YMM: m[k].Y})
	}
	return pins, nil
}

func importNets(raw json.RawMessage) ([]Net, []string, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, nil, fmt.Errorf("board: nets: %w", err)
	}
	var warnings []string
	nets := make([]Net, 0, len(m))
	for _, name := range sortedKeys(m) {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(m[name], &obj); err != nil {
			return nil, nil, fmt.Errorf("board: net %q: %w", name, err)
		}
		n := Net{Name: name}
		getString(obj, "name", &n.Name) // prefer explicit name if present

		// pins: [{component_id, pin_name}] → ["Ref.Pad"]
		if pv, ok := obj["pins"]; ok {
			var pins []struct {
				ComponentID string `json:"component_id"`
				PinName     string `json:"pin_name"`
			}
			if err := json.Unmarshal(pv, &pins); err != nil {
				return nil, nil, fmt.Errorf("board: net %q pins: %w", name, err)
			}
			for _, p := range pins {
				n.Pins = append(n.Pins, fmt.Sprintf("%s.%s", p.ComponentID, p.PinName))
			}
		}

		// preserve every other net field in Extra; warn on the unknown.
		for k, v := range obj {
			if k == "name" || k == "pins" {
				continue // already mapped
			}
			var val interface{}
			_ = json.Unmarshal(v, &val)
			ensureExtra(&n.Extra)[k] = val
			if !knownNetFields[k] {
				warnings = append(warnings, fmt.Sprintf("net %q: non-canonical field %q preserved as passthrough", name, k))
			}
		}
		nets = append(nets, n)
	}
	return nets, warnings, nil
}

func importTraces(raw json.RawMessage) ([]Trace, []string, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, nil, fmt.Errorf("board: traces: %w", err)
	}
	var warnings []string
	traces := make([]Trace, 0, len(m))
	for _, id := range sortedKeys(m) {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(m[id], &obj); err != nil {
			return nil, nil, fmt.Errorf("board: trace %q: %w", id, err)
		}
		t := Trace{}
		getString(obj, "net_name", &t.Net)
		getString(obj, "layer", &t.Layer)
		getFloat(obj, "width", &t.WidthMM)

		if wv, ok := obj["waypoints"]; ok {
			var wps []struct {
				X float64 `json:"x"`
				Y float64 `json:"y"`
			}
			if err := json.Unmarshal(wv, &wps); err != nil {
				return nil, nil, fmt.Errorf("board: trace %q waypoints: %w", id, err)
			}
			for _, wp := range wps {
				t.Points = append(t.Points, Point{XMM: wp.X, YMM: wp.Y})
			}
		}

		// Legacy trace id maps to the canonical ID field. Before schema v2 the
		// Trace struct had no id slot, so the importer parked the map key in
		// Extra["id"]; v2 models `id`, and a modeled field whose yaml name also
		// appears in an inline Extra map makes yaml.v3 panic on marshal
		// (item 019f802ca3af). The map key (always a non-empty string, from
		// sortedKeys) is the authoritative default; a string inner "id" field
		// overrides it. A non-string inner "id" is redundant with the map key
		// and is dropped — identity is never lost because the map key holds it.
		t.ID = id
		getString(obj, "id", &t.ID)

		// preserve every other trace field in Extra; warn on the unknown.
		for k, v := range obj {
			if k == "net_name" || k == "layer" || k == "width" || k == "waypoints" || k == "id" {
				continue // already mapped
			}
			var val interface{}
			_ = json.Unmarshal(v, &val)
			ensureExtra(&t.Extra)[k] = val
			if !knownTraceFields[k] {
				warnings = append(warnings, fmt.Sprintf("trace %q: non-canonical field %q preserved as passthrough", id, k))
			}
		}
		traces = append(traces, t)
	}
	return traces, warnings, nil
}

func importVias(raw json.RawMessage) ([]Via, error) {
	var arr []map[string]interface{}
	if err := json.Unmarshal(raw, &arr); err != nil {
		return nil, fmt.Errorf("board: vias: %w", err)
	}
	vias := make([]Via, 0, len(arr))
	for _, obj := range arr {
		v := Via{}
		if pos, ok := obj["position"].(map[string]interface{}); ok {
			v.XMM = toFloat(pos["x"])
			v.YMM = toFloat(pos["y"])
		}
		v.DrillMM = toFloat(obj["drill"])
		v.DiameterMM = toFloat(obj["size"])
		if s, ok := obj["net_name"].(string); ok {
			v.Net = s
		}
		// Legacy via id maps to the canonical ID field, not Extra — a modeled
		// field whose yaml name also sits in an inline Extra map panics yaml.v3
		// on marshal (item 019f802ca3af). A non-string legacy id is STRINGIFIED
		// rather than dropped: it cannot fall through to Extra (that re-creates
		// the collision), so preserving it here keeps the import lossless.
		if raw, ok := obj["id"]; ok {
			if s, ok := raw.(string); ok {
				v.ID = s
			} else {
				v.ID = fmt.Sprint(raw)
			}
		}
		// preserve anything else (layers, etc.) in Extra
		for k, val := range obj {
			if k == "position" || k == "drill" || k == "size" || k == "net_name" || k == "id" {
				continue
			}
			ensureExtra(&v.Extra)[k] = val
		}
		vias = append(vias, v)
	}
	return vias, nil
}

// importBlobMap converts a legacy id→object map into an ordered []Blob. Each
// blob is the object verbatim (opaque passthrough); the id is already present
// inside each object as its "id" field, so nothing is lost by flattening.
func importBlobMap(raw json.RawMessage) ([]Blob, error) {
	var m map[string]Blob
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, err
	}
	blobs := make([]Blob, 0, len(m))
	for _, k := range sortedBlobKeys(m) {
		blob := m[k]
		if _, ok := blob["id"]; !ok {
			blob["id"] = k // don't lose the map key if the object omits it
		}
		blobs = append(blobs, blob)
	}
	return blobs, nil
}

// ---- small helpers ----

func sortedKeys(m map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func sortedBlobKeys(m map[string]Blob) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func ensureExtra(e *map[string]interface{}) map[string]interface{} {
	if *e == nil {
		*e = map[string]interface{}{}
	}
	return *e
}

func getFloat(m map[string]json.RawMessage, key string, dst *float64) {
	if v, ok := m[key]; ok {
		_ = json.Unmarshal(v, dst)
	}
}

func getString(m map[string]json.RawMessage, key string, dst *string) {
	if v, ok := m[key]; ok {
		_ = json.Unmarshal(v, dst)
	}
}

func getPoint(m map[string]json.RawMessage, key string, x, y *float64) {
	if v, ok := m[key]; ok {
		var p struct {
			X float64 `json:"x"`
			Y float64 `json:"y"`
		}
		if json.Unmarshal(v, &p) == nil {
			*x, *y = p.X, p.Y
		}
	}
}

func toFloat(v interface{}) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	case json.Number:
		f, _ := n.Float64()
		return f
	}
	return 0
}

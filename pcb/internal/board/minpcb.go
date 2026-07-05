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
var knownRootFields = map[string]bool{
	"version": true, "board_name": true, "board_width": true,
	"board_height": true, "grid_size": true, "layers": true,
	"components": true, "nets": true, "traces": true, "vias": true,
	"annotations": true, "route_hints": true,
}

// knownComponentFields are the per-component keys mapped or intentionally
// carried (render/geometry detail the canonical model does not surface). Keys
// outside this set are still preserved in Component.Extra but also warned.
var knownComponentFields = map[string]bool{
	"id": true, "footprint": true, "footprint_id": true, "position": true,
	"rotation": true, "layer": true, "pins": true, "pads": true,
	"properties": true, "width": true, "height": true, "local_bounds": true,
	"has_pad_geometry": true, "bbox_center_offset": true, "color": true,
	"label_visible": true, "locked": true,
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
	if v, ok := root["version"]; ok {
		_ = json.Unmarshal(v, &b.Version)
	}
	if v, ok := root["layers"]; ok {
		_ = json.Unmarshal(v, &b.Layers)
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

		// value lives under properties.value in the legacy shape
		if pv, ok := obj["properties"]; ok {
			var props map[string]interface{}
			if json.Unmarshal(pv, &props) == nil {
				if val, ok := props["value"].(string); ok {
					c.Value = val
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
				k == "layer" || k == "position" || k == "pins" {
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

		// legacy trace id has no canonical slot: preserve the map key, letting
		// an explicit "id" field below override it.
		ensureExtra(&t.Extra)["id"] = id

		// preserve every other trace field in Extra; warn on the unknown.
		for k, v := range obj {
			if k == "net_name" || k == "layer" || k == "width" || k == "waypoints" {
				continue // already mapped
			}
			var val interface{}
			_ = json.Unmarshal(v, &val)
			t.Extra[k] = val
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
		// preserve anything else (layers, etc.) in Extra
		for k, val := range obj {
			if k == "position" || k == "drill" || k == "size" || k == "net_name" {
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

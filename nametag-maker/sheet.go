package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
)

// sheetMapping describes how spreadsheet columns map onto a tag's fields. The
// shape is fixed (so the host won't stringify it) — column NAMES are values.
type sheetMapping struct {
	Title    string `json:"title"`    // column → big bold name
	Subtitle string `json:"subtitle"` // column → subtitle line
	Lines    []struct {
		Label  string `json:"label"`  // fixed label printed before the value ("" = value only)
		Column string `json:"column"` // column → the value
	} `json:"lines"`
}

// buildFromSheetArgs is the input for nametag_build_from_sheet. The sheet rows
// arrive as a JSON STRING (rows_json) — the LLM reads the sheet via
// minerva_get_spreadsheet_data and passes the array verbatim. A string is immune
// to the host's nested-arg coercion, and the columns are arbitrary per use case.
type buildFromSheetArgs struct {
	RowsJSON  string       `json:"rows_json"`
	Mapping   sheetMapping `json:"mapping"`
	// BackMapping (optional) builds a DISTINCT per-row back face from columns —
	// same shape as Mapping. Each tag's back is derived from its own row (e.g.
	// the parent electives on the back of a student tag).
	BackMapping *sheetMapping `json:"back_mapping"`
	// SharedBack (optional) is one CONSTANT back face drawn behind EVERY tag —
	// the common case being a schedule (columns of lines, optionally per-day
	// headings). A per-row BackMapping back overrides it for that row.
	SharedBack *faceArgs `json:"shared_back"`
	// Image registry pass-through: the shared "icon" (icon_png_base64 | icon_path)
	// plus any extra named Images that faces/placements reference by id. Resolved
	// at render time by resolveImages, so they must reach the stored generate dict.
	IconPNGB64 string          `json:"icon_png_base64"`
	IconPath   string          `json:"icon_path"`
	Images     json.RawMessage `json:"images"`
	// FrontImages (optional) are free-placed images applied to EVERY tag's front
	// (e.g. a logo): position/size/rotation. Supplying them converts the flat
	// front into an explicit face carrying the placements.
	FrontImages      json.RawMessage `json:"front_images"`
	Layout           string          `json:"layout"`
	ImageSide        string    `json:"image_side"`
	BackMode         string    `json:"back_mode"`
	FullGuides       bool      `json:"full_guides"`
	IconWidthIn      float64   `json:"icon_width_in"`
	OutPath          string    `json:"out_path"`
	Title            string    `json:"title"`
	SheetRef         string    `json:"sheet_ref"`
	PreviewFirstOnly bool      `json:"preview_first_only"`
}

// mapRowToFace builds a structured face (title/subtitle + a single column of
// lines) for one sheet row from a column mapping. Empty values are omitted;
// returns nil when the row yields no back content at all (so a row missing all
// back data simply has no back face rather than a blank one). The returned map
// is faceArgs-shaped so buildDocFromArgs parses it as a layout.Face.
func mapRowToFace(r map[string]interface{}, m sheetMapping) map[string]interface{} {
	title := sheetCell(r, m.Title)
	subtitle := sheetCell(r, m.Subtitle)
	var lines []map[string]interface{}
	for _, ml := range m.Lines {
		val := sheetCell(r, ml.Column)
		if val == "" {
			continue
		}
		lines = append(lines, map[string]interface{}{"label": ml.Label, "value": val})
	}
	if title == "" && subtitle == "" && len(lines) == 0 {
		return nil
	}
	face := map[string]interface{}{}
	if title != "" {
		face["title"] = title
	}
	if subtitle != "" {
		face["subtitle"] = subtitle
	}
	if len(lines) > 0 {
		face["columns"] = []map[string]interface{}{{"lines": lines}}
	}
	return face
}

func orDefault(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}

// hasNonEmptyJSON reports whether a raw JSON value is present AND carries
// content — i.e. not absent, not null, and not an empty container/string.
// Crucially an empty array `[]` or object `{}` counts as ABSENT: the host
// stringifies undeclared optional args, and models routinely emit `[]` as the
// "unused" default for an array param, so treating `[]` as "present" silently
// flips behavior (e.g. forcing the explicit-face path and dropping the shared
// icon — the root cause fixed here). Whitespace variants like `[ ]` are handled
// by unmarshalling rather than a string compare.
func hasNonEmptyJSON(r json.RawMessage) bool {
	if len(r) == 0 {
		return false
	}
	var v interface{}
	if err := json.Unmarshal(r, &v); err != nil {
		return false
	}
	switch t := v.(type) {
	case nil:
		return false
	case string:
		return strings.TrimSpace(t) != ""
	case []interface{}:
		return len(t) > 0
	case map[string]interface{}:
		return len(t) > 0
	default:
		return true
	}
}

// sheetCell coerces a spreadsheet cell to a trimmed string. Numbers come back as
// float64 from JSON; whole numbers drop the ".0" so "Cabin 1" stays "Cabin 1".
func sheetCell(row map[string]interface{}, col string) string {
	if col == "" {
		return ""
	}
	v, ok := row[col]
	if !ok || v == nil {
		return ""
	}
	switch t := v.(type) {
	case string:
		return strings.TrimSpace(t)
	case float64:
		if t == float64(int64(t)) {
			return fmt.Sprintf("%d", int64(t))
		}
		return strings.TrimSpace(fmt.Sprintf("%g", t))
	case bool:
		return fmt.Sprintf("%v", t)
	default:
		return strings.TrimSpace(fmt.Sprintf("%v", t))
	}
}

// toolNametagBuildFromSheet is the deterministic "spreadsheet → .mtags" tool.
// The LLM reads the sheet (minerva_get_spreadsheet_data), passes the rows as
// rows_json plus a column mapping; this builds the generic-faces rows, renders a
// preview PDF (the first tag only when preview_first_only — the single-draft
// review; the .mtags still stores ALL rows), writes the preview PDF and the
// .mtags document to disk, and returns the .mtags path for the LLM to open.
func toolNametagBuildFromSheet(client capabilityCaller, rawArgs json.RawMessage) map[string]interface{} {
	var a buildFromSheetArgs
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &a); err != nil {
			return toolErr("schema_validation_failed", "parse args: "+err.Error())
		}
	}
	if strings.TrimSpace(a.OutPath) == "" {
		return toolErr("schema_validation_failed", "out_path is required (absolute .mtags destination)")
	}
	if strings.TrimSpace(a.RowsJSON) == "" {
		return toolErr("schema_validation_failed", "rows_json is required (a JSON array of sheet row objects)")
	}
	if strings.TrimSpace(a.Mapping.Title) == "" {
		return toolErr("schema_validation_failed", "mapping.title is required (the column holding the tag's name)")
	}

	var sheetRows []map[string]interface{}
	if err := json.Unmarshal([]byte(a.RowsJSON), &sheetRows); err != nil {
		return toolErr("schema_validation_failed", "rows_json is not a JSON array of objects: "+err.Error())
	}
	if len(sheetRows) == 0 {
		return toolErr("schema_validation_failed", "rows_json is empty")
	}

	// Map each sheet row onto a flat-detailed tag row (title/subtitle/lines).
	// Empty values are omitted so missing data simply drops that line.
	var tagRows []map[string]interface{}
	for _, r := range sheetRows {
		row := map[string]interface{}{
			"title":    sheetCell(r, a.Mapping.Title),
			"subtitle": sheetCell(r, a.Mapping.Subtitle),
		}
		var lines []map[string]interface{}
		for _, m := range a.Mapping.Lines {
			val := sheetCell(r, m.Column)
			if val == "" {
				continue
			}
			lines = append(lines, map[string]interface{}{"label": m.Label, "value": val})
		}
		if len(lines) > 0 {
			row["lines"] = lines
		}
		// Free-placed images on every front (e.g. a logo) turn the flat front into
		// an explicit face carrying the placements; the flat fields move into it.
		if hasNonEmptyJSON(a.FrontImages) {
			front := mapRowToFace(r, a.Mapping)
			if front == nil {
				front = map[string]interface{}{}
			}
			front["images"] = a.FrontImages
			row["front"] = front
			delete(row, "title")
			delete(row, "subtitle")
			delete(row, "lines")
		}
		// A distinct per-row back face (e.g. parent electives) from back_mapping.
		if a.BackMapping != nil {
			if back := mapRowToFace(r, *a.BackMapping); back != nil {
				row["back"] = back
			}
		}
		tagRows = append(tagRows, row)
	}

	// The generate sub-dict stored in the .mtags (and used to render).
	gen := map[string]interface{}{
		"layout":        orDefault(a.Layout, "detailed"),
		"image_side":    orDefault(a.ImageSide, "left"),
		"back_mode":     orDefault(a.BackMode, "blank"),
		"full_guides":   a.FullGuides,
		"icon_width_in": a.IconWidthIn,
		"rows":          tagRows,
	}
	// A shared constant back face (e.g. the schedule) drawn behind every tag.
	// buildDocFromArgs reads top-level `back` as Options.Back; a per-row back
	// face (set above) overrides it for that row.
	if a.SharedBack != nil {
		gen["back"] = a.SharedBack
	}
	// Image registry pass-through so resolveImages can register them at render
	// time (preview AND later re-renders from the stored .mtags generate dict).
	if strings.TrimSpace(a.IconPNGB64) != "" {
		gen["icon_png_base64"] = a.IconPNGB64
	}
	if strings.TrimSpace(a.IconPath) != "" {
		gen["icon_path"] = a.IconPath
	}
	if hasNonEmptyJSON(a.Images) {
		gen["images"] = a.Images
	}

	// Preview: first tag only when requested (single-draft review). The stored
	// doc keeps ALL rows regardless.
	previewRows := tagRows
	if a.PreviewFirstOnly && len(tagRows) > 0 {
		previewRows = tagRows[:1]
	}
	previewGen := map[string]interface{}{}
	for k, v := range gen {
		previewGen[k] = v
	}
	previewGen["rows"] = previewRows
	previewArgsJSON, err := json.Marshal(previewGen)
	if err != nil {
		return toolErr("internal_error", "marshal preview args: "+err.Error())
	}
	pdf, fault := generatePDF(client, previewArgsJSON)
	if fault != nil {
		return failResult(fault)
	}

	// Write the preview PDF beside the .mtags (base64 → host writes raw bytes).
	previewPath := a.OutPath + ".preview.pdf"
	if fault := writeFileB64(client, previewPath, pdf.BytesB64); fault != nil {
		return failResult(fault)
	}

	// Assemble + write the .mtags document (JSON written as raw text bytes).
	doc := map[string]interface{}{
		"version":          1,
		"title":            a.Title,
		"sheet_ref":        a.SheetRef,
		"preview_pdf_path": previewPath,
		"generate":         gen,
		"images":           []interface{}{},
		"annotations":      []interface{}{},
	}
	docJSON, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return toolErr("internal_error", "marshal .mtags: "+err.Error())
	}
	if fault := writeFileB64(client, a.OutPath, base64.StdEncoding.EncodeToString(docJSON)); fault != nil {
		return failResult(fault)
	}

	out := map[string]interface{}{
		"success":          true,
		"path":             a.OutPath,
		"row_count":        len(tagRows),
		"page_count":       pdf.PageCount,
		"preview_pdf_path": previewPath,
	}
	if len(pdf.Warnings) > 0 {
		out["warnings"] = pdf.Warnings
	}
	return out
}

// writeFileB64 writes base64 content to a path via host.files.write (the host
// decodes it and writes the raw bytes), creating parent dirs.
func writeFileB64(client capabilityCaller, path, contentB64 string) *toolFault {
	raw, capErr := client.callCapability("host.files.write", map[string]interface{}{
		"path":           path,
		"content":        contentB64,
		"encoding":       "base64",
		"create_parents": true,
	})
	if capErr != nil {
		return &toolFault{Code: fmt.Sprintf("rpc_error_%d", capErr.Code), Msg: capErr.Message}
	}
	var resp struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return &toolFault{Code: "parse_error", Msg: "parse files.write response: " + err.Error()}
	}
	if !resp.Success {
		return &toolFault{Code: resp.ErrorCode, Msg: resp.ErrorMessage}
	}
	return nil
}

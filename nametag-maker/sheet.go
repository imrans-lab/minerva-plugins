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
	RowsJSON         string       `json:"rows_json"`
	Mapping          sheetMapping `json:"mapping"`
	Layout           string       `json:"layout"`
	ImageSide        string       `json:"image_side"`
	BackMode         string       `json:"back_mode"`
	FullGuides       bool         `json:"full_guides"`
	IconWidthIn      float64      `json:"icon_width_in"`
	OutPath          string       `json:"out_path"`
	Title            string       `json:"title"`
	SheetRef         string       `json:"sheet_ref"`
	PreviewFirstOnly bool         `json:"preview_first_only"`
}

func orDefault(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
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

	return map[string]interface{}{
		"success":          true,
		"path":             a.OutPath,
		"row_count":        len(tagRows),
		"page_count":       pdf.PageCount,
		"preview_pdf_path": previewPath,
	}
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

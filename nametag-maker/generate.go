package main

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"strings"
)

// capabilityCaller is the seam between the nametag_generate tool and the host.
// In production it is *hostClient; in tests it is a fake returning canned
// host.pdf.generate replies. This lets the tool logic (doc build → call →
// result map) be exercised without a live broker.
type capabilityCaller interface {
	callCapability(capability string, args map[string]interface{}) (json.RawMessage, *rpcError)
}

// pdfGenerateResult is the result block of a successful host.pdf.generate
// reply (contract §6).
type pdfGenerateResult struct {
	BytesB64    string `json:"bytes_b64"`
	ByteSize    int    `json:"byte_size"`
	PageCount   int    `json:"page_count"`
	ContentType string `json:"content_type"`
}

// toolNametagGenerate is the handler for the nametag_generate tool.
//
// Args (one of rows|csv required):
//   - rows: [{name, class, group, room}]   OR
//   - csv:  a CSV string with headers Name / Class / Group # / Room Assignment
//   - icon_png_base64 (required): bare base64 PNG for the per-tag icon
//   - back_mode    (opt, default "same"): "same" | "blank"
//   - back_offset_x / back_offset_y (opt, points): duplex registration nudge
//   - full_guides  (opt bool): full bounding rect per tag instead of corner marks
//   - icon_width_in (opt, default 0.40): icon width in inches
//
// On success returns {success, bytes_b64, byte_size, page_count, content_type}.
// On a host.pdf.generate failure, surfaces {success:false, error_code,
// error_message}.
func toolNametagGenerate(client capabilityCaller, rawArgs json.RawMessage) map[string]interface{} {
	var a struct {
		Rows []struct {
			Name  string `json:"name"`
			Class string `json:"class"`
			Group string `json:"group"`
			Room  string `json:"room"`
		} `json:"rows"`
		CSV         string  `json:"csv"`
		IconPNGB64  string  `json:"icon_png_base64"`
		BackMode    string  `json:"back_mode"`
		BackOffsetX float64 `json:"back_offset_x"`
		BackOffsetY float64 `json:"back_offset_y"`
		FullGuides  bool    `json:"full_guides"`
		IconWidthIn float64 `json:"icon_width_in"`
	}
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &a); err != nil {
			return toolErr("schema_validation_failed", "arguments not a JSON object: "+err.Error())
		}
	}

	if a.IconPNGB64 == "" {
		return toolErr("schema_validation_failed", "icon_png_base64 is required")
	}

	// Resolve rows from either the structured array or the CSV string.
	var rows []TagRow
	switch {
	case len(a.Rows) > 0:
		for _, r := range a.Rows {
			rows = append(rows, TagRow{Name: r.Name, Class: r.Class, Group: r.Group, Room: r.Room})
		}
	case a.CSV != "":
		parsed, fault := parseCSVRows(a.CSV)
		if fault != nil {
			return failResult(fault)
		}
		rows = parsed
	default:
		return toolErr("schema_validation_failed", "provide either rows or csv")
	}
	if len(rows) == 0 {
		return toolErr("schema_validation_failed", "no tag rows to render")
	}

	if a.BackMode == "" {
		a.BackMode = "same"
	}
	if a.BackMode != "same" && a.BackMode != "blank" {
		return toolErr("schema_validation_failed", `back_mode must be "same" or "blank"`)
	}

	doc := buildDoc(rows, a.IconPNGB64, Options{
		BackMode:    a.BackMode,
		BackOffsetX: a.BackOffsetX,
		BackOffsetY: a.BackOffsetY,
		FullGuides:  a.FullGuides,
		IconWidthIn: a.IconWidthIn,
	})

	// The capability args ARE the doc object itself (contract §4 — NOT wrapped
	// in {"doc": …}). Round-trip through JSON so the map carries exactly the
	// contract field names/omitempty shape the typed Doc encodes.
	docMap, err := docToMap(doc)
	if err != nil {
		return toolErr("internal_error", "encode doc: "+err.Error())
	}

	raw, capErr := client.callCapability("host.pdf.generate", docMap)
	if capErr != nil {
		return toolErr(fmt.Sprintf("rpc_error_%d", capErr.Code), capErr.Message)
	}

	var resp struct {
		Success      bool               `json:"success"`
		ErrorCode    string             `json:"error_code,omitempty"`
		ErrorMessage string             `json:"error_message,omitempty"`
		Result       *pdfGenerateResult `json:"result,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return toolErr("parse_error", "parse host.pdf.generate response: "+err.Error())
	}
	if !resp.Success {
		return toolErr(resp.ErrorCode, resp.ErrorMessage)
	}
	if resp.Result == nil {
		return toolErr("parse_error", "host.pdf.generate returned success but no result")
	}

	return map[string]interface{}{
		"success":      true,
		"bytes_b64":    resp.Result.BytesB64,
		"byte_size":    resp.Result.ByteSize,
		"page_count":   resp.Result.PageCount,
		"content_type": resp.Result.ContentType,
	}
}

// docToMap marshals a Doc to its JSON shape and re-parses it as a generic map
// so it can be carried as capability `args` (which want map[string]interface{}).
func docToMap(doc Doc) (map[string]interface{}, error) {
	b, err := json.Marshal(doc)
	if err != nil {
		return nil, err
	}
	var m map[string]interface{}
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	return m, nil
}

// parseCSVRows parses a CSV string into TagRows. Headers are matched
// case-insensitively against the original spreadsheet column names:
//
//	Name              → Name
//	Class             → Class
//	Group #           → Group
//	Room Assignment   → Room
//
// A header row is required. Unknown columns are ignored; missing columns yield
// empty fields (which omit their draw downstream).
func parseCSVRows(csvText string) ([]TagRow, *toolFault) {
	r := csv.NewReader(strings.NewReader(csvText))
	r.FieldsPerRecord = -1 // tolerate ragged rows
	records, err := r.ReadAll()
	if err != nil {
		return nil, &toolFault{Code: "schema_validation_failed", Msg: "parse csv: " + err.Error()}
	}
	if len(records) == 0 {
		return nil, &toolFault{Code: "schema_validation_failed", Msg: "csv is empty"}
	}

	header := records[0]
	col := map[string]int{} // canonical field → column index
	for i, h := range header {
		switch strings.ToLower(strings.TrimSpace(h)) {
		case "name":
			col["name"] = i
		case "class":
			col["class"] = i
		case "group #", "group":
			col["group"] = i
		case "room assignment", "room":
			col["room"] = i
		}
	}

	get := func(rec []string, field string) string {
		idx, ok := col[field]
		if !ok || idx >= len(rec) {
			return ""
		}
		return strings.TrimSpace(rec[idx])
	}

	var rows []TagRow
	for _, rec := range records[1:] {
		row := TagRow{
			Name:  get(rec, "name"),
			Class: get(rec, "class"),
			Group: get(rec, "group"),
			Room:  get(rec, "room"),
		}
		// Skip wholly-empty lines.
		if row.Name == "" && row.Class == "" && row.Group == "" && row.Room == "" {
			continue
		}
		rows = append(rows, row)
	}
	return rows, nil
}

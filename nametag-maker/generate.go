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

// nametagArgs is the shared input shape for nametag_generate and nametag_save.
// Both tools build the SAME Doc from these inputs; nametag_save additionally
// picks a path, grants scope, and writes the bytes — all server-side, so the
// PDF never traverses the webview IPC channel (which caps payloads at 64 KiB).
type nametagArgs struct {
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

// buildDocFromArgs parses+validates the shared nametag args and builds the Doc.
// It returns the Doc on success or a *toolFault describing the validation error.
// Shared by nametag_generate and nametag_save so neither duplicates doc-building.
func buildDocFromArgs(rawArgs json.RawMessage) (Doc, *toolFault) {
	var a nametagArgs
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &a); err != nil {
			return Doc{}, &toolFault{Code: "schema_validation_failed", Msg: "arguments not a JSON object: " + err.Error()}
		}
	}

	if a.IconPNGB64 == "" {
		return Doc{}, &toolFault{Code: "schema_validation_failed", Msg: "icon_png_base64 is required"}
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
			return Doc{}, fault
		}
		rows = parsed
	default:
		return Doc{}, &toolFault{Code: "schema_validation_failed", Msg: "provide either rows or csv"}
	}
	if len(rows) == 0 {
		return Doc{}, &toolFault{Code: "schema_validation_failed", Msg: "no tag rows to render"}
	}

	if a.BackMode == "" {
		a.BackMode = "same"
	}
	if a.BackMode != "same" && a.BackMode != "blank" {
		return Doc{}, &toolFault{Code: "schema_validation_failed", Msg: `back_mode must be "same" or "blank"`}
	}

	return buildDoc(rows, a.IconPNGB64, Options{
		BackMode:    a.BackMode,
		BackOffsetX: a.BackOffsetX,
		BackOffsetY: a.BackOffsetY,
		FullGuides:  a.FullGuides,
		IconWidthIn: a.IconWidthIn,
	}), nil
}

// generatePDF builds the Doc, calls host.pdf.generate, and returns the parsed
// result. Shared by nametag_generate (which returns the bytes to the UI for
// preview) and nametag_save (which forwards the bytes to host.files.write).
// On a validation/capability/parse error it returns a *toolFault.
func generatePDF(client capabilityCaller, rawArgs json.RawMessage) (*pdfGenerateResult, *toolFault) {
	doc, fault := buildDocFromArgs(rawArgs)
	if fault != nil {
		return nil, fault
	}

	// The capability args ARE the doc object itself (contract §4 — NOT wrapped
	// in {"doc": …}). Round-trip through JSON so the map carries exactly the
	// contract field names/omitempty shape the typed Doc encodes.
	docMap, err := docToMap(doc)
	if err != nil {
		return nil, &toolFault{Code: "internal_error", Msg: "encode doc: " + err.Error()}
	}

	raw, capErr := client.callCapability("host.pdf.generate", docMap)
	if capErr != nil {
		return nil, &toolFault{Code: fmt.Sprintf("rpc_error_%d", capErr.Code), Msg: capErr.Message}
	}

	var resp struct {
		Success      bool               `json:"success"`
		ErrorCode    string             `json:"error_code,omitempty"`
		ErrorMessage string             `json:"error_message,omitempty"`
		Result       *pdfGenerateResult `json:"result,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, &toolFault{Code: "parse_error", Msg: "parse host.pdf.generate response: " + err.Error()}
	}
	if !resp.Success {
		return nil, &toolFault{Code: resp.ErrorCode, Msg: resp.ErrorMessage}
	}
	if resp.Result == nil {
		return nil, &toolFault{Code: "parse_error", Msg: "host.pdf.generate returned success but no result"}
	}
	return resp.Result, nil
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
	res, fault := generatePDF(client, rawArgs)
	if fault != nil {
		return failResult(fault)
	}
	return map[string]interface{}{
		"success":      true,
		"bytes_b64":    res.BytesB64,
		"byte_size":    res.ByteSize,
		"page_count":   res.PageCount,
		"content_type": res.ContentType,
	}
}

// toolNametagSave is the handler for the nametag_save tool. It regenerates the
// PDF deterministically from the SAME inputs as nametag_generate, then prompts
// for a save location, grants filesystem scope, and writes the bytes — all via
// host capabilities on the backend↔host MCP channel, which (unlike the webview
// pluginIPC channel) is NOT subject to the 64 KiB payload cap. So the PDF bytes
// never leave the server side.
//
// Flow (each step via hostClient.callCapability):
//  1. generatePDF(...)              → bytes_b64
//  2. host.dialogs.file_picker      → picked path (or {cancelled:true})
//  3. host.permissions.grant_scope  → authorize the picked path for this plugin
//  4. host.files.write              → write the base64 PDF to the path
//
// Returns {success:true, saved:true, path, bytes_written, page_count} on
// success; {success:true, saved:false, cancelled:true} when the user cancels
// the picker; {success:false, error_code, error_message} (also saved:false) on
// any capability error or denied permission.
func toolNametagSave(client capabilityCaller, rawArgs json.RawMessage) map[string]interface{} {
	// 1. Regenerate the PDF (validation happens here too).
	pdf, fault := generatePDF(client, rawArgs)
	if fault != nil {
		out := failResult(fault)
		out["saved"] = false
		return out
	}

	// 2. Pick a save location. filters is an Array of String in Godot FileDialog
	// format ("*.pdf ; PDF Files") — see CapabilityBroker._handle_host_dialogs_file_picker.
	pickRaw, capErr := client.callCapability("host.dialogs.file_picker", map[string]interface{}{
		"mode":    "save",
		"title":   "Save name tags",
		"filters": []string{"*.pdf ; PDF Files"},
	})
	if capErr != nil {
		return saveErr(fmt.Sprintf("rpc_error_%d", capErr.Code), capErr.Message)
	}
	var pick struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			Cancelled bool   `json:"cancelled"`
			Path      string `json:"path"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(pickRaw, &pick); err != nil {
		return saveErr("parse_error", "parse file_picker response: "+err.Error())
	}
	if !pick.Success {
		return saveErr(pick.ErrorCode, pick.ErrorMessage)
	}
	if pick.Result == nil {
		return saveErr("parse_error", "file_picker returned success but no result")
	}
	if pick.Result.Cancelled {
		return map[string]interface{}{"success": true, "saved": false, "cancelled": true}
	}
	path := pick.Result.Path
	if path == "" {
		return saveErr("parse_error", "file_picker returned an empty path")
	}

	// 3. Grant filesystem scope for the picked path so the write passes scope.
	grantRaw, capErr := client.callCapability("host.permissions.grant_scope", map[string]interface{}{
		"path":   path,
		"reason": "Save generated name tags",
	})
	if capErr != nil {
		return saveErr(fmt.Sprintf("rpc_error_%d", capErr.Code), capErr.Message)
	}
	var grant struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			Granted        bool `json:"granted"`
			AlreadyGranted bool `json:"already_granted"`
			Cancelled      bool `json:"cancelled"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(grantRaw, &grant); err != nil {
		return saveErr("parse_error", "parse grant_scope response: "+err.Error())
	}
	if !grant.Success {
		return saveErr(grant.ErrorCode, grant.ErrorMessage)
	}
	if grant.Result == nil {
		return saveErr("parse_error", "grant_scope returned success but no result")
	}
	if grant.Result.Cancelled {
		return saveErr("permission_denied", "permission to write to that location was declined")
	}
	if !grant.Result.Granted && !grant.Result.AlreadyGranted {
		return saveErr("permission_denied", "could not get permission to write to: "+path)
	}

	// 4. Write the base64 PDF bytes to the picked path.
	writeRaw, capErr := client.callCapability("host.files.write", map[string]interface{}{
		"path":           path,
		"content":        pdf.BytesB64,
		"encoding":       "base64",
		"create_parents": true,
	})
	if capErr != nil {
		return saveErr(fmt.Sprintf("rpc_error_%d", capErr.Code), capErr.Message)
	}
	var write struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			Path         string `json:"path"`
			BytesWritten int    `json:"bytes_written"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(writeRaw, &write); err != nil {
		return saveErr("parse_error", "parse files.write response: "+err.Error())
	}
	if !write.Success {
		return saveErr(write.ErrorCode, write.ErrorMessage)
	}
	if write.Result == nil {
		return saveErr("parse_error", "files.write returned success but no result")
	}

	savedPath := write.Result.Path
	if savedPath == "" {
		savedPath = path
	}
	return map[string]interface{}{
		"success":       true,
		"saved":         true,
		"path":          savedPath,
		"bytes_written": write.Result.BytesWritten,
		"page_count":    pdf.PageCount,
	}
}

// saveErr builds a nametag_save failure map. Unlike toolErr it also carries
// saved:false so the panel can distinguish a failed save from a generate error.
func saveErr(code, msg string) map[string]interface{} {
	return map[string]interface{}{
		"success":       false,
		"saved":         false,
		"error_code":    code,
		"error_message": msg,
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

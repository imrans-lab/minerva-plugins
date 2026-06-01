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

// faceArgs is the JSON shape of one tag face (front or back). Either structured
// (image_id + title + subtitle + columns of lines) or a full-tag image
// (full_image_id). Maps to layout.Face.
type faceArgs struct {
	ImageID   string `json:"image_id"`
	ImageSide string `json:"image_side"`
	Title     string `json:"title"`
	Subtitle  string `json:"subtitle"`
	Columns   []struct {
		Heading string `json:"heading"`
		Lines   []struct {
			Label string `json:"label"`
			Value string `json:"value"`
		} `json:"lines"`
	} `json:"columns"`
	FullImageID string `json:"full_image_id"`
	// Images are free-placed images on this face (a logo/stamp): size, position
	// (tag-local inches from the content box), and rotation. Each references a
	// registered image id (the shared "icon" or an images[] entry).
	Images []struct {
		ImageID     string  `json:"image_id"`
		XIn         float64 `json:"x_in"`
		YIn         float64 `json:"y_in"`
		WidthIn     float64 `json:"width_in"`
		HeightIn    float64 `json:"height_in"`
		RotationDeg float64 `json:"rotation_deg"`
	} `json:"images"`
}

// toFace converts the JSON face args into a layout.Face (nil-safe).
func (fa *faceArgs) toFace() *Face {
	if fa == nil {
		return nil
	}
	var cols []Column
	for _, c := range fa.Columns {
		var lines []DetailLine
		for _, l := range c.Lines {
			lines = append(lines, DetailLine{Label: l.Label, Value: l.Value})
		}
		cols = append(cols, Column{Heading: c.Heading, Lines: lines})
	}
	var placed []PlacedImage
	for _, im := range fa.Images {
		placed = append(placed, PlacedImage{
			ImageID: im.ImageID, XIn: im.XIn, YIn: im.YIn,
			WidthIn: im.WidthIn, HeightIn: im.HeightIn, RotationDeg: im.RotationDeg,
		})
	}
	return &Face{
		ImageID: fa.ImageID, ImageSide: fa.ImageSide,
		Title: fa.Title, Subtitle: fa.Subtitle,
		Columns: cols, FullImageID: fa.FullImageID, Placed: placed,
	}
}

// nametagArgs is the shared input shape for nametag_generate and nametag_save.
// Both tools build the SAME Doc from these inputs; nametag_save additionally
// picks a path, grants scope, and writes the bytes — all server-side, so the
// PDF never traverses the webview IPC channel (which caps payloads at 64 KiB).
type nametagArgs struct {
	Rows []struct {
		// classic layout
		Name  string `json:"name"`
		Class string `json:"class"`
		Group string `json:"group"`
		Room  string `json:"room"`
		// flat detailed convenience (→ a 1-column front face)
		Title    string `json:"title"`
		Subtitle string `json:"subtitle"`
		Lines    []struct {
			Label string `json:"label"`
			Value string `json:"value"`
		} `json:"lines"`
		// generic faces
		Front *faceArgs `json:"front"`
		Back  *faceArgs `json:"back"`
	} `json:"rows"`
	CSV        string `json:"csv"`
	RowsPath   string `json:"rows_path"`
	IconPNGB64 string `json:"icon_png_base64"`
	IconPath   string `json:"icon_path"`
	// Images registers extra named images (beyond the shared "icon") that faces
	// reference by id — for full-image faces or per-tag images. Each entry
	// supplies png_base64 OR path (read on the backend via host.files.read).
	Images []struct {
		ID     string `json:"id"`
		PNGB64 string `json:"png_base64"`
		Path   string `json:"path"`
	} `json:"images"`
	BackMode    string    `json:"back_mode"`
	BackOffsetX float64   `json:"back_offset_x"`
	BackOffsetY float64   `json:"back_offset_y"`
	FullGuides  bool      `json:"full_guides"`
	IconWidthIn float64   `json:"icon_width_in"`
	Layout      string    `json:"layout"`
	ImageSide   string    `json:"image_side"`
	Back        *faceArgs `json:"back"` // shared back face for every tag
}

// buildDocFromArgs parses+validates the shared nametag args and builds the Doc.
// It returns the Doc on success or a *toolFault describing the validation error.
// Shared by nametag_generate and nametag_save so neither duplicates doc-building.
func buildDocFromArgs(rawArgs json.RawMessage, images []Image) (Doc, *toolFault) {
	var a nametagArgs
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &a); err != nil {
			return Doc{}, &toolFault{Code: "schema_validation_failed", Msg: "arguments not a JSON object: " + err.Error()}
		}
	}

	// Resolve rows from either the structured array or the CSV string.
	var rows []TagRow
	switch {
	case len(a.Rows) > 0:
		for _, r := range a.Rows {
			var lines []DetailLine
			for _, l := range r.Lines {
				lines = append(lines, DetailLine{Label: l.Label, Value: l.Value})
			}
			rows = append(rows, TagRow{
				Name: r.Name, Class: r.Class, Group: r.Group, Room: r.Room,
				Title: r.Title, Subtitle: r.Subtitle, Lines: lines,
				Front: r.Front.toFace(), Back: r.Back.toFace(),
			})
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

	if a.Layout != "" && a.Layout != "classic" && a.Layout != "detailed" {
		return Doc{}, &toolFault{Code: "schema_validation_failed", Msg: `layout must be "classic" or "detailed"`}
	}
	if a.ImageSide != "" && a.ImageSide != "left" && a.ImageSide != "right" {
		return Doc{}, &toolFault{Code: "schema_validation_failed", Msg: `image_side must be "left" or "right"`}
	}

	if a.BackMode != "" && a.BackMode != "same" && a.BackMode != "blank" {
		return Doc{}, &toolFault{Code: "schema_validation_failed", Msg: `back_mode must be "same" or "blank"`}
	}

	sharedBack := a.Back.toFace()
	opts := Options{
		BackMode:    a.BackMode, // "" → buildDoc applies the faces-aware default
		BackOffsetX: a.BackOffsetX,
		BackOffsetY: a.BackOffsetY,
		FullGuides:  a.FullGuides,
		IconWidthIn: a.IconWidthIn,
		Layout:      a.Layout,
		ImageSide:   a.ImageSide,
		Back:        sharedBack,
	}

	// The classic icon/name layout requires the shared "icon" image; faces only
	// need the specific images they reference. Use the shared facesMode predicate
	// so this validation can't disagree with buildDoc's render-time decision.
	known := map[string]bool{}
	for _, im := range images {
		known[im.ID] = true
	}
	if !facesMode(rows, opts) {
		if !known[imageID] {
			return Doc{}, &toolFault{Code: "schema_validation_failed", Msg: "provide an icon via icon_png_base64 or icon_path"}
		}
	}

	// Every image a face references (image_id / full_image_id) must resolve to a
	// supplied image — fail clearly here rather than as an opaque host.pdf error.
	checkFace := func(fc *Face) *toolFault {
		if fc == nil {
			return nil
		}
		ids := []string{fc.ImageID, fc.FullImageID}
		for _, p := range fc.Placed {
			ids = append(ids, p.ImageID)
		}
		for _, id := range ids {
			if id != "" && !known[id] {
				return &toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("face references unknown image id %q (add it via images[] or icon_png_base64/icon_path)", id)}
			}
		}
		return nil
	}
	for _, r := range rows {
		if fault := checkFace(r.Front); fault != nil {
			return Doc{}, fault
		}
		if fault := checkFace(r.Back); fault != nil {
			return Doc{}, fault
		}
	}
	if fault := checkFace(sharedBack); fault != nil {
		return Doc{}, fault
	}

	return buildDoc(rows, images, opts), nil
}

// resolveRowsPath supports the path-driven route for tag data: when `rows_path`
// is set, the file (a JSON array of row objects, same shape as inline `rows`)
// is read on the backend via host.files.read and spliced in as `rows`, so large
// rosters never have to be inlined into the tool call. Mutually exclusive with
// inline `rows`. Returns the (possibly rewritten) args. A no-op without rows_path.
func resolveRowsPath(client capabilityCaller, rawArgs json.RawMessage) (json.RawMessage, *toolFault) {
	var probe struct {
		RowsPath string          `json:"rows_path"`
		Rows     json.RawMessage `json:"rows"`
	}
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &probe); err != nil {
			return rawArgs, &toolFault{Code: "schema_validation_failed", Msg: "arguments not a JSON object: " + err.Error()}
		}
	}
	if strings.TrimSpace(probe.RowsPath) == "" {
		return rawArgs, nil
	}
	if len(probe.Rows) > 0 && string(probe.Rows) != "null" {
		return rawArgs, &toolFault{Code: "schema_validation_failed", Msg: "provide rows OR rows_path, not both"}
	}

	raw, capErr := client.callCapability("host.files.read", map[string]interface{}{
		"path":     probe.RowsPath,
		"encoding": "text",
	})
	if capErr != nil {
		return rawArgs, &toolFault{Code: fmt.Sprintf("rpc_error_%d", capErr.Code), Msg: capErr.Message}
	}
	var resp struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			Content string `json:"content"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return rawArgs, &toolFault{Code: "parse_error", Msg: "parse host.files.read response: " + err.Error()}
	}
	if !resp.Success {
		return rawArgs, &toolFault{Code: resp.ErrorCode, Msg: resp.ErrorMessage}
	}
	if resp.Result == nil {
		return rawArgs, &toolFault{Code: "parse_error", Msg: "host.files.read returned no content for rows_path"}
	}
	// The file must be a JSON array of row objects.
	var arr []json.RawMessage
	if err := json.Unmarshal([]byte(resp.Result.Content), &arr); err != nil {
		return rawArgs, &toolFault{Code: "schema_validation_failed", Msg: "rows_path file is not a JSON array of rows: " + err.Error()}
	}

	// Splice the file's array in as `rows` (drop rows_path) and re-marshal.
	var m map[string]json.RawMessage
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &m); err != nil {
			return rawArgs, &toolFault{Code: "schema_validation_failed", Msg: "arguments not a JSON object: " + err.Error()}
		}
	}
	if m == nil {
		m = map[string]json.RawMessage{}
	}
	m["rows"] = json.RawMessage(resp.Result.Content)
	delete(m, "rows_path")
	out, err := json.Marshal(m)
	if err != nil {
		return rawArgs, &toolFault{Code: "internal_error", Msg: "re-marshal args: " + err.Error()}
	}
	return out, nil
}

// readImageB64 returns a PNG as bare base64. An inline b64 wins; otherwise the
// path is read on the backend via host.files.read (encoding base64) — the
// path-driven route, so large real images never have to be inlined into the
// tool call. Returns "" (no fault) when neither is supplied.
func readImageB64(client capabilityCaller, b64, path string) (string, *toolFault) {
	if strings.TrimSpace(b64) != "" {
		return b64, nil
	}
	if strings.TrimSpace(path) == "" {
		return "", nil
	}
	raw, capErr := client.callCapability("host.files.read", map[string]interface{}{
		"path":     path,
		"encoding": "base64",
	})
	if capErr != nil {
		return "", &toolFault{Code: fmt.Sprintf("rpc_error_%d", capErr.Code), Msg: capErr.Message}
	}
	var resp struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			Content string `json:"content"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return "", &toolFault{Code: "parse_error", Msg: "parse host.files.read response: " + err.Error()}
	}
	if !resp.Success {
		return "", &toolFault{Code: resp.ErrorCode, Msg: resp.ErrorMessage}
	}
	if resp.Result == nil || resp.Result.Content == "" {
		return "", &toolFault{Code: "parse_error", Msg: "host.files.read returned no content for path: " + path}
	}
	return resp.Result.Content, nil
}

// resolveImages builds the Doc image table from the args: the shared "icon"
// (icon_png_base64 | icon_path) plus any named entries in `images`. Faces
// reference these by id. Returns an empty list when no images are supplied
// (text-only faces are valid).
func resolveImages(client capabilityCaller, rawArgs json.RawMessage) ([]Image, *toolFault) {
	var a nametagArgs
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &a); err != nil {
			return nil, &toolFault{Code: "schema_validation_failed", Msg: "arguments not a JSON object: " + err.Error()}
		}
	}
	var images []Image

	icon, fault := readImageB64(client, a.IconPNGB64, a.IconPath)
	if fault != nil {
		return nil, fault
	}
	if icon != "" {
		images = append(images, Image{ID: imageID, Format: "png", BytesB64: icon})
	}

	for i, im := range a.Images {
		if strings.TrimSpace(im.ID) == "" {
			return nil, &toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("images[%d] requires an id", i)}
		}
		b64, fault := readImageB64(client, im.PNGB64, im.Path)
		if fault != nil {
			return nil, fault
		}
		if b64 == "" {
			return nil, &toolFault{Code: "schema_validation_failed", Msg: fmt.Sprintf("images[%d] (%q) needs png_base64 or path", i, im.ID)}
		}
		images = append(images, Image{ID: im.ID, Format: "png", BytesB64: b64})
	}
	return images, nil
}

// generatePDF builds the Doc, calls host.pdf.generate, and returns the parsed
// result. Shared by nametag_generate (which returns the bytes to the UI for
// preview) and nametag_save (which forwards the bytes to host.files.write).
// On a validation/capability/parse error it returns a *toolFault.
func generatePDF(client capabilityCaller, rawArgs json.RawMessage) (*pdfGenerateResult, *toolFault) {
	rawArgs, fault := resolveRowsPath(client, rawArgs)
	if fault != nil {
		return nil, fault
	}
	images, fault := resolveImages(client, rawArgs)
	if fault != nil {
		return nil, fault
	}
	doc, fault := buildDocFromArgs(rawArgs, images)
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

// readTextFile reads a UTF-8 text file on the backend via host.files.read.
func readTextFile(client capabilityCaller, path string) (string, *toolFault) {
	raw, capErr := client.callCapability("host.files.read", map[string]interface{}{
		"path":     path,
		"encoding": "text",
	})
	if capErr != nil {
		return "", &toolFault{Code: fmt.Sprintf("rpc_error_%d", capErr.Code), Msg: capErr.Message}
	}
	var resp struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			Content string `json:"content"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return "", &toolFault{Code: "parse_error", Msg: "parse host.files.read response: " + err.Error()}
	}
	if !resp.Success {
		return "", &toolFault{Code: resp.ErrorCode, Msg: resp.ErrorMessage}
	}
	if resp.Result == nil {
		return "", &toolFault{Code: "parse_error", Msg: "host.files.read returned no content for path: " + path}
	}
	return resp.Result.Content, nil
}

// toolNametagRender is the panel IPC handler ("nametag.render"): render the
// editor's current document to a PDF on disk and return its path, for the in-app
// preview (the panel then rasterizes that PDF with pdftoppm). Path-driven BOTH
// ways — generate args are read from args_path, the PDF is written to out_path —
// so nothing large ever crosses the 64 KiB panel IPC channel. The args file is
// the SAME shape as nametag_generate's arguments (rows + options + images).
func toolNametagRender(client capabilityCaller, rawArgs json.RawMessage) map[string]interface{} {
	var a struct {
		ArgsPath string `json:"args_path"`
		OutPath  string `json:"out_path"`
	}
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &a); err != nil {
			return failResult(&toolFault{Code: "schema_validation_failed", Msg: "parse args: " + err.Error()})
		}
	}
	if strings.TrimSpace(a.ArgsPath) == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "args_path is required"})
	}
	if strings.TrimSpace(a.OutPath) == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "out_path is required"})
	}

	genArgs, fault := readTextFile(client, a.ArgsPath)
	if fault != nil {
		return failResult(fault)
	}

	pdf, fault := generatePDF(client, json.RawMessage(genArgs))
	if fault != nil {
		return failResult(fault)
	}

	writeRaw, capErr := client.callCapability("host.files.write", map[string]interface{}{
		"path":           a.OutPath,
		"content":        pdf.BytesB64,
		"encoding":       "base64",
		"create_parents": true,
	})
	if capErr != nil {
		return failResult(&toolFault{Code: fmt.Sprintf("rpc_error_%d", capErr.Code), Msg: capErr.Message})
	}
	var write struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			Path string `json:"path"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(writeRaw, &write); err != nil {
		return failResult(&toolFault{Code: "parse_error", Msg: "parse files.write response: " + err.Error()})
	}
	if !write.Success {
		return failResult(&toolFault{Code: write.ErrorCode, Msg: write.ErrorMessage})
	}
	outPath := a.OutPath
	if write.Result != nil && write.Result.Path != "" {
		outPath = write.Result.Path
	}
	return map[string]interface{}{
		"success": true,
		"result": map[string]interface{}{
			"path":       outPath,
			"page_count": pdf.PageCount,
		},
	}
}

// toolNametagGenerate is the handler for the nametag_generate tool. The full
// argument surface is described authoritatively by the input schema in main.go
// (generateInputSchema/sharedProps) — in brief: rows (classic {name,class,
// group,room} | flat-detailed {title,subtitle,lines} | generic {front,back}
// faces) OR csv; a shared/per-row back face; images (icon_png_base64/icon_path
// + named images[]); layout/back_mode/offsets/full_guides/icon_width_in. An
// icon is required only for the classic layout; faces need only the images they
// reference.
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

	// 2. Resolve the destination. An explicit `path` arg (agent-driven) is
	// written directly with no dialog — parity with Minerva's core MCP file
	// tools, which write wherever the agent says. When `path` is omitted we
	// fall back to a save picker for the human panel flow.
	var pathArg struct {
		Path string `json:"path"`
	}
	// Best-effort: rawArgs was already structurally validated by generatePDF.
	_ = json.Unmarshal(rawArgs, &pathArg)
	path := strings.TrimSpace(pathArg.Path)

	if path == "" {
		picked, early := pickSavePath(client)
		if early != nil {
			return early
		}
		path = picked
	}

	// 3. Write the base64 PDF bytes. Under filesystem_mode "unrestricted" the
	// host authorizes the write from the granted host.files.write capability
	// alone — no grant_scope handshake and no second confirmation dialog.
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

// pickSavePath pops a host save dialog and returns the chosen path. The second
// return is non-nil when the caller should return it directly: either a
// {saved:false, cancelled:true} map (user cancelled the picker) or a saveErr map.
// Used only as the human-panel fallback when nametag_save gets no explicit path.
func pickSavePath(client capabilityCaller) (string, map[string]interface{}) {
	pickRaw, capErr := client.callCapability("host.dialogs.file_picker", map[string]interface{}{
		"mode":    "save",
		"title":   "Save name tags",
		"filters": []string{"*.pdf ; PDF Files"},
	})
	if capErr != nil {
		return "", saveErr(fmt.Sprintf("rpc_error_%d", capErr.Code), capErr.Message)
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
		return "", saveErr("parse_error", "parse file_picker response: "+err.Error())
	}
	if !pick.Success {
		return "", saveErr(pick.ErrorCode, pick.ErrorMessage)
	}
	if pick.Result == nil {
		return "", saveErr("parse_error", "file_picker returned success but no result")
	}
	if pick.Result.Cancelled {
		return "", map[string]interface{}{"success": true, "saved": false, "cancelled": true}
	}
	if pick.Result.Path == "" {
		return "", saveErr("parse_error", "file_picker returned an empty path")
	}
	return pick.Result.Path, nil
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

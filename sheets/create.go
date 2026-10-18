package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
)

func failure(code, message string) map[string]any {
	return map[string]any{"success": false, "error_code": code, "error_message": message, "error": message}
}

func transportFailure(code, message string, err error) map[string]any {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		code = "cancelled"
	}
	return failure(code, message+err.Error())
}

func createEditor(ctx context.Context, stream *rpcStream, raw json.RawMessage) map[string]any {
	args := struct {
		Name       *string `json:"name"`
		CSVContent string  `json:"csv_content"`
		FilePath   string  `json:"file_path"`
	}{}
	if len(raw) != 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return failure("invalid_arguments", "Invalid spreadsheet creation arguments: "+err.Error())
		}
	}
	if args.FilePath != "" && args.CSVContent != "" {
		return failure("invalid_arguments", "csv_content cannot be combined with file_path")
	}
	capability := "mcp.proxy:minerva_create_plugin_editor"
	title := "Spreadsheet"
	if args.Name != nil {
		title = *args.Name
	}
	if args.FilePath == "" && title != "" {
		listed, listErr := stream.capability(ctx, "host.documents.list_open", map[string]any{})
		if listErr != nil {
			return transportFailure("editor_lookup_failed", "Could not check existing editors: ", listErr)
		}
		if listed["success"] == false {
			return listed
		}
		documents, valid := listed["documents"].([]any)
		if !valid {
			return failure("editor_lookup_failed", "Host returned invalid editor listings")
		}
		for _, item := range documents {
			if document, valid := item.(map[string]any); valid && document["editor_name"] == title {
				return map[string]any{"success": true, "already_existed": true, "editor_name": title}
			}
		}
	}
	request := map[string]any{"plugin_id": "sheets", "editor_item_id": "new_minsheet", "tab_title": title}
	if args.FilePath != "" {
		capability = "mcp.proxy:minerva_open_file"
		request = map[string]any{"path": args.FilePath, "action": "open"}
	}
	opened, err := stream.capability(ctx, capability, request)
	if err != nil {
		return transportFailure("creation_failed", "Spreadsheet creation failed: ", err)
	}
	if opened["success"] != true {
		return opened
	}
	if args.FilePath != "" && opened["plugin_id"] != "sheets" {
		if args.Name != nil && *args.Name != "" {
			opened["note"] = "name ignored for plugin-owned file"
		}
		return opened
	}
	name, ok := opened["editor_name"].(string)
	if !ok || name == "" {
		return failure("creation_failed", "Host opened an editor without returning its name")
	}
	if args.CSVContent != "" {
		updated, updateErr := stream.capability(ctx, "mcp.proxy:minerva_sheets_update_data",
			map[string]any{"editor_name": name, "csv_content": args.CSVContent})
		if updateErr != nil || updated["success"] != true {
			message := fmt.Sprintf("Spreadsheet tab %q remains open, but initial CSV content was not applied.", name)
			if updateErr != nil {
				message += " " + updateErr.Error()
			} else {
				message += " " + fmt.Sprint(updated["error_message"])
			}
			result := failure("initial_content_failed", message)
			result["editor_name"] = name
			return result
		}
	}
	result := opened
	result["message"] = "Spreadsheet editor created. Use this editor_name for subsequent operations."
	if args.FilePath != "" && args.Name != nil && *args.Name != "" {
		result["note"] = "name was ignored for a file-backed spreadsheet; editor_name identifies the opened tab."
	}
	if args.FilePath != "" || args.CSVContent != "" {
		data, readErr := stream.capability(ctx, "mcp.proxy:minerva_sheets_get_data", map[string]any{"editor_name": name, "format": "json", "range": "A1"})
		// A data-size refusal still carries independently computed import counts.
		countsOnly := data["error_code"] == "cell_too_large" || data["error_code"] == "payload_too_large"
		if readErr != nil || (data["success"] != true && !countsOnly) {
			refusal := failure("import_verification_failed", fmt.Sprintf("Spreadsheet tab %q remains open, but imported rows could not be verified.", name))
			refusal["editor_name"] = name
			return refusal
		}
		rows, ok := data["used_row_count"].(float64)
		if !ok || rows < 0 || rows != math.Trunc(rows) {
			refusal := failure("import_verification_failed", fmt.Sprintf("Spreadsheet tab %q returned invalid imported row counts.", name))
			refusal["editor_name"] = name
			return refusal
		}
		result["rows_imported"] = rows
		if rows == 0 {
			result["warning"] = "Import produced 0 rows — the file/CSV had no usable data. Verify the source before continuing; do NOT proceed as if data were loaded."
		}
	}
	return result
}

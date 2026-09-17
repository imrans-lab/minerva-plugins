package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// The HTML panel talks to this backend over window.minerva.call, which is
// bounded at 65,536 UTF-8 bytes in BOTH directions and has no bulk route. A
// real name-tag PDF base64-encodes to hundreds of KB, and a logo PNG easily
// exceeds the cap on the way in, so neither may travel inline:
//
//	in  — the panel picks the icon with a host dialog (nametag_pick_icon) and
//	      passes the resulting icon_path; only the path crosses the channel.
//	out — nametag_generate with deliver_to_file writes the PDF to a file and
//	      returns its path; the panel pulls the bytes back in chunks small
//	      enough to fit the cap (nametag_read_chunk).
//
// Tools a worker calls directly over stdio are not capped, so the default
// inline-bytes result of nametag_generate is unchanged.

// previewChunkBytes is the payload of one nametag_read_chunk reply, in bytes of
// the file. Base64 inflates it by 4/3 (~43.7 KiB) which, with the result
// envelope, stays inside the 64 KiB control cap.
const previewChunkBytes = 32 * 1024

// previewSeq numbers the preview files this process writes so two renders in a
// row never fight over one path.
var previewSeq int

// retainedPreviews bounds how many delivered previews stay on disk. A transfer
// normally reclaims its own preview at the eof read; this bound reclaims the
// ones nobody finished reading. It is a small ring rather than "the previous
// one" because the backend cannot see panels: two panels can have transfers in
// flight at once, and deleting the other one's file mid-transfer would break it.
// Delivering a 5th preview removes the oldest of the 4 kept.
const retainedPreviews = 4

// deliveredPreviews are the preview paths still on disk, oldest first.
var deliveredPreviews []string

// ownedFile is the identity of a file this process wrote: the Lstat record taken
// immediately after the write, plus its size.
type ownedFile struct {
	info os.FileInfo
	size int64
}

// ownPaths are the files this process wrote (writePDFFile), keyed by cleaned
// path. nametag_read_chunk hands bytes back to its caller, so it serves only
// these — it is not a general read-any-file verb. The recorded identity is what
// makes that true: a pathname alone can be replaced with a symlink or another
// file between the write and the read.
var ownPaths = map[string]ownedFile{}

// nextPreviewPath names the next generated preview PDF in the system temp dir.
func nextPreviewPath() string {
	previewSeq++
	return filepath.Join(os.TempDir(), fmt.Sprintf("nametag-preview-%d-%d.pdf", os.Getpid(), previewSeq))
}

// forgetOwnPath deletes a file this process wrote and drops it from the
// readable set. A remove failure is not worth failing a tool call over: the
// path stays forgotten either way, so the bytes stop being reachable.
func forgetOwnPath(path string) {
	if path == "" {
		return
	}
	clean := filepath.Clean(path)
	delete(ownPaths, clean)
	for i, p := range deliveredPreviews {
		if filepath.Clean(p) == clean {
			deliveredPreviews = append(deliveredPreviews[:i], deliveredPreviews[i+1:]...)
			break
		}
	}
	_ = os.Remove(path)
}

// recordOwnFile captures the identity of a file this process just wrote. A
// pathname that is not a regular file (a symlink, a directory) is not recorded,
// so nametag_read_chunk will refuse it.
func recordOwnFile(path string) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		delete(ownPaths, filepath.Clean(path))
		return
	}
	ownPaths[filepath.Clean(path)] = ownedFile{info: info, size: info.Size()}
}

// checkOwnFile proves the file at `path` is still the one this process wrote —
// same inode, same size, and not a symlink — rather than a replacement standing
// at a spelling the allowlist happens to hold.
func checkOwnFile(path string) *toolFault {
	rec, known := ownPaths[filepath.Clean(path)]
	if !known {
		return &toolFault{Code: "target_not_allowlisted",
			Msg: "nametag_read_chunk only serves PDFs this plugin wrote (nametag_generate deliver_to_file / nametag_save) in this session: " + path}
	}
	info, err := os.Lstat(path)
	if err != nil {
		return &toolFault{Code: "io_error", Msg: "stat " + path + ": " + err.Error()}
	}
	if !info.Mode().IsRegular() || !os.SameFile(rec.info, info) || info.Size() != rec.size {
		return &toolFault{Code: "file_identity_changed",
			Msg: "the file at " + path + " is no longer the one this plugin wrote"}
	}
	return nil
}

// writePDFFile writes base64 PDF bytes to a path via host.files.write and
// returns the host's path plus the bytes actually written (the on-disk truth).
// Shared by every route that lands a PDF on disk.
func writePDFFile(client capabilityCaller, path, bytesB64 string) (string, int, *toolFault) {
	raw, capErr := client.callCapability("host.files.write", map[string]interface{}{
		"path":           path,
		"content":        bytesB64,
		"encoding":       "base64",
		"create_parents": true,
	})
	if capErr != nil {
		return "", 0, &toolFault{Code: fmt.Sprintf("rpc_error_%d", capErr.Code), Msg: capErr.Message}
	}
	var resp struct {
		Success      bool   `json:"success"`
		ErrorCode    string `json:"error_code,omitempty"`
		ErrorMessage string `json:"error_message,omitempty"`
		Result       *struct {
			Path         string `json:"path"`
			BytesWritten int    `json:"bytes_written"`
		} `json:"result,omitempty"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return "", 0, &toolFault{Code: "parse_error", Msg: "parse host.files.write response: " + err.Error()}
	}
	if !resp.Success {
		return "", 0, &toolFault{Code: resp.ErrorCode, Msg: resp.ErrorMessage}
	}
	if resp.Result == nil {
		return "", 0, &toolFault{Code: "parse_error", Msg: "host.files.write returned success but no result"}
	}
	written := resp.Result.Path
	if written == "" {
		written = path
	}
	recordOwnFile(written)
	return written, resp.Result.BytesWritten, nil
}

// deliverPDFToFile writes a generated PDF to a fresh temp file and returns the
// nametag_generate result that names it instead of carrying its bytes.
func deliverPDFToFile(client capabilityCaller, pdf *pdfGenerateResult) map[string]interface{} {
	path, written, fault := writePDFFile(client, nextPreviewPath(), pdf.BytesB64)
	if fault != nil {
		return failResult(fault)
	}
	deliveredPreviews = append(deliveredPreviews, path)
	for len(deliveredPreviews) > retainedPreviews {
		forgetOwnPath(deliveredPreviews[0])
	}
	out := map[string]interface{}{
		"success":      true,
		"path":         path,
		"byte_size":    written,
		"page_count":   pdf.PageCount,
		"content_type": pdf.ContentType,
	}
	if len(pdf.Warnings) > 0 {
		out["warnings"] = pdf.Warnings
	}
	return out
}

// toolNametagReadChunk returns one slice of a PDF THIS process wrote, so a panel
// that cannot receive a whole PDF in one reply can pull it across in pieces.
// Any other path is refused: this verb returns file bytes to its caller, so its
// reach is the set of files the backend itself produced, not the filesystem.
// Offset and length are file bytes; length is clamped to previewChunkBytes and
// the reply reports what it actually carries, so the caller loops on the
// returned length until eof. The slice that reports eof also removes a
// delivered preview — the transfer is done with it.
//
// The slice is cut from a full host.files.read of the file each call: a preview
// PDF is a few hundred KB and a re-read costs less than holding per-panel
// buffers alive in the backend.
func toolNametagReadChunk(client capabilityCaller, rawArgs json.RawMessage) map[string]interface{} {
	var a struct {
		Path   string `json:"path"`
		Offset int    `json:"offset"`
		Length int    `json:"length"`
	}
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &a); err != nil {
			return failResult(&toolFault{Code: "schema_validation_failed", Msg: "arguments not a JSON object: " + err.Error()})
		}
	}
	if strings.TrimSpace(a.Path) == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "path is required"})
	}
	if a.Offset < 0 {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "offset must not be negative"})
	}
	if fault := checkOwnFile(a.Path); fault != nil {
		return failResult(fault)
	}

	b64, fault := readFileB64(client, a.Path)
	if fault != nil {
		return failResult(fault)
	}
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return failResult(&toolFault{Code: "parse_error", Msg: "host.files.read returned invalid base64: " + err.Error()})
	}
	if a.Offset > len(data) {
		return failResult(&toolFault{Code: "schema_validation_failed",
			Msg: fmt.Sprintf("offset %d is past the end of %s (%d bytes)", a.Offset, a.Path, len(data))})
	}

	length := a.Length
	if length <= 0 || length > previewChunkBytes {
		length = previewChunkBytes
	}
	if a.Offset+length > len(data) {
		length = len(data) - a.Offset
	}

	eof := a.Offset+length >= len(data)
	out := map[string]interface{}{
		"success":     true,
		"path":        a.Path,
		"offset":      a.Offset,
		"length":      length,
		"total_bytes": len(data),
		"eof":         eof,
		"bytes_b64":   base64.StdEncoding.EncodeToString(data[a.Offset : a.Offset+length]),
	}
	if eof && isDeliveredPreview(a.Path) {
		forgetOwnPath(a.Path)
	}
	return out
}

// toolNametagPickIcon pops a host open-dialog for a PNG and returns its path,
// so the panel never has to carry image bytes across the capped channel.
func toolNametagPickIcon(client capabilityCaller, _ json.RawMessage) map[string]interface{} {
	path, cancelled, fault := pickFilePath(client, "open", "Choose an icon PNG", []string{"*.png ; PNG Images"})
	if fault != nil {
		return failResult(fault)
	}
	if cancelled {
		return map[string]interface{}{"success": true, "cancelled": true}
	}
	return map[string]interface{}{"success": true, "cancelled": false, "path": path}
}

// isDeliveredPreview reports whether a path is one of the previews still held
// on disk — a PDF written for a caller by nametag_save is not one, and reading
// it must never delete it.
func isDeliveredPreview(path string) bool {
	clean := filepath.Clean(path)
	for _, p := range deliveredPreviews {
		if filepath.Clean(p) == clean {
			return true
		}
	}
	return false
}

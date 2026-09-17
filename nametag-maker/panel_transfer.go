package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// The HTML panel talks to this backend over window.minerva.call, which is
// bounded at 65,536 UTF-8 bytes in BOTH directions and has no bulk route. A
// real name-tag PDF base64-encodes to hundreds of KB, and a logo PNG easily
// exceeds the cap on the way in, so neither may travel inline:
//
//	in  — the panel picks the icon with a host dialog (nametag_pick_icon) and
//	      passes the resulting icon_path; only the path crosses the channel.
//	out — nametag_generate with deliver_by_token holds the PDF in this process
//	      under a one-time token and returns that; the panel pulls the bytes
//	      back in slices that fit the cap (nametag_read_chunk).
//
// The preview never touches disk: a file would have to be named, guarded
// against replacement between the write and each read, and reclaimed without
// knowing which panel is still reading it. A token names bytes this process
// already holds, so there is nothing to re-open and nothing to race.
//
// Tools a worker calls directly over stdio are not capped, so the default
// inline-bytes result of nametag_generate is unchanged.

// previewChunkBytes is the payload of one nametag_read_chunk reply, in bytes of
// the PDF. Base64 inflates it by 4/3 (~43.7 KiB) which, with the result
// envelope, stays inside the 64 KiB control cap.
const previewChunkBytes = 32 * 1024

// transferSlots bounds how many PDFs this process holds at once. Each entry is
// a whole PDF, so memory is 32 times one PDF; a panel walks one transfer at a
// time, so 32 covers far more panels mid-transfer than Minerva ever opens.
// Delivering into a full store drops the entry read least recently, which is
// always the longest-abandoned one when any exists.
const transferSlots = 32

// staleTransfer is how long an unread transfer survives. A panel that closed or
// reloaded mid-transfer never comes back for its bytes; a later read of that
// token is refused, and eviction reaches it before any transfer still walked.
const staleTransfer = 5 * time.Minute

// pdfTransfer is one generated PDF waiting to be pulled across the capped
// channel.
type pdfTransfer struct {
	data    []byte
	touched time.Time
}

// transfers are the live transfers, keyed by token.
var transfers = map[string]*pdfTransfer{}

// now is the clock the store ages entries by; a test replaces it.
var now = time.Now

// newTransferToken mints an unguessable token: a caller cannot reach another
// panel's bytes by guessing a name.
func newTransferToken() (string, *toolFault) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", &toolFault{Code: "internal_error", Msg: "mint transfer token: " + err.Error()}
	}
	return hex.EncodeToString(buf), nil
}

// rememberTransfer stores bytes under a fresh token, making room first.
func rememberTransfer(t *pdfTransfer) (string, *toolFault) {
	token, fault := newTransferToken()
	if fault != nil {
		return "", fault
	}
	for len(transfers) >= transferSlots {
		evictTransfer()
	}
	t.touched = now()
	transfers[token] = t
	return token, nil
}

// evictTransfer drops the most expendable entry: the longest-abandoned one,
// else the least recently read.
func evictTransfer() {
	oldest, at := "", time.Time{}
	for token, t := range transfers {
		if oldest == "" || t.touched.Before(at) {
			oldest, at = token, t.touched
		}
	}
	delete(transfers, oldest)
}

// takeTransfer returns a live transfer, expiring it first if nothing has read
// it for staleTransfer. A token that is unknown, expired or already completed
// is one error the panel can act on: start the transfer over.
func takeTransfer(token string) (*pdfTransfer, *toolFault) {
	t, ok := transfers[token]
	if ok && now().Sub(t.touched) > staleTransfer {
		delete(transfers, token)
		ok = false
	}
	if !ok {
		return nil, &toolFault{Code: "transfer_not_found",
			Msg: "no transfer for this token — it finished, expired, or was evicted; generate again to start a new one"}
	}
	return t, nil
}

// deliverPDFToTransfer holds a generated PDF in this process and returns the
// nametag_generate result that names it instead of carrying its bytes.
func deliverPDFToTransfer(pdf *pdfGenerateResult) map[string]interface{} {
	data, err := base64.StdEncoding.DecodeString(pdf.BytesB64)
	if err != nil {
		return failResult(&toolFault{Code: "parse_error", Msg: "host.pdf.generate returned invalid base64: " + err.Error()})
	}
	token, fault := rememberTransfer(&pdfTransfer{data: data})
	if fault != nil {
		return failResult(fault)
	}
	out := map[string]interface{}{
		"success":      true,
		"token":        token,
		"byte_size":    len(data),
		"page_count":   pdf.PageCount,
		"content_type": pdf.ContentType,
	}
	if len(pdf.Warnings) > 0 {
		out["warnings"] = pdf.Warnings
	}
	return out
}

// toolNametagReadChunk returns one slice of a transfer this process is holding,
// so a panel that cannot receive a whole PDF in one reply can pull it across in
// pieces. Offset and length are PDF bytes; length is clamped to
// previewChunkBytes and the reply reports what it actually carries, so the
// caller loops on the returned length until eof. The slice that reports eof
// releases the transfer — the caller has everything.
//
// It serves only bytes this process generated and is holding under a token; it
// reads no files.
func toolNametagReadChunk(_ capabilityCaller, rawArgs json.RawMessage) map[string]interface{} {
	var a struct {
		Token  string `json:"token"`
		Offset int    `json:"offset"`
		Length int    `json:"length"`
	}
	if len(rawArgs) > 0 && string(rawArgs) != "null" {
		if err := json.Unmarshal(rawArgs, &a); err != nil {
			return failResult(&toolFault{Code: "schema_validation_failed", Msg: "arguments not a JSON object: " + err.Error()})
		}
	}
	if strings.TrimSpace(a.Token) == "" {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "token is required"})
	}
	if a.Offset < 0 {
		return failResult(&toolFault{Code: "schema_validation_failed", Msg: "offset must not be negative"})
	}

	t, fault := takeTransfer(a.Token)
	if fault != nil {
		return failResult(fault)
	}
	if a.Offset > len(t.data) {
		return failResult(&toolFault{Code: "schema_validation_failed",
			Msg: fmt.Sprintf("offset %d is past the end of the transfer (%d bytes)", a.Offset, len(t.data))})
	}

	length := a.Length
	if length <= 0 || length > previewChunkBytes {
		length = previewChunkBytes
	}
	if a.Offset+length > len(t.data) {
		length = len(t.data) - a.Offset
	}

	eof := a.Offset+length >= len(t.data)
	out := map[string]interface{}{
		"success":     true,
		"offset":      a.Offset,
		"length":      length,
		"total_bytes": len(t.data),
		"eof":         eof,
		"bytes_b64":   base64.StdEncoding.EncodeToString(t.data[a.Offset : a.Offset+length]),
	}
	if eof {
		delete(transfers, a.Token)
	} else {
		t.touched = now()
	}
	return out
}

// writePDFFile writes base64 PDF bytes to a path via host.files.write and
// returns the host's path plus the bytes actually written (the on-disk truth).
// Shared by the routes that land a PDF on disk for the caller: nametag_save and
// the .mtags render.
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
	return written, resp.Result.BytesWritten, nil
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

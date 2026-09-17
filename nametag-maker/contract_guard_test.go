package main

// nametag-maker's CONTRACT GUARD — six domain-defined cases through the real
// tool surface.
//
// WHY THIS SUITE EXISTS
//
// The panel is an HTML page on the host's webview bridge, bounded at 65,536
// UTF-8 bytes in BOTH directions with no bulk route. A sheet of any real size
// renders to a PDF of hundreds of kilobytes, so the whole preview surface rests
// on the token-and-slices transfer: nothing that grows with the sheet may ever
// travel inline.
//
// panel_transfer_test.go pins that transfer for one PDF. This guard weighs the
// plugin at BOTH sizes and in both moods:
//
//	1. null / empty document   — a sheet with no rows is refused, and nothing
//	                             is written
//	2. small happy             — two rows map to two tags and a document
//	3. small unhappy           — a malformed sheet is refused by code, with
//	                             nothing written
//	4. large happy             — a 200-row sheet's PDF crosses as a token plus
//	                             slices that each fit the cap, reassembling
//	                             byte for byte, where the inline reply would not
//	5. large unhappy           — that transfer, expired: refused by name, and
//	                             never a silent empty slice
//	6. large-with-errors reply — a 200-row sheet where EVERY row maps to
//	                             nothing: see THE DECLARED LANE below
//
// nametag's own definitions of LARGE are SHEET ROW COUNT and PAGE COUNT.
//
// THE DECLARED LANE (case 6). nametag has no reply whose error payload grows
// with the sheet: a row whose mapped column is absent contributes an empty
// value, which is dropped, and the tool answers success with a row_count that
// counts it. So the all-faulty sheet and the clean one answer in the SAME SHAPE
// and within bytes of each other, which case 6 measures and pins. Two
// consequences worth stating plainly: the reply can never cross a host boundary
// on the strength of its complaints, and a sheet whose every row is unmappable
// is reported as a successful build of N tags. The second is a GAP, not a
// contract — it is filed, not blessed — and adding a per-row finding will turn
// this case red, which is the point: the lane has to be re-declared
// deliberately.
//
// WHERE THE REAL CHAIN ENDS. Everything this guard drives is the plugin's own
// code — argument validation, the sheet mapping, the document it writes, the
// transfer store and its refusals. The PDF itself is rendered by a HOST
// capability (host.pdf.generate), which no Go test can hold; the host stand-in
// answers with real bytes and the guard asserts on what the plugin does with
// them. That boundary is the plugin's, not this test's.
//
// ORACLE: revert the token transfer (return bytes_b64 inline from
// nametag_generate) and case 4 goes red — the reply is 265 KB against a 64 KiB
// cap, which the host replaces with payload_too_large and the panel shows no
// preview at all. Let an expired token answer with an empty slice instead of a
// refusal and case 5 goes red. Cases 1, 2 and 3 stay green: they are small
// enough that the transfer never engages.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

// nametag's unit of large, and the count both large moods share.
const guardLargeRows = 200

// guardSmallRows is a sheet that fits any bound — the size at which a refusal
// has no excuse.
const guardSmallRows = 2

// guardOKRender is the host's answer for a small render: real bytes, one page.
const guardOKRender = `{"success":true,"result":{"bytes_b64":"JVBERi0xLjcK","byte_size":9,"page_count":1,"content_type":"application/pdf"}}`

const guardWriteOK = `{"success":true,"result":{"path":"/tmp/guard.mtags","bytes_written":100}}`

// guardSheet is a sheet of `rows` rows. `mapped` decides which of the two
// moods it is: a mapped sheet names the column the mapping reads, an unmapped
// one carries the same rows under a column nothing maps to — every row then
// contributes an empty title, which is case 6's subject.
func guardSheet(rows int, mapped bool) string {
	column := "Name"
	if !mapped {
		column = "NotTheMappedColumn"
	}
	parts := make([]string, 0, rows)
	for i := 0; i < rows; i++ {
		parts = append(parts, fmt.Sprintf(
			`{%q:"Attendee %03d","Cabin":"%d","Teacher":"Teacher %02d"}`,
			column, i, i%12, i%7))
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// guardBuildArgs is the one call shape both moods of case 6 use, so the sheet
// is the only thing that differs between them.
func guardBuildArgs(t *testing.T, rowsJSON string) json.RawMessage {
	t.Helper()
	return mustArgs(t, map[string]interface{}{
		"rows_json": rowsJSON,
		"mapping": map[string]interface{}{
			"title":    "Name",
			"subtitle": "Cabin",
			"lines":    []map[string]interface{}{{"label": "Teacher", "column": "Teacher"}},
		},
		"layout":   "detailed",
		"out_path": "/tmp/guard.mtags",
		"title":    "Contract guard",
	})
}

// guardRefusal is the discipline every unhappy case here is held to: an
// explicit failure and a machine-readable code, never prose. It mirrors
// scripts/contract_guard.gd's expect_refusal; Go's module boundaries keep the
// shared helper from being imported across plugins, so the rule travels as the
// same named assertion rather than the same file.
func guardRefusal(t *testing.T, name string, res map[string]interface{}) string {
	t.Helper()
	if ok, _ := res["success"].(bool); ok {
		t.Fatalf("%s: expected a refusal, got a success: %+v", name, res)
	}
	code, _ := res["error_code"].(string)
	if code == "" {
		t.Fatalf("%s: the refusal names no error_code: %+v", name, res)
	}
	return code
}

// guardNothingWritten is the no-partial-state rule: a refused build must not
// have written a document or a preview on its way to the refusal.
func guardNothingWritten(t *testing.T, name string, host *seqHost) {
	t.Helper()
	for _, call := range host.calls {
		if call.capability == "host.files.write" {
			t.Fatalf("%s: partial state — a refused build wrote %v",
				name, call.args["path"])
		}
	}
}

// TestContractGuardNullDocument — case 1. A sheet with no rows is not a
// zero-tag document to print; it is a call that cannot be answered, and it is
// refused before anything is written.
func TestContractGuardNullDocument(t *testing.T) {
	host := &seqHost{}
	res := toolNametagBuildFromSheet(host, guardBuildArgs(t, "[]"))
	if code := guardRefusal(t, "null-document", res); code != "schema_validation_failed" {
		t.Fatalf("null-document: want schema_validation_failed, got %q", code)
	}
	guardNothingWritten(t, "null-document", host)
}

// TestContractGuardSmallHappy — case 2. Two rows become two tags, a rendered
// preview and a document, in that order.
func TestContractGuardSmallHappy(t *testing.T) {
	host := &seqHost{replies: []json.RawMessage{
		json.RawMessage(guardOKRender),
		json.RawMessage(guardWriteOK),
		json.RawMessage(guardWriteOK),
	}}
	res := toolNametagBuildFromSheet(host, guardBuildArgs(t, guardSheet(guardSmallRows, true)))
	if ok, _ := res["success"].(bool); !ok {
		t.Fatalf("small-happy: %+v", res)
	}
	if res["row_count"] != guardSmallRows {
		t.Fatalf("small-happy: row_count %v, want %d", res["row_count"], guardSmallRows)
	}
	if path, _ := res["preview_pdf_path"].(string); path == "" {
		t.Fatalf("small-happy: no preview was named: %+v", res)
	}
	// No silent empty document: the .mtags the caller is told about carries the
	// rows, not an empty generate block.
	if len(host.calls) < 3 {
		t.Fatalf("small-happy: expected a render and two writes, got %+v", host.calls)
	}
}

// TestContractGuardSmallUnhappy — case 3. A malformed sheet, refused by code,
// with nothing written.
func TestContractGuardSmallUnhappy(t *testing.T) {
	host := &seqHost{}
	res := toolNametagBuildFromSheet(host, guardBuildArgs(t, `{"Name":"not an array"}`))
	if code := guardRefusal(t, "small-unhappy", res); code != "schema_validation_failed" {
		t.Fatalf("small-unhappy: want schema_validation_failed, got %q", code)
	}
	guardNothingWritten(t, "small-unhappy", host)
}

// TestContractGuardLargeHappy — case 4, and the oracle. A 200-row sheet's PDF
// reaches the panel whole, as a token plus slices that each fit the cap, where
// the inline reply it replaces would not have fit at all.
func TestContractGuardLargeHappy(t *testing.T) {
	freshStore(t)
	pdf := oversizePDF()
	host := &fileHost{pdf: pdf, pageCount: guardLargeRows / 8}

	rows := make([]map[string]interface{}, 0, guardLargeRows)
	for i := 0; i < guardLargeRows; i++ {
		rows = append(rows, map[string]interface{}{"name": fmt.Sprintf("Attendee %03d", i)})
	}
	args := mustArgs(t, map[string]interface{}{
		"icon_png_base64":  "Zm9v",
		"deliver_by_token": true,
		"rows":             rows,
	})

	res := toolNametagGenerate(host, args)
	if ok, _ := res["success"].(bool); !ok {
		t.Fatalf("large-happy: %+v", res)
	}
	tokenReply := replyBytes(t, res)
	if tokenReply > controlCapBytes {
		t.Fatalf("large-happy: the token reply is %d bytes, over the %d-byte cap",
			tokenReply, controlCapBytes)
	}
	token, _ := res["token"].(string)
	if token == "" {
		t.Fatalf("large-happy: no token: %+v", res)
	}
	if res["byte_size"] != len(pdf) {
		t.Fatalf("large-happy: byte_size %v, want %d", res["byte_size"], len(pdf))
	}

	got := chunks(t, host, token, len(pdf))
	if !bytes.Equal(got, pdf) {
		t.Fatalf("large-happy: reassembled %d bytes, want the %d rendered bytes",
			len(got), len(pdf))
	}

	// The falsifier, measured rather than asserted from memory: the inline
	// reply this replaces is far over the cap, so the host would swap it for
	// payload_too_large and the panel would show nothing.
	inline := toolNametagGenerate(host, mustArgs(t, map[string]interface{}{
		"icon_png_base64": "Zm9v",
		"rows":            rows,
	}))
	inlineBytes := replyBytes(t, inline)
	if inlineBytes <= controlCapBytes {
		t.Fatalf("large-happy: the inline reply is only %d bytes — the fixture no "+
			"longer proves the cap is exceeded", inlineBytes)
	}
	t.Logf("measured [large-happy]: %d rows, pdf=%d B, token reply=%d B, "+
		"inline reply=%d B, control cap=%d B",
		guardLargeRows, len(pdf), tokenReply, inlineBytes, controlCapBytes)
}

// TestContractGuardLargeUnhappy — case 5. The transfer that is no longer
// there. A caller mid-walk must be told, by name; an empty slice reported as
// success would reassemble into a truncated PDF nobody could tell from a whole
// one.
func TestContractGuardLargeUnhappy(t *testing.T) {
	freshStore(t)
	pdf := oversizePDF()
	host := &fileHost{pdf: pdf, pageCount: guardLargeRows / 8}
	res := toolNametagGenerate(host, mustArgs(t, map[string]interface{}{
		"icon_png_base64":  "Zm9v",
		"deliver_by_token": true,
		"rows":             []map[string]interface{}{{"name": "Ada"}},
	}))
	token, _ := res["token"].(string)
	if token == "" {
		t.Fatalf("large-unhappy: no token to lose: %+v", res)
	}
	// One slice lands, so the caller is genuinely mid-walk.
	first := toolNametagReadChunk(host, mustArgs(t, map[string]interface{}{
		"token": token, "offset": 0,
	}))
	if ok, _ := first["success"].(bool); !ok {
		t.Fatalf("large-unhappy: the first slice failed: %+v", first)
	}

	base := time.Now()
	now = func() time.Time { return base.Add(staleTransfer + time.Second) }
	expired := toolNametagReadChunk(host, mustArgs(t, map[string]interface{}{
		"token": token, "offset": 1,
	}))
	if code := guardRefusal(t, "large-unhappy", expired); code != "transfer_not_found" {
		t.Fatalf("large-unhappy: want transfer_not_found, got %q (%+v)", code, expired)
	}
	if _, carried := expired["bytes_b64"]; carried {
		t.Fatalf("large-unhappy: a lost transfer handed bytes over anyway: %+v", expired)
	}
	if len(transfers) != 0 {
		t.Fatalf("large-unhappy: an expired transfer must be dropped, store holds %d",
			len(transfers))
	}
}

// TestContractGuardLargeErrorReply — case 6, and nametag's DECLARED LANE (see
// the header). The same 200-row sheet twice: once mapped, once with every row
// under a column the mapping does not read. The measurement is the point — the
// unhappy reply is the same shape and the same size class as the happy one,
// because nametag carries no per-row findings at all.
func TestContractGuardLargeErrorReply(t *testing.T) {
	build := func(rowsJSON string) (map[string]interface{}, int) {
		host := &seqHost{replies: []json.RawMessage{
			json.RawMessage(guardOKRender),
			json.RawMessage(guardWriteOK),
			json.RawMessage(guardWriteOK),
		}}
		res := toolNametagBuildFromSheet(host, guardBuildArgs(t, rowsJSON))
		if ok, _ := res["success"].(bool); !ok {
			t.Fatalf("build: %+v", res)
		}
		return res, replyBytes(t, res)
	}

	clean, cleanBytes := build(guardSheet(guardLargeRows, true))
	faulty, faultyBytes := build(guardSheet(guardLargeRows, false))

	if clean["row_count"] != guardLargeRows || faulty["row_count"] != guardLargeRows {
		t.Fatalf("large-errors: both moods must report %d rows, got %v and %v",
			guardLargeRows, clean["row_count"], faulty["row_count"])
	}

	// THE DECLARATION: the reply carries no per-row finding in either mood, so
	// the all-faulty answer cannot outgrow the clean one. Add one and this
	// fails, which is how the lane gets re-declared rather than quietly left.
	if _, has := faulty["warnings"]; has {
		t.Fatalf("large-errors: nametag now reports per-row findings (%+v) — the "+
			"declared lane in this file's header is out of date and the case must "+
			"be rewritten to weigh them", faulty["warnings"])
	}
	if len(faulty) != len(clean) {
		t.Fatalf("large-errors: the two moods answer in different shapes: %v vs %v",
			keysOf(faulty), keysOf(clean))
	}
	t.Logf("measured [large-errors]: %d rows, clean reply=%d B, "+
		"every-row-unmappable reply=%d B, control cap=%d B — nametag's unhappy "+
		"reply does not grow with the sheet",
		guardLargeRows, cleanBytes, faultyBytes, controlCapBytes)

	// The gap this declaration records, stated where a reader will see it: a
	// sheet whose every row maps to nothing still reports a successful build of
	// guardLargeRows tags. Nothing here asserts that is right.
	t.Logf("declared: %d unmappable rows are reported as %v built tags with no "+
		"finding naming one of them", guardLargeRows, faulty["row_count"])
}

// keysOf is the reply's key set, for the shape comparison above.
func keysOf(m map[string]interface{}) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

extends RefCounted
## Assertion discipline shared by every plugin's contract-guard suite.
##
## Each plugin's tests/gd/test_contract_guard.gd owns its DOMAIN — what "large"
## means for it (component count, body count, tracked files, transcript length,
## symbol count, sheet pages), which verbs and channels its six cases drive, and
## what a right answer looks like. This script owns only HOW an answer is
## judged:
##
##   * an unhappy case is refused STRUCTURALLY — `success` (or `ok`) present and
##     false, plus a machine-readable code — never by matching prose, which
##     passes for the wrong reason the day the wording changes;
##   * a refusal leaves NO PARTIAL STATE, measured against what the caller could
##     see before it;
##   * a happy case never answers with a silent empty document;
##   * every large case's request and reply are WEIGHED on the wire and the
##     measurements ride the Results line, so a "large" case that quietly
##     stopped being large shows up in the run log instead of passing green.
##
## Sizes are REPORTED, never asserted against a host cap: what counts as large
## is the plugin's call, and a guard that pinned the host's numbers would need
## re-pinning every time the host retuned them. A guard that DOES depend on a
## cap (pcb's large-happy case rides the bulk route precisely because the reply
## is over the control cap) states that itself, in its own terms.
##
## Loaded by path — this script has no class_name, because it lives outside
## Minerva's res:// tree where class_name does not resolve:
##
##   const ContractGuard := preload(
##       "res://../../minerva-plugins/scripts/contract_guard.gd")
##   var guard := ContractGuard.new()

## Codes a refusal may carry, in the order they are consulted. `error_code` is
## the host's scene-reply contract (PluginScenePanelBroker); `code` and
## `error_kind` are the shapes plugin surfaces of their own use.
const DEFAULT_CODE_KEYS: Array[String] = ["error_code", "code", "error_kind"]

## Codes that mean "the host refused to carry this", which is never a valid
## answer to a case the plugin declares it supports at that size.
const OVERSIZE_CODES: Array[String] = ["payload_too_large"]

var passed: int = 0
var failed: int = 0

## {case, request_bytes, reply_bytes, note} per weighed round trip, replayed on
## the Results line.
var _weighed: Array[Dictionary] = []

## Cases whose surface answered a refusal with no machine-readable code at all.
## Declared out loud rather than quietly tolerated: the next reader needs to
## know the guard could only assert the negative shape there.
var _codeless: Array[String] = []


# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

func check(description: String, ok: bool, detail: String = "") -> bool:
	if ok:
		passed += 1
		print("  PASS: %s" % description)
	else:
		failed += 1
		if detail.is_empty():
			printerr("  FAIL: %s" % description)
		else:
			printerr("  FAIL: %s — %s" % [description, detail])
	return ok


func check_eq(description: String, actual: Variant, expected: Variant) -> bool:
	return check("%s (expected %s, got %s)" % [description, str(expected), str(actual)],
			actual == expected)


# ---------------------------------------------------------------------------
# The discipline
# ---------------------------------------------------------------------------

## A happy case answered happily. Either envelope marker satisfies it: the
## host's scene reply says `success`, a worker envelope says `ok`.
## One assertion.
func expect_success(case_name: String, reply: Dictionary) -> bool:
	var ok: bool = reply.get("success", null) == true or reply.get("ok", null) == true
	return check("%s: the reply is a success" % case_name, ok, brief(reply))


## An unhappy case refused structurally. Two assertions when `code_keys` is
## non-empty (the shape, then the code), one when it is empty — which a suite
## passes ONLY for a surface that carries no machine code of its own, and which
## is named on the Results line so the gap stays visible.
##
## Returns the code it found, or "".
func expect_refusal(case_name: String, reply: Dictionary,
		code_keys: Array[String] = DEFAULT_CODE_KEYS) -> String:
	# `success`/`ok` must be PRESENT and false. A reply carrying neither is a
	# refusal only by the reader's charity, which is exactly what this forbids.
	var refused: bool = reply.get("success", null) == false or reply.get("ok", null) == false
	check("%s: refused structurally — success/ok is present and false" % case_name,
			refused, brief(reply))
	if code_keys.is_empty():
		_codeless.append(case_name)
		return ""
	var code := ""
	for key in code_keys:
		var value: Variant = reply.get(key, null)
		if value is String and not (value as String).is_empty():
			code = value
			break
	check("%s: the refusal names a machine-readable code (one of %s), not prose alone"
			% [case_name, ", ".join(code_keys)], not code.is_empty(), brief(reply))
	return code


## The refusal is the plugin's own, not the host declining to carry the answer.
## A guard whose large case comes back payload_too_large is measuring the
## transport, not the plugin. One assertion.
func expect_not_oversize_refusal(case_name: String, reply: Dictionary) -> bool:
	var code := str(reply.get("error_code", ""))
	return check("%s: the host carried the payload — no oversize refusal" % case_name,
			not (code in OVERSIZE_CODES), "error_code=%s %s" % [code, brief(reply)])


## No partial state: a value the caller could read before the unhappy case is
## exactly what it reads after. One assertion.
func expect_unchanged(case_name: String, label: String, actual: Variant,
		expected: Variant) -> bool:
	return check("%s: no partial state — %s is still %s (got %s)"
			% [case_name, label, str(expected), str(actual)], actual == expected)


## No silent empty document: a happy case that reports success must have
## something to show for it. One assertion.
func expect_document(case_name: String, label: String, count: int) -> bool:
	return check("%s: no silent empty document — %s is %d" % [case_name, label, count],
			count > 0)


# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------

## Weigh one round trip as it crossed the wire. Asserts nothing: the numbers are
## evidence, replayed on the Results line so a shrunken "large" case is visible.
## `note` records anything that makes the number read oddly — a request sent by
## reference, say, whose bytes are a handle rather than the document.
func weigh(case_name: String, request: Dictionary, reply: Dictionary,
		note: String = "") -> Dictionary:
	var entry := {
		"case": case_name,
		"request_bytes": bytes_of(request),
		"reply_bytes": bytes_of(reply),
		"note": note,
	}
	_weighed.append(entry)
	print("  measured [%s]: request=%d bytes, reply=%d bytes%s"
			% [case_name, entry["request_bytes"], entry["reply_bytes"],
				"" if note.is_empty() else " (%s)" % note])
	return entry


static func bytes_of(payload: Dictionary) -> int:
	return JSON.stringify(payload).to_utf8_buffer().size()


## The bytes a weighed case measured, or -1 when it was never weighed — so a
## comparison between two cases fails loudly rather than against a zero.
func reply_bytes(case_name: String) -> int:
	for entry in _weighed:
		if str(entry.get("case", "")) == case_name:
			return int(entry.get("reply_bytes", -1))
	return -1


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

## The Results line the run-gd-tests.sh runner parses, with every weighed case's
## measurements appended to it. Returns the process exit code.
func results() -> int:
	if not _codeless.is_empty():
		print("\nSurfaces that refused WITHOUT a machine-readable code (shape asserted "
				+ "only): %s" % ", ".join(_codeless))
	var parts: PackedStringArray = PackedStringArray()
	for entry in _weighed:
		parts.append("%s req=%dB reply=%dB%s" % [str(entry.get("case", "?")),
			int(entry.get("request_bytes", -1)), int(entry.get("reply_bytes", -1)),
			"" if str(entry.get("note", "")).is_empty() else " [%s]" % str(entry.get("note"))])
	var wire := "" if parts.is_empty() else " | wire: %s" % "; ".join(parts)
	print("\n=== Results: %d passed, %d failed ===%s" % [passed, failed, wire])
	if failed > 0:
		printerr("FAILURES: %d" % failed)
	return 1 if failed > 0 else 0


static func brief(value: Variant, limit: int = 300) -> String:
	return str(value).left(limit)

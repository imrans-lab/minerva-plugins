extends RefCounted
## PcbTraceWidth — THE one rule for how wide a piece of routed copper is when
## the thing that produced it did not say.
##
## A missing width is RESOLVED, never invented. The twin of PcbViaDimensions
## (same shape, same "0.0 means nobody has said yet" contract) with one
## deliberate difference: there is NO last-resort constant. A via that nobody
## sized still has to be a hole, so a constant is the honest floor there; a
## trace that nobody sized is not copper at all, and stamping a house number on
## it would put a width nobody chose onto a fabricated board.
##
## ── PRECEDENCE ───────────────────────────────────────────────────────────────
## Callers resolve the sources they own first — an explicit caller option, the
## router's own per-route/per-segment stamp, a hint-authored width — and reach
## here only when all of those are silent. This file then answers with the
## BOARD's own two sources, in the same order the router uses:
##   1. the net's ESTABLISHED copper — the widest trace already on that net. A
##      new span joining 0.8mm copper at the board's 0.25mm default is a quarter
##      the width of what it joins and still passes every minimum-only gate.
##   2. `design_rules.trace_width_mm` — the board's blanket answer.
##   3. nothing: {"width": 0.0, "source": "unresolved"}, which the commit
##      pre-flight refuses by name.
##
## Off-tree plugin: NO class_name; reached by relative preload.

## Source label for a width taken from the net's own existing copper. Matches
## the worker's vocabulary (methods.py stamps the same string) so one word means
## one thing on both sides of the seam.
const SOURCE_NET_COPPER := "net_copper"

## Source label for a width taken from `design_rules.trace_width_mm`.
const SOURCE_DESIGN_RULES := "design_rules"

## Source label for "no source had an answer" — the width is 0.0.
const SOURCE_UNRESOLVED := "unresolved"


## Resolve {width, source} from a board's design_rules dict and a net's existing
## copper widths. `net_widths` is every width already on the net (any order);
## the WIDEST wins, matching route_bridge.established_net_widths.
static func resolve(design_rules, net_widths: Array = []) -> Dictionary:
	var widest := 0.0
	for w in net_widths:
		var fw := float(w)
		if fw > widest:
			widest = fw
	if widest > 0.0:
		return {"width": widest, "source": SOURCE_NET_COPPER}
	var dr: Dictionary = design_rules if design_rules is Dictionary else {}
	var rule := float(dr.get("trace_width_mm", 0.0))
	if rule > 0.0:
		return {"width": rule, "source": SOURCE_DESIGN_RULES}
	return {"width": 0.0, "source": SOURCE_UNRESOLVED}


## resolve() against a live board object (duck-typed, same seam as
## PcbViaDimensions.from_board: anything exposing `design_rules` and
## `get_traces_for_net`). A null/rule-less board with no copper on the net
## resolves to unresolved — the honest headless answer.
static func from_board(board, net: String) -> Dictionary:
	if board == null or not is_instance_valid(board):
		return {"width": 0.0, "source": SOURCE_UNRESOLVED}
	var net_widths: Array = []
	if not net.is_empty() and board.has_method("get_traces_for_net"):
		for trace in board.get_traces_for_net(net):
			if trace != null and "width" in trace:
				net_widths.append(float(trace.width))
	var dr = board.design_rules if "design_rules" in board else null
	return resolve(dr, net_widths)

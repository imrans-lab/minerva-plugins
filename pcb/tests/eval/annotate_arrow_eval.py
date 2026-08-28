#!/usr/bin/env python3
"""Scripted LLM eval: can a worker put an arrow ON the pad it was asked to point at?

WHAT IT MEASURES
    The pcb skill (`minerva_pcb_design`) now teaches annotation authoring. This
    eval is the falsifier for that claim. It spawns a Minerva worker WITH the
    skill, gives it one natural-language instruction, and grades the annotation
    that comes back against the board itself -- not against the worker's prose.

    PASS BAR: 3 armed runs, 3/3 must pass. A control run WITHOUT the skill is
    executed and recorded for comparison; it is NOT required to fail (a model
    that gets this right unaided is good news, not a broken eval).

GRADING (all four must hold for a run to pass)
    1. exactly one annotation was added by the run
    2. its kind is 2d_arrow
    3. annotations_list reports anchor_detail {kind: "pad", id: <target ref>}
       -- this is the board's own hit test, not the worker's claim
    4. the arrow primitive's `to` (the TIP) is within 0.5 mm of the pad position
       pin_info reports, i.e. the arrow points AT the pad rather than away

PRECONDITIONS
    * Minerva is running with its HTTP MCP server up (default port 9315).
    * A PCB editor tab has worker/tests/testdata/hitl_bench.yaml loaded. The
      default target R8A.1 is bench row R8 cell A, pin 1 at (22.0, 92.95) --
      see docs/hitl_bench.md. Bench row SUBJECTS are retired and re-used over
      time, so pass --pad-ref/--editor for any other board; the eval reads the
      pad's true position from minerva_pcb_pin_info and never assumes it.
    * Worker spawning must not be gated on human approval for the parent chat
      (minerva_set_worker_budget approval_after=-1), or the runs will hang.

HOW TO RUN
    python3 pcb/tests/eval/annotate_arrow_eval.py
    python3 pcb/tests/eval/annotate_arrow_eval.py \
        --editor "hitl_bench" --pad-ref R8A.1 --runs 3 --report /tmp/eval.json

    Exit status: 0 when every armed run passed, 1 otherwise. The JSON report
    (stdout, and --report if given) carries each run's verdict and the reason a
    failing run failed, so a regression names itself.

    The eval deletes the annotations it caused so runs stay independent; it
    never touches annotations that existed before it started.
"""
import argparse
import json
import sys
import time
import urllib.request

DEFAULT_ENDPOINT = "http://localhost:9315/mcp"
DEFAULT_PAD_REF = "R8A.1"
TIP_TOLERANCE_MM = 0.5

TASK = (
    "Put an arrow pointing at pad {ref} on the open board in the PCB editor tab "
    "named '{editor}', labelled 'here'. Add exactly one annotation, then stop."
)
SYSTEM_PROMPT = (
    "You are annotating a PCB board that is already open in a Minerva editor tab. "
    "Do exactly what you are asked and nothing more. Report the annotation id you created."
)


# ── MCP transport ─────────────────────────────────────────────────────────────

class Mcp:
    """Minimal JSON-RPC-over-HTTP client for Minerva's own MCP endpoint."""

    def __init__(self, endpoint):
        self.endpoint = endpoint
        self.session_id = ""
        self._next_id = 0

    def _rpc(self, method, params):
        self._next_id += 1
        body = json.dumps({
            "jsonrpc": "2.0", "id": self._next_id,
            "method": method, "params": params,
        }).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.session_id:
            headers["MCP-Session-Id"] = self.session_id
        req = urllib.request.Request(self.endpoint, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=300) as resp:
            sid = resp.headers.get("MCP-Session-Id")
            if sid:
                self.session_id = sid
            raw = resp.read().decode("utf-8")
        if not raw:
            return {}
        parsed = json.loads(raw)
        if "error" in parsed:
            raise RuntimeError("%s: %s" % (method, parsed["error"]))
        return parsed.get("result", {})

    def initialize(self):
        self._rpc("initialize", {
            "protocolVersion": "2025-06-18",
            "clientInfo": {"name": "pcb-annotate-eval", "version": "1"},
            "capabilities": {},
        })

    def call(self, tool, args):
        """Call a tool and return its decoded payload.

        Minerva wraps every reply as {content: [{type: text, text: "<json>"}]},
        and reports tool-level failure as isError rather than a JSON-RPC error.
        """
        result = self._rpc("tools/call", {"name": tool, "arguments": args})
        content = result.get("content") or []
        text = content[0].get("text", "") if content else ""
        try:
            payload = json.loads(text)
        except (ValueError, TypeError):
            payload = {"text": text}
        if result.get("isError"):
            raise RuntimeError("%s failed: %s" % (tool, text[:400]))
        return payload


# ── board facts ───────────────────────────────────────────────────────────────

def pad_position(mcp, editor, ref):
    """The pad's true position in board mm, from the board itself."""
    row = mcp.call("minerva_pcb_pin_info", {"editor_name": editor, "ref": ref})
    pos = row.get("position") or {}
    if "x_mm" not in pos or "y_mm" not in pos:
        raise RuntimeError("pin_info gave no position for %s: %s" % (ref, json.dumps(row)[:300]))
    return float(pos["x_mm"]), float(pos["y_mm"])


def list_annotations(mcp, editor):
    reply = mcp.call("minerva_annotations_list", {"editor_name": editor})
    return reply.get("annotations", [])


def arrow_tip(annotation):
    """The arrow primitive's `to` -- the tip, which is what must be on the pad."""
    for prim in annotation.get("primitives", []):
        if isinstance(prim, dict) and prim.get("kind") == "arrow":
            to = prim.get("to")
            if isinstance(to, list) and len(to) >= 2:
                return float(to[0]), float(to[1])
    return None


def grade(added, pad_ref, pad_xy):
    """Return (passed, reason). `added` is the annotations this run created."""
    if len(added) != 1:
        return False, "expected exactly 1 new annotation, got %d" % len(added)
    ann = added[0]
    if ann.get("kind") != "2d_arrow":
        return False, "wrong kind: %s (an arrow points AT things)" % ann.get("kind")
    detail = ann.get("anchor_detail") or {}
    if detail.get("kind") != "pad" or detail.get("id") != pad_ref:
        return False, "anchor_detail resolved to %s, not pad %s" % (json.dumps(detail), pad_ref)
    tip = arrow_tip(ann)
    if tip is None:
        return False, "no arrow primitive with a `to` endpoint"
    dist = ((tip[0] - pad_xy[0]) ** 2 + (tip[1] - pad_xy[1]) ** 2) ** 0.5
    if dist > TIP_TOLERANCE_MM:
        return False, "tip is %.3f mm from the pad (tolerance %.1f) -- arrow points away" % (
            dist, TIP_TOLERANCE_MM)
    return True, "tip %.3f mm from pad; anchor_detail names it" % dist


# ── one run ───────────────────────────────────────────────────────────────────

def run_once(mcp, editor, pad_ref, pad_xy, armed, timeout_s, poll_s):
    before = {a.get("id") for a in list_annotations(mcp, editor)}

    spawn_args = {
        "name": "annotate-eval-%s" % ("armed" if armed else "control"),
        "system_prompt": SYSTEM_PROMPT,
        "task": TASK.format(ref=pad_ref, editor=editor),
        "max_tool_rounds": 12,
        "timeout_seconds": timeout_s,
    }
    if armed:
        spawn_args["skills"] = ["minerva_pcb_design"]
    spawned = mcp.call("minerva_spawn_worker", spawn_args)
    worker_id = spawned.get("worker_id")
    if not worker_id:
        raise RuntimeError("spawn returned no worker_id: %s" % json.dumps(spawned)[:300])

    deadline = time.time() + timeout_s
    status = "unknown"
    while time.time() < deadline:
        time.sleep(poll_s)
        state = mcp.call("minerva_check_worker", {"worker_id": worker_id})
        status = str(state.get("status", "")).lower()
        if status in ("complete", "completed", "done", "finished", "failed", "error", "timeout"):
            break

    added = [a for a in list_annotations(mcp, editor) if a.get("id") not in before]
    passed, reason = grade(added, pad_ref, pad_xy)

    # Leave the board as we found it, whatever the verdict.
    for ann in added:
        try:
            mcp.call("minerva_annotations_delete", {"editor_name": editor, "id": ann.get("id")})
        except RuntimeError:
            pass

    return {
        "armed": armed,
        "worker_id": worker_id,
        "worker_status": status,
        "passed": passed,
        "reason": reason,
        "annotations_added": len(added),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    ap.add_argument("--editor", default="", help="PCB editor tab name; discovered when omitted")
    ap.add_argument("--pad-ref", default=DEFAULT_PAD_REF, help='Target pad, "COMPONENT.PIN"')
    ap.add_argument("--runs", type=int, default=3, help="Armed runs; all must pass")
    ap.add_argument("--timeout", type=float, default=300.0, help="Per-run worker timeout, seconds")
    ap.add_argument("--poll", type=float, default=5.0, help="Worker poll interval, seconds")
    ap.add_argument("--report", default="", help="Write the JSON report here as well as stdout")
    args = ap.parse_args()

    mcp = Mcp(args.endpoint)
    mcp.initialize()

    editor = args.editor
    if not editor:
        editors = mcp.call("minerva_list_editors", {}).get("editors", [])
        pcb_tabs = [e for e in editors if "pcb" in json.dumps(e).lower()]
        if len(pcb_tabs) != 1:
            raise SystemExit("pass --editor: found %d candidate PCB tabs" % len(pcb_tabs))
        editor = pcb_tabs[0].get("name") or pcb_tabs[0].get("title", "")

    pad_xy = pad_position(mcp, editor, args.pad_ref)

    runs = [run_once(mcp, editor, args.pad_ref, pad_xy, True, args.timeout, args.poll)
            for _ in range(args.runs)]
    control = run_once(mcp, editor, args.pad_ref, pad_xy, False, args.timeout, args.poll)

    armed_passed = sum(1 for r in runs if r["passed"])
    report = {
        "editor": editor,
        "pad_ref": args.pad_ref,
        "pad_position_mm": list(pad_xy),
        "tip_tolerance_mm": TIP_TOLERANCE_MM,
        "armed": {"passed": armed_passed, "of": len(runs), "runs": runs},
        "control": control,
        "verdict": "PASS" if armed_passed == len(runs) else "FAIL",
    }
    text = json.dumps(report, indent=2)
    print(text)
    if args.report:
        with open(args.report, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    return 0 if armed_passed == len(runs) else 1


if __name__ == "__main__":
    sys.exit(main())

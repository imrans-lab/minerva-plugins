"""Assertion discipline shared by the PYTHON-side contract guards.

The sibling of scripts/contract_guard.gd, holding the same rules for plugins
whose honest test seam is a Python unittest rather than a GDScript suite. One
file per language, never one per plugin: the discipline is the thing that must
not drift.

Each plugin's guard owns its DOMAIN — what "large" means for it, which calls
its six cases drive, and what a right answer looks like. This owns only HOW an
answer is judged:

  * an unhappy case is refused STRUCTURALLY — an explicit failure status plus a
    machine-readable code — never by matching prose, which passes for the wrong
    reason the day the wording changes;
  * a refusal leaves NO PARTIAL STATE, measured against what the caller could
    see before it;
  * a happy case never answers with a silent empty document;
  * every large case's request and reply are WEIGHED and the measurements are
    printed, so a "large" case that quietly stopped being large shows up in the
    run log instead of passing green.

Sizes are REPORTED, never asserted against a host cap: what counts as large is
the plugin's call. A guard that DOES depend on a bound states that itself, in
its own terms.

Used from a unittest.TestCase:

    import sys, pathlib
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "scripts"))
    from contract_guard import ContractGuard

    guard = ContractGuard(self, sink=self.WEIGHED)   # one sink per test class
    guard.expect_refusal("small-unhappy", reply, code_keys=("error.kind",))
"""

from __future__ import annotations

import json
from typing import Any, Iterable, Sequence

#: Where a refusal's code may live, in the order the keys are consulted. A key
#: may name a path through nested dictionaries with dots, because where a plugin
#: keeps its code is the plugin's business — that it HAS one is not.
DEFAULT_CODE_KEYS: Sequence[str] = ("error_code", "code", "error.kind", "error.code")

#: Statuses that mean "this failed", whatever the plugin calls its field.
FAILURE_MARKERS = ("error", "failed", "failure")


def bytes_of(payload: Any) -> int:
    """What this payload weighs on the wire, in UTF-8 bytes."""
    return len(json.dumps(payload).encode("utf-8"))


def at_path(reply: Any, key: str) -> Any:
    """The value at a dotted path through nested mappings, or None."""
    value = reply
    for step in key.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(step)
    return value


def brief(value: Any, limit: int = 300) -> str:
    text = value if isinstance(value, str) else json.dumps(value, default=str)
    return text[:limit]


class ContractGuard:
    """The discipline, bound to one unittest.TestCase (or its class).

    Every method asserts through the case, so a breach fails the test it is in
    with the guard's own wording rather than a bare comparison.
    """

    def __init__(self, case, sink: list | None = None):
        self._case = case
        # A shared sink lets every test in a class weigh into one list, so the
        # measurements can be reported together once the cases have run.
        self._weighed: list[dict] = sink if sink is not None else []

    # -- the discipline ----------------------------------------------------

    def expect_success(self, case_name: str, reply: dict) -> None:
        """A happy case answered happily, by an explicit marker and not by the
        absence of an error."""
        status = reply.get("status", reply.get("ok", reply.get("success")))
        ok = status == "ok" or status is True
        self._case.assertTrue(
            ok, "%s: the reply is not an explicit success — %s"
            % (case_name, brief(reply)))

    def expect_refusal(self, case_name: str, reply: dict,
                       code_keys: Iterable[str] = DEFAULT_CODE_KEYS) -> str:
        """An unhappy case refused structurally. Returns the code it found.

        An empty `code_keys` is how a surface DECLARES that it carries no
        machine code; the shape is then all that is asserted, and the guard's
        report names the case so the gap stays visible.
        """
        status = reply.get("status", reply.get("ok", reply.get("success")))
        refused = status in FAILURE_MARKERS or status is False
        self._case.assertTrue(
            refused,
            "%s: not refused structurally — an explicit failure status must be "
            "present, got %s" % (case_name, brief(reply)))
        keys = tuple(code_keys)
        if not keys:
            print("  DECLARED: %s refuses without a machine-readable code" % case_name)
            return ""
        for key in keys:
            value = at_path(reply, key)
            if isinstance(value, str) and value:
                return value
        self._case.fail(
            "%s: the refusal names no machine-readable code (looked at %s) — %s"
            % (case_name, ", ".join(keys), brief(reply)))
        return ""

    def expect_not_oversize_refusal(self, case_name: str, reply: dict,
                                    codes: Iterable[str] = ("payload_too_large",)) -> None:
        """The refusal is the plugin's own, not the transport declining to
        carry the answer."""
        code = str(reply.get("error_code", "") or at_path(reply, "error.kind") or "")
        self._case.assertNotIn(
            code, tuple(codes),
            "%s: the transport refused to carry the payload (%s)" % (case_name, code))

    def expect_unchanged(self, case_name: str, label: str,
                         actual: Any, expected: Any) -> None:
        """No partial state: what the caller could read before the unhappy case
        is exactly what it reads after."""
        self._case.assertEqual(
            actual, expected,
            "%s: partial state — %s should still be %s" % (case_name, label, expected))

    def expect_document(self, case_name: str, label: str, count: int) -> None:
        """No silent empty document: a happy case that reports success has
        something to show for it."""
        self._case.assertGreater(
            count, 0, "%s: silent empty document — %s is %d"
            % (case_name, label, count))

    # -- measurement -------------------------------------------------------

    def weigh(self, case_name: str, request: Any, reply: Any,
              note: str = "") -> dict:
        """Weigh one round trip. Asserts nothing: the numbers are evidence."""
        entry = {
            "case": case_name,
            "request_bytes": bytes_of(request),
            "reply_bytes": bytes_of(reply),
            "note": note,
        }
        self._weighed.append(entry)
        print("  measured [%s]: request=%d bytes, reply=%d bytes%s"
              % (case_name, entry["request_bytes"], entry["reply_bytes"],
                 "" if not note else " (%s)" % note))
        return entry

    def reply_bytes(self, case_name: str) -> int:
        """The bytes a weighed case measured, or -1 — so a comparison between
        two cases fails loudly rather than against a zero."""
        for entry in self._weighed:
            if entry["case"] == case_name:
                return entry["reply_bytes"]
        return -1

    def report(self, title: str) -> None:
        """The measurements line, printed once a guard has run its cases."""
        if not self._weighed:
            return
        parts = ["%s req=%dB reply=%dB%s"
                 % (e["case"], e["request_bytes"], e["reply_bytes"],
                    "" if not e["note"] else " [%s]" % e["note"])
                 for e in self._weighed]
        print("\n=== %s === | wire: %s" % (title, "; ".join(parts)))

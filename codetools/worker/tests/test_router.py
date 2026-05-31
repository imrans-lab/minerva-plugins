"""Unit tests for the worker router (codetools_worker.router)."""

import unittest

from codetools_worker import envelope, router
from codetools_worker.errors import MethodError, ToolError


class TestRouter(unittest.TestCase):
    def test_ping_returns_valid_ok_envelope(self):
        env = router.route("ping", {})
        envelope.validate(env)  # raises if malformed
        self.assertEqual(env["status"], "ok")
        self.assertEqual(len(env["artifacts"]), 1)
        info = env["artifacts"][0]
        self.assertTrue(info["pong"])
        self.assertEqual(info["worker"], "codetools")

    def test_ping_echoes(self):
        env = router.route("ping", {"echo": "xyz"})
        self.assertEqual(env["artifacts"][0]["echo"], "xyz")

    def test_ping_tolerates_none_params(self):
        env = router.route("ping", None)
        self.assertEqual(env["status"], "ok")

    def test_unknown_method_raises_method_error(self):
        with self.assertRaises(MethodError):
            router.route("does_not_exist", {})

    def test_tool_error_becomes_error_envelope(self):
        # Temporarily register a handler that raises a ToolError, and prove the
        # router converts it to a status='error' envelope (not a transport fault).
        def boom(_params):
            raise ToolError("nope", kind="parse")

        router.ROUTES["__test_boom__"] = boom
        try:
            env = router.route("__test_boom__", {})
        finally:
            del router.ROUTES["__test_boom__"]
        envelope.validate(env)
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "parse")
        self.assertEqual(env["error"]["message"], "nope")

    def test_handler_returning_error_envelope_passes_through(self):
        # A handler may build a status='error' envelope directly (not via
        # ToolError); the router must validate and pass it through unchanged.
        def sad(_params):
            return envelope.error("could not do the thing", kind="notfound")

        router.ROUTES["__test_sad__"] = sad
        try:
            env = router.route("__test_sad__", {})
        finally:
            del router.ROUTES["__test_sad__"]
        envelope.validate(env)
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "notfound")

    def test_malformed_handler_result_is_rejected(self):
        def bad(_params):
            return {"not": "an envelope"}

        router.ROUTES["__test_bad__"] = bad
        try:
            with self.assertRaises(ValueError):
                router.route("__test_bad__", {})
        finally:
            del router.ROUTES["__test_bad__"]


if __name__ == "__main__":
    unittest.main()

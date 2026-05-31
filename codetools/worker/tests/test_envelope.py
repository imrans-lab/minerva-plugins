"""Unit tests for the unified result envelope (codetools_worker.envelope)."""

import unittest

from codetools_worker import envelope


class TestEnvelope(unittest.TestCase):
    def test_ok_has_all_required_fields(self):
        env = envelope.ok("done")
        for field in envelope.REQUIRED_FIELDS:
            self.assertIn(field, env)
        self.assertEqual(env["status"], "ok")
        self.assertEqual(env["summary"], "done")
        self.assertEqual(env["artifacts"], [])
        self.assertEqual(env["evidence_handles"], [])
        self.assertEqual(env["follow_ups"], [])
        self.assertNotIn("error", env)

    def test_ok_carries_lists(self):
        env = envelope.ok("x", artifacts=[{"a": 1}], follow_ups=["next"])
        self.assertEqual(env["artifacts"], [{"a": 1}])
        self.assertEqual(env["follow_ups"], ["next"])

    def test_error_carries_error_object(self):
        env = envelope.error("boom", kind="parse")
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"], {"kind": "parse", "message": "boom"})
        # error envelopes are still well-formed (lists present).
        self.assertEqual(env["artifacts"], [])

    def test_validate_round_trip(self):
        env = envelope.ok("good")
        self.assertIs(envelope.validate(env), env)
        err = envelope.error("bad")
        self.assertIs(envelope.validate(err), err)

    def test_validate_rejects_non_dict(self):
        with self.assertRaises(ValueError):
            envelope.validate("nope")

    def test_validate_rejects_missing_field(self):
        env = envelope.ok("x")
        del env["artifacts"]
        with self.assertRaises(ValueError):
            envelope.validate(env)

    def test_validate_rejects_bad_status(self):
        env = envelope.ok("x")
        env["status"] = "weird"
        with self.assertRaises(ValueError):
            envelope.validate(env)

    def test_validate_rejects_non_list_field(self):
        env = envelope.ok("x")
        env["artifacts"] = {"not": "a list"}
        with self.assertRaises(ValueError):
            envelope.validate(env)

    def test_validate_rejects_error_status_without_error_obj(self):
        env = envelope.ok("x")
        env["status"] = "error"
        with self.assertRaises(ValueError):
            envelope.validate(env)


if __name__ == "__main__":
    unittest.main()

"""P3.6 — Option B replay test: attach→validate round-trip with NO live Godot.

Copies the committed probe-state fixture into a temp dir, drives the P3.2
sightline_probe adapter through the full attach→validate cycle, and asserts
that the replay round-trips correctly without requiring a running Godot editor.
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

_WORKER_ROOT = Path(__file__).parent.parent
if str(_WORKER_ROOT) not in sys.path:
    sys.path.insert(0, str(_WORKER_ROOT))

from codetools_worker import envelope
from codetools_worker import sightline_probe
from codetools_worker.sightline_probe import inspect, validate

_FIXTURE = (
    Path(__file__).parent
    / "fixtures"
    / "probe"
    / "debugger_state.v3.json"
)

_MARKER = "probe_fixture_marker"


class ProbeReplayTest(unittest.TestCase):
    """Option B replay: fixture → attach → validate — no live Godot needed."""

    def setUp(self):
        # Fresh temp dir acts as the sightline root (stores .sightline/inspect/).
        self.tmpdir = tempfile.mkdtemp(prefix="ct_p36_replay_")
        # Copy the fixture into the temp dir so artifact paths are local.
        self.fixture_copy = Path(self.tmpdir) / "debugger_state.v3.json"
        shutil.copy2(str(_FIXTURE), str(self.fixture_copy))
        # Reset sightline import state so tearDown can clear it cleanly.
        sightline_probe._sightline_imported = False

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)
        # Clear module-level import cache so tests remain independent.
        sightline_probe._sightline_imported = False
        sightline_probe._explore = None
        sightline_probe._search_mod = None
        sightline_probe._files_mod = None
        sightline_probe._inspect_mod = None
        sightline_probe._validate_mod = None
        sightline_probe._models_mod = None
        sightline_probe._godot_plugin = None

    def _valid_envelope(self, env, label=""):
        try:
            envelope.validate(env)
        except ValueError as exc:
            self.fail("Envelope invalid%s: %s\nEnvelope: %r" % (
                " (%s)" % label if label else "", exc, env
            ))
        return env

    # ------------------------------------------------------------------
    # Core round-trip: attach → inspect artifact_id → validate
    # ------------------------------------------------------------------

    def test_attach_creates_session_and_artifact(self):
        """attach op with the fixture path must produce a valid inspect_result."""
        env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "surface_kind": "path",
            "artifacts": [["runtime_issue_report", str(self.fixture_copy)]],
        })
        self._valid_envelope(env, "attach")
        self.assertEqual(env["status"], "ok")

        art = env["artifacts"][0]
        self.assertEqual(art["type"], "inspect_result")
        self.assertIn("session_id", art)
        self.assertIn("artifacts", art)
        self.assertEqual(len(art["artifacts"]), 1)
        self.assertEqual(art["artifacts"][0]["kind"], "runtime_issue_report")

    def test_attach_returns_existing_artifact_id(self):
        """The artifact_id returned by attach is present and non-empty."""
        env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "surface_kind": "path",
            "artifacts": [["runtime_issue_report", str(self.fixture_copy)]],
        })
        self._valid_envelope(env, "attach")
        artifact_id = env["artifacts"][0]["artifacts"][0]["artifact_id"]
        self.assertTrue(artifact_id, "artifact_id must be a non-empty string")
        self.assertTrue(artifact_id.startswith("a_"), "artifact_id should start with 'a_'")

    def test_validate_round_trip_marker_found(self):
        """Full attach→validate round-trip: marker text must be found in the fixture."""
        # Step 1 — attach the fixture as a runtime_issue_report artifact.
        attach_env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "surface_kind": "path",
            "artifacts": [["runtime_issue_report", str(self.fixture_copy)]],
        })
        self._valid_envelope(attach_env, "attach")
        artifact_id = attach_env["artifacts"][0]["artifacts"][0]["artifact_id"]

        # Step 2 — validate: artifact_only=True, look for the marker string.
        val_env = validate({
            "goal": "probe captured the editor state",
            "root": self.tmpdir,
            "artifact_ids": [artifact_id],
            "artifact_only": True,
            "expected_artifact_text": [_MARKER],
        })
        self._valid_envelope(val_env, "validate")
        self.assertEqual(val_env["status"], "ok")

        art = val_env["artifacts"][0]
        self.assertEqual(art["type"], "validation_result")

        # The expected_artifact_text check must have found the marker.
        checks_by_name = {c["name"]: c for c in art["checks"]}
        self.assertIn(
            "expected_artifact_text",
            checks_by_name,
            msg="expected_artifact_text check missing from validation result",
        )
        self.assertEqual(
            checks_by_name["expected_artifact_text"]["status"],
            "pass",
            msg="Marker %r was not found in the fixture artifact text. "
                "Check: %r" % (_MARKER, checks_by_name["expected_artifact_text"]),
        )

    def test_validate_returns_coherent_validation_result(self):
        """validate always returns a well-formed validation_result artifact."""
        attach_env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "surface_kind": "path",
            "artifacts": [["runtime_issue_report", str(self.fixture_copy)]],
        })
        self._valid_envelope(attach_env, "attach")
        artifact_id = attach_env["artifacts"][0]["artifacts"][0]["artifact_id"]

        val_env = validate({
            "goal": "probe captured the editor state",
            "root": self.tmpdir,
            "artifact_ids": [artifact_id],
            "artifact_only": True,
            "expected_artifact_text": [_MARKER],
        })
        self._valid_envelope(val_env, "validate")

        art = val_env["artifacts"][0]
        # All required ValidationResultRecord fields must be present.
        for field_name in [
            "validation_id",
            "status",
            "confidence",
            "checks",
            "reason_summary",
            "evidence_used",
            "gaps",
            "recommended_next_step",
        ]:
            self.assertIn(
                field_name,
                art,
                msg="validation_result missing required field: %r" % field_name,
            )

        # checks is a list of dicts, each with name/status/evidence/detail.
        self.assertIsInstance(art["checks"], list)
        self.assertGreater(len(art["checks"]), 0)
        for check in art["checks"]:
            self.assertIn("name", check)
            self.assertIn("status", check)
            self.assertIn("evidence", check)
            self.assertIn("detail", check)

        # The artifact_id must appear in evidence_used (referenced by the artifact).
        self.assertIn(
            artifact_id,
            art["evidence_used"],
            msg="artifact_id not in evidence_used — validate did not see the artifact",
        )

    def test_validate_artifact_references_session(self):
        """The artifact created by attach is visible via op=list for its session."""
        attach_env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "surface_kind": "path",
            "artifacts": [["runtime_issue_report", str(self.fixture_copy)]],
        })
        self._valid_envelope(attach_env, "attach")
        session_id = attach_env["artifacts"][0]["session_id"]
        artifact_id = attach_env["artifacts"][0]["artifacts"][0]["artifact_id"]

        list_env = inspect({
            "op": "list",
            "root": self.tmpdir,
            "session_id": session_id,
        })
        self._valid_envelope(list_env, "list")
        list_art = list_env["artifacts"][0]
        self.assertEqual(list_art["type"], "inspect_artifacts")
        self.assertEqual(list_art["session_id"], session_id)
        self.assertEqual(list_art["count"], 1)
        listed_id = list_art["artifacts"][0]["artifact_id"]
        self.assertEqual(listed_id, artifact_id)

    def test_validate_without_marker_fails_text_check(self):
        """If expected_artifact_text is absent from the fixture, the check fails."""
        attach_env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "surface_kind": "path",
            "artifacts": [["runtime_issue_report", str(self.fixture_copy)]],
        })
        self._valid_envelope(attach_env, "attach")
        artifact_id = attach_env["artifacts"][0]["artifacts"][0]["artifact_id"]

        val_env = validate({
            "goal": "probe captured something else",
            "root": self.tmpdir,
            "artifact_ids": [artifact_id],
            "artifact_only": True,
            "expected_artifact_text": ["text_that_does_not_exist_in_fixture_XYZZY"],
        })
        self._valid_envelope(val_env, "validate-missing-text")
        art = val_env["artifacts"][0]
        checks_by_name = {c["name"]: c for c in art["checks"]}
        self.assertIn("expected_artifact_text", checks_by_name)
        self.assertEqual(
            checks_by_name["expected_artifact_text"]["status"],
            "fail",
            msg="Expected text-check to fail for absent marker",
        )

    def test_fixture_json_is_valid_and_contains_marker(self):
        """Sanity: the fixture JSON parses cleanly and contains the marker."""
        data = json.loads(_FIXTURE.read_text(encoding="utf-8"))
        self.assertEqual(data["schema"], "sightline.godot.editor_probe_state.v3")
        self.assertEqual(data["source"], "godot_editor_probe")

        # Marker must appear somewhere in the serialised fixture.
        fixture_text = _FIXTURE.read_text(encoding="utf-8")
        self.assertIn(_MARKER, fixture_text)

    def test_all_envelopes_pass_validate(self):
        """Every envelope emitted by the replay round-trip must pass envelope.validate."""
        attach_env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "surface_kind": "path",
            "artifacts": [["runtime_issue_report", str(self.fixture_copy)]],
        })
        envelope.validate(attach_env)
        artifact_id = attach_env["artifacts"][0]["artifacts"][0]["artifact_id"]
        session_id = attach_env["artifacts"][0]["session_id"]

        list_env = inspect({"op": "list", "root": self.tmpdir})
        envelope.validate(list_env)

        list_art_env = inspect({
            "op": "list",
            "root": self.tmpdir,
            "session_id": session_id,
        })
        envelope.validate(list_art_env)

        val_env = validate({
            "goal": "probe captured the editor state",
            "root": self.tmpdir,
            "artifact_ids": [artifact_id],
            "artifact_only": True,
            "expected_artifact_text": [_MARKER],
        })
        envelope.validate(val_env)


if __name__ == "__main__":
    unittest.main()

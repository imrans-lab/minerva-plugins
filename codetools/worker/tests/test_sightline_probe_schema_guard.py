"""P3.6 — schema-version guard: probe GDScript schema vs fixture schema.

If the vendored codetools_probe.gd bumps its top-level schema string (e.g.,
v3 → v4) without a matching fixture refresh this test will FAIL, causing the
build to stop until a human updates the fixture via the Option C runbook at
codetools/docs/probe_capture_runbook.md.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

_WORKER_ROOT = Path(__file__).parent.parent
if str(_WORKER_ROOT) not in sys.path:
    sys.path.insert(0, str(_WORKER_ROOT))

_PROBE_GD = (
    _WORKER_ROOT
    / "vendored"
    / "sightline"
    / "godot"
    / "probe"
    / "addons"
    / "codetools_probe"
    / "codetools_probe.gd"
)

_FIXTURE = (
    Path(__file__).parent
    / "fixtures"
    / "probe"
    / "debugger_state.v3.json"
)

_RUNBOOK = "codetools/docs/probe_capture_runbook.md"


def _probe_schema_from_gd(path: Path) -> str:
    """Extract the first top-level schema string from codetools_probe.gd.

    Searches for the pattern:
        "schema": "sightline.godot.editor_probe_state.vN"
    and returns the full schema value string.  The top-level schema is defined
    in _capture_debugger_state() and always appears before the nested sub-schemas.
    """
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(
        r'"schema"\s*:\s*"(sightline\.godot\.editor_probe_state\.v\d+)"'
    )
    match = pattern.search(text)
    if match is None:
        raise AssertionError(
            "Could not find top-level schema string in %s. "
            "The pattern searched: %r" % (path, pattern.pattern)
        )
    return match.group(1)


class ProbeSchemaGuardTest(unittest.TestCase):
    """Fail-fast guard: fixture schema must match the probe's declared schema.

    This test will FAIL when:
      - The vendored codetools_probe.gd bumps its top-level schema version
        (e.g., editor_probe_state.v3 → v4), AND
      - The fixture at tests/fixtures/probe/debugger_state.v3.json has NOT
        been refreshed to match.

    To fix a failure here, follow the Option C runbook at:
      %(runbook)s

    Summary: open a real Godot project with the probe installed (op=prepare),
    let the probe write debugger_state.json, copy that JSON over the fixture
    (normalizing absolute paths to /project), then re-run these tests.
    """ % {"runbook": _RUNBOOK}

    def test_probe_gd_exists(self):
        self.assertTrue(
            _PROBE_GD.is_file(),
            "Probe GDScript not found at expected path: %s" % _PROBE_GD,
        )

    def test_fixture_exists(self):
        self.assertTrue(
            _FIXTURE.is_file(),
            "Probe state fixture not found at: %s" % _FIXTURE,
        )

    def test_schema_versions_match(self):
        """Top-level schema in codetools_probe.gd must match the fixture's schema field.

        If this test fails after a probe update, refresh the fixture by following
        the Option C runbook at: %(runbook)s
        """ % {"runbook": _RUNBOOK}
        probe_schema = _probe_schema_from_gd(_PROBE_GD)
        fixture_data = json.loads(_FIXTURE.read_text(encoding="utf-8"))
        fixture_schema = fixture_data.get("schema", "")

        self.assertEqual(
            probe_schema,
            fixture_schema,
            msg=(
                "\n\nPROBE SCHEMA DRIFT DETECTED\n"
                "  probe declares: %r\n"
                "  fixture has:    %r\n\n"
                "The vendored codetools_probe.gd has a different schema version than\n"
                "the replay fixture. Refresh the fixture by following the Option C\n"
                "runbook at: %s\n"
                "\n"
                "Quick summary:\n"
                "  1. minerva_codetools_inspect {op:'prepare', project_path:'<godot-project>'}\n"
                "  2. Open/restart the project in Godot Editor\n"
                "  3. Wait for probe to write debugger_state.json (~0.5s cadence)\n"
                "  4. Copy that JSON to %s, normalize absolute paths to /project\n"
                "  5. Re-run: cd codetools/worker && python3 -m unittest discover -t . -s tests -p 'test_*.py'\n"
            ) % (probe_schema, fixture_schema, _RUNBOOK, _FIXTURE),
        )

    def test_fixture_has_required_top_level_keys(self):
        """Fixture must contain the expected top-level structure from the probe."""
        fixture_data = json.loads(_FIXTURE.read_text(encoding="utf-8"))
        required = [
            "schema",
            "project",
            "project_path",
            "captured_at_unix",
            "source",
            "debugger",
            "output_console",
            "provenance",
        ]
        for key in required:
            self.assertIn(
                key,
                fixture_data,
                msg="Fixture missing required top-level key: %r" % key,
            )

    def test_fixture_debugger_schema(self):
        """Debugger sub-object must carry its own schema discriminator."""
        fixture_data = json.loads(_FIXTURE.read_text(encoding="utf-8"))
        debugger = fixture_data.get("debugger", {})
        self.assertEqual(
            debugger.get("schema"),
            "sightline.godot.debugger_rows.v2",
        )

    def test_fixture_output_console_schema(self):
        """Output console sub-object must carry its own schema discriminator."""
        fixture_data = json.loads(_FIXTURE.read_text(encoding="utf-8"))
        output_console = fixture_data.get("output_console", {})
        self.assertEqual(
            output_console.get("schema"),
            "sightline.godot.output_console.v1",
        )

    def test_fixture_marker_present_in_debugger_rows(self):
        """The recognizable marker text used by the replay test must be in the fixture."""
        fixture_data = json.loads(_FIXTURE.read_text(encoding="utf-8"))
        rows = fixture_data.get("debugger", {}).get("rows", [])
        marker = "probe_fixture_marker"
        found = any(marker in row.get("text", "") for row in rows)
        self.assertTrue(
            found,
            "Marker %r not found in debugger rows. "
            "Rows: %r" % (marker, rows),
        )

    def test_fixture_marker_present_in_output_console(self):
        """The recognizable marker text must also appear in output_console.text."""
        fixture_data = json.loads(_FIXTURE.read_text(encoding="utf-8"))
        text = fixture_data.get("output_console", {}).get("text", "")
        self.assertIn("probe_fixture_marker", text)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env bash
# pcb's entry point into the SHARED GDScript suite runner.
#
# The pass/fail contract — results-line floor, pinned suite manifest,
# assertion-count pins, real-worker proof, fatal-diagnostic allowlist — lives
# once in scripts/run-gd-tests.sh and is shared with every other plugin that
# has a tests/gd directory. Everything pcb-specific is data next to the
# suites: tests/gd/EXPECTED_SUITES, tests/gd/KNOWN_HARNESS_DIAGNOSTICS,
# tests/gd/REQUIRED_HOST_FILES, and scripts/probe-worker-methods.py.
#
# Usage (unchanged):
#   pcb/scripts/run-gd-tests.sh [--preflight-only] <path-to-minerva-checkout>
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../../scripts/run-gd-tests.sh" --plugin pcb "$@"

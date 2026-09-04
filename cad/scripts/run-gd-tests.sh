#!/usr/bin/env bash
# cad's entry point into the SHARED GDScript suite runner.
#
# The pass/fail contract — results-line floor, pinned suite manifest,
# assertion-count pins, fatal-diagnostic allowlist — lives once in
# scripts/run-gd-tests.sh and is shared with pcb. Everything cad-specific is
# data next to the suites: tests/gd/EXPECTED_SUITES,
# tests/gd/KNOWN_HARNESS_DIAGNOSTICS, tests/gd/REQUIRED_HOST_FILES.
#
# Usage:
#   cad/scripts/run-gd-tests.sh [--preflight-only] <path-to-minerva-checkout>
#
# Execution needs a Minerva checkout with its native GDExtensions built and
# KILLS a Minerva running from the editor; --preflight-only is filesystem-only
# and is what CI runs.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../../scripts/run-gd-tests.sh" --plugin cad "$@"

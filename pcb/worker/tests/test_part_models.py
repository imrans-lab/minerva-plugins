"""The vendor part-data client: real payloads, no network, no mocks.

FEW AND WIDE, ONE PER ORACLE. Every assertion below rests on something that
was measured or authored INDEPENDENTLY of the code under test:

* ``vendor_footprints/index.json`` states each part's package and title. It was
  authored for the orientation work, from the payloads, by hand — so it is a
  genuine second opinion about what the parser should read out.
* Datasheet PITCHES (JST PH 2.00 mm, JST XH 2.50 mm, VQFN-16 0.50 mm) fix the
  vendor's unit scale. A wrong scale would leave every ANGLE correct — a
  rotation is scale-free — and quietly move every distance, so it has to be
  re-derived rather than trusted.
* The vendor's own PACKAGE TITLE encodes the part's length (``_L2.9-W1.6``).
  The title is a string the supplier wrote; the model extent is a number we
  computed from a different field entirely. Agreement between them is real
  evidence.
* The "component not found" body is quoted verbatim from the live endpoint,
  where it arrives with **HTTP 200**. Nothing here would catch a client that
  trusted the status code, so the body is the oracle.

NO NETWORK, AND NOT BY MOCKING ONE. The two cache/absence tests point the
client at ``127.0.0.1:1``, where a connection is REFUSED immediately by the
kernel. That is a real network failure rather than a simulated one, and it also
makes the cache assertion airtight: a cached part that still resolves against a
dead address cannot have made a request.

Live fetching is verified by its own acceptance station. CI must never depend
on the supplier being up.
"""

from __future__ import annotations

import hashlib
import json
import math
import re

from pathlib import Path

import pytest

from pcb_worker import cache_dir
from pcb_worker import part_models as pm
from pcb_worker import part_orientation as po

VENDOR_DIR = Path(__file__).resolve().parent / "testdata" / "vendor_footprints"
INDEX = json.loads((VENDOR_DIR / "index.json").read_text(encoding="utf-8"))
PARTS = sorted(INDEX)

#: An address the kernel refuses instantly. Port 1 is not a filtered port, so
#: this fails fast everywhere rather than hanging until a timeout.
DEAD = "http://127.0.0.1:1/"


def _payload_bytes(part: str) -> bytes:
    return (VENDOR_DIR / f"{part}.json").read_bytes()


def _facts(part: str) -> pm.PartFacts:
    return pm.parse_component_payload(json.loads(_payload_bytes(part)), part)


def _unreachable(monkeypatch) -> None:
    """Make sure the refused connection stays refused.

    A configured proxy would send it somewhere real, and the test would start
    depending on the network it exists to do without.
    """
    for name in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
                 "all_proxy", "ALL_PROXY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("no_proxy", "*")


@pytest.fixture
def offline(monkeypatch, tmp_path):
    """A client that cannot reach anything, with a private empty cache."""
    _unreachable(monkeypatch)
    monkeypatch.setenv(cache_dir.ENV_VAR, str(tmp_path / "cache"))
    return pm.VendorPartClient(api_base=DEAD, model_base=DEAD, timeout=2.0)


# ---------------------------------------------------------------------------
# Parsing real payloads
# ---------------------------------------------------------------------------


def test_every_committed_payload_parses_into_the_facts_the_index_states():
    """The wide one. All twenty-two real payloads normalize, and each reports
    the package and title ``index.json`` independently says it is.

    Also pins the two structural claims the consumers rest on: a payload
    carries pads, and it carries exactly one model reference with a 32-hex
    uuid. A payload that stopped carrying either would still "parse" — this is
    what makes that visible.
    """
    for part in PARTS:
        facts = _facts(part)
        assert not facts.absent, f"{part}: {facts}"
        assert facts.part == part
        assert facts.package == INDEX[part]["package"], part
        assert facts.title == INDEX[part]["title"], part
        assert facts.pads, f"{part}: no pads"
        assert not facts.duplicate_numbers, (
            f"{part}: duplicate pad numbers {facts.duplicate_numbers} — the "
            "corpus is not supposed to contain any yet, so this is news")
        assert facts.model is not None, f"{part}: no model reference"
        assert re.fullmatch(r"[0-9a-f]{32}", facts.model.uuid), part
        # Pads are relative to the payload's own datum, so a part drawn on a
        # canvas offset by thousands of units still parses to small numbers.
        assert max(abs(p.x_mm) for p in facts.pads) < 100, part


def test_the_vendor_unit_is_rederived_from_pitches_we_already_know():
    """``VENDOR_UNIT_MM`` is 10 mil — checked against datasheet pitches, and
    checked to still agree with the copy in ``part_orientation``.

    The second half is the drift guard. Two modules parse these payloads today
    (folding them together belongs to the footprint-verification work, not
    here), and a scale that differed between them would make two consumers
    disagree about the same part while both looked self-consistent.
    """
    assert pm.VENDOR_UNIT_MM == po.VENDOR_UNIT_MM

    expected = {"C265102": 2.00, "C265104": 2.00, "C295747": 2.00,
                "C161861": 2.50, "C910544": 0.50}
    for part, pitch in expected.items():
        centres = {n: (p.x_mm, p.y_mm)
                   for n, p in _facts(part).pads_by_number.items()}
        numbered = sorted((n for n in centres if n.isdigit()), key=int)
        # The MINIMUM adjacent spacing: it skips the jump from the last signal
        # pin to a mounting tab or a thermal pad.
        spacings = [math.dist(centres[a], centres[b])
                    for a, b in zip(numbered, numbered[1:])]
        assert min(spacings) == pytest.approx(pitch, abs=0.002), (
            f"{part}: closest numbered-pad spacing {min(spacings):.4f} mm is "
            f"not the datasheet pitch {pitch} mm — VENDOR_UNIT_MM no longer "
            "describes the payload")


def test_the_model_extent_agrees_with_the_length_its_own_title_states():
    """A part whose package title says ``_L2.9-W1.6`` is 2.9 mm long, and the
    model's extent — read from a different field, in different units — has to
    show that length on one of its two axes.

    WHICH axis is not asserted, and that is deliberate rather than lazy: the
    corpus shows the vendor putting the length on ``c_width`` for a TSOT-26 and
    on ``c_height`` for an LGA-8, and pinning a convention the supplier does not
    hold would make this test lie. The claim being made is about SCALE and about
    reading the right field, which is what a mis-parse would break.

    Fourteen of the twenty-two titles encode a length; the rest (connectors,
    a switch, a header) name a series instead and are skipped by the pattern
    rather than by a list, so a newly-added part joins automatically.
    """
    checked = 0
    for part in PARTS:
        model = _facts(part).model
        stated = re.search(r"_L(\d+(?:\.\d+)?)-W\d", model.title)
        if not stated:
            continue
        checked += 1
        length = float(stated.group(1))
        dims = (model.width_mm, model.height_mm)
        assert min(abs(d - length) for d in dims) <= 0.05, (
            f"{part} ({model.title}): neither model extent {dims} is the "
            f"{length} mm length the title states")
    assert checked >= 14, (
        f"only {checked} titles encoded a length — the corpus changed shape "
        "and this oracle has quietly stopped checking most of it")


def test_a_part_the_supplier_does_not_have_is_an_absence_not_an_error():
    """Quoted verbatim from the live endpoint: a missing part answers **HTTP
    200** with a failure body. A client keyed on status would take this for a
    package drawing and cache it forever, so the body is what decides.

    The other three shapes here are the ones a truncated or wrong response
    actually takes. All of them are absences; none of them raises.
    """
    missing = {"success": False, "code": 404, "message": "Component not found"}
    absent = pm.parse_component_payload(missing, "C000000000")
    assert absent.absent and absent.reason == pm.REASON_NOT_FOUND
    assert "not found" in absent.detail.lower()

    for payload in ("not a document", [], {}, {"result": {}},
                    {"result": {"packageDetail": {"dataStr": {}}}}):
        answer = pm.parse_component_payload(payload, "C1")
        assert answer.absent, payload
        assert answer.reason in pm.REASONS, payload


# ---------------------------------------------------------------------------
# The client: caching, and absence with no network
# ---------------------------------------------------------------------------


def test_a_cached_part_resolves_with_the_network_refused(offline, tmp_path):
    """The no-second-fetch oracle, proved rather than counted.

    The cache is seeded the way a previous run leaves it — payload bytes plus a
    provenance sidecar — and the client is pointed at a dead address. Facts
    coming back at all is proof no request was made, because a request would
    have been refused. Provenance survives the round trip, and a second call
    through the in-process memo answers identically.
    """
    part = "C910544"
    data = _payload_bytes(part)
    digest = hashlib.sha256(data).hexdigest()
    home = tmp_path / "cache" / pm.CACHE_TENANT / "components"
    home.mkdir(parents=True)
    (home / f"{part}.json").write_bytes(data)
    (home / f"{part}.json.meta.json").write_text(json.dumps({
        "url": "https://easyeda.com/api/products/C910544/components",
        "sha256": digest,
        "fetched_at": "2026-09-02T00:00:00+00:00",
        "size_bytes": len(data),
    }), encoding="utf-8")

    facts = offline.facts(part)
    assert not facts.absent, facts
    assert facts.package == INDEX[part]["package"]
    assert facts.provenance.from_cache
    assert facts.provenance.sha256 == digest
    assert facts.provenance.fetched_at == "2026-09-02T00:00:00+00:00"
    assert offline.facts(part) is facts

    # A cache entry whose bytes no longer match its recorded hash is not
    # trusted: it falls back to the network, which here is refused.
    (home / f"{part}.json").write_bytes(data + b" ")
    fresh = pm.VendorPartClient(api_base=DEAD, model_base=DEAD, timeout=2.0)
    assert fresh.facts(part).absent


def test_with_no_network_every_part_reports_absent_and_nothing_raises(offline):
    """Forty-three parts on a real board become eighty-six requests. On a
    laptop with no connection every one of them has to come back as a stated
    absence, concurrently, without an exception reaching the export.

    Model lookups are included because they are the second request, and the
    path that reaches them differs: it goes through facts first.
    """
    answers = offline.facts_for(PARTS + ["", "  "])
    assert set(answers) == set(PARTS) | {""}
    for part in PARTS:
        answer = answers[part]
        assert answer.absent, part
        assert answer.reason == pm.REASON_NO_NETWORK, (part, answer.detail)
    assert answers[""].reason == pm.REASON_NO_PART_NUMBER

    assert offline.facts("../../etc/passwd").reason == pm.REASON_NO_PART_NUMBER
    model = offline.model("C910544")
    assert model.absent and model.reason == pm.REASON_NO_NETWORK


def test_caching_is_optional_and_its_absence_is_not_a_failure(monkeypatch):
    """``cache_dir`` may hand back nothing at all — no variable, an unwritable
    tree. The client then has no cache and says so by behaving normally: an
    absence from the network, never an exception about a directory."""
    _unreachable(monkeypatch)
    monkeypatch.delenv(cache_dir.ENV_VAR, raising=False)
    client = pm.VendorPartClient(api_base=DEAD, model_base=DEAD, timeout=2.0)
    answer = client.facts("C149504")
    assert answer.absent and answer.reason == pm.REASON_NO_NETWORK

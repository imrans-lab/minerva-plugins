"""THE TWO VERBS, DRIVEN — not their arithmetic re-stated.

Everything here calls ``board_3d.warm_cache`` / ``board_3d.export`` for real,
against a REAL :class:`part_models.VendorPartClient` and a REAL per-user cache
directory pointed at a tmp path. The one thing replaced is the socket:
``part_models._http_get`` is redirected at the committed vendor corpus, which
is what the endpoint actually answers with. Nothing else is stubbed — the memo,
the on-disk cache, the sidecars, the identity check and the parse all run.

THE ORACLES
-----------
* AN EXPORT AGAINST A COLD CACHE TOUCHES NO NETWORK. ``_http_get`` is replaced
  with a function that FAILS THE TEST if it is called at all, so "offline" is
  proven by the absence of a call rather than by reading a flag. The export
  still produces its file — the parts are placeholder prisms — and it names the
  warming verb.
* WARMING IS WHAT MAKES THE EXPORT COMPLETE. The same board, the same tmp cache
  and the same offline export, run once before the warm and once after: the
  second run has to find the models the first could not. That is the only
  assertion that proves the two verbs share one cache; asserting each alone
  passes even when they are writing and reading different directories.
* THE COLD REASON IS ITS OWN REASON. ``not_cached`` is a statement about this
  machine, curable by warming; ``no_network`` is not. A caller that cannot tell
  them apart cannot tell a person what to do.
* THE FILE IS ON DISK, AND IS THE BYTES THE REPLY DESCRIBES. The reply's
  sha256 and byte count are checked against the file that was written, and the
  file is checked to be a GLB by its own magic — not by its extension.

The board is ``assembly_orientation.yaml``, the same fixture the CPL and
placement suites use, so a part that moves here moves there too.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import struct
from pathlib import Path

import pytest
import yaml

from pcb_worker import board_3d
from pcb_worker import part_models as pm
from pcb_worker import part_placement as pp
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "testdata" / "assembly_boards" / "assembly_orientation.yaml"
VENDOR = HERE / "testdata" / "vendor_footprints"
#: The gerber spike board: three POPULATED components, not one of which carries
#: an ``mpn`` or a house catalogue number. The order package refuses it by name
#: (assembly_missing_identity) and must — a BOM row with a blank identity cell
#: is not a thing to send a factory. NEITHER of this module's verbs may refuse
#: it: they draw a picture on this machine.
MPNLESS = HERE.parent.parent / "spikes" / "gerber" / "board.yaml"

#: The catalogue numbers this fixture board orders, from its own assembly
#: blocks. FID1 is not populated and never reaches the position file.
ORDERED = ("C149504", "C265102", "C780769", "C910544")

#: A minimal but REAL vendor-dialect OBJ: inline materials, ``d 0.0``, the
#: ``f 1// 2// 3//`` face syntax. Served as the model body for every uuid, so
#: the parse the client runs is the parse it runs on the wire.
OBJ_BODY = """newmtl body
Kd 0.251 0.251 0.251
d 0.0
v 0 0 0
v 1 0 0
v 1 1 0
v 0 0 1
usemtl body
f 1// 2// 3//
f 1// 2// 4//
f 2// 3// 4//
f 1// 3// 4//
"""


def _compiled(path: Path):
    result = compile_board(yaml.safe_load(path.read_text(encoding="utf-8")))
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError("fixture did not compile: " + ", ".join(
            d.code for d in result.diagnostics
            if d.severity is DiagnosticSeverity.ERROR))
    return result.board


@pytest.fixture()
def board():
    return _compiled(FIXTURE)


@pytest.fixture()
def mpnless_board():
    return _compiled(MPNLESS)


@pytest.fixture()
def cache(tmp_path, monkeypatch):
    """A REAL, EMPTY per-user cache root, stated the way the Go side states it."""
    root = tmp_path / "cache"
    root.mkdir()
    monkeypatch.setenv("MINERVA_PCB_CACHE_DIR", str(root))
    return root


@pytest.fixture()
def no_network(monkeypatch):
    """Any HTTP call at all fails the test by name."""
    def forbidden(url, **_kwargs):
        raise AssertionError(
            "this code path reached the network: %s" % url)
    monkeypatch.setattr(pm, "_http_get", forbidden)


@pytest.fixture()
def corpus_network(monkeypatch):
    """The committed corpus, served over the module's own fetch seam.

    Returns the list of urls requested, so "at most once per document" and
    "nothing was asked for after the warm" are both measurable.
    """
    asked: list[str] = []

    def serve(url, **_kwargs):
        asked.append(url)
        if url.startswith(pm.API_BASE):
            part = url[len(pm.API_BASE):].split("/", 1)[0]
            path = VENDOR / f"{part}.json"
            if not path.exists():
                raise pm._Unreachable("HTTP 404 from %s" % url)
            return path.read_bytes()
        if url.startswith(pm.MODEL_BASE):
            return OBJ_BODY.encode("utf-8")
        raise AssertionError("unexpected url %s" % url)

    monkeypatch.setattr(pm, "_http_get", serve)
    return asked


def _export(board, tmp_path, **extra):
    params = {"out_dir": str(tmp_path / "out")}
    params.update(extra)
    reply = board_3d.export(board, params)
    assert reply["ok"], reply
    return reply["result"]


# ---------------------------------------------------------------------------
# The export never fetches
# ---------------------------------------------------------------------------


def test_a_cold_export_writes_the_file_names_the_gap_and_touches_no_network(
        board, cache, no_network, tmp_path):
    """The whole contract of the offline half, in one run."""
    result = _export(board, tmp_path)

    # It produced a real file, and the reply describes THOSE bytes.
    path = Path(result["path"])
    assert path.is_file()
    data = path.read_bytes()
    assert data[:4] == b"glTF", "not a GLB — magic is %r" % data[:4]
    assert result["bytes"] == len(data)
    assert result["sha256"] == hashlib.sha256(data).hexdigest()

    # Every ordered part fell back, because nothing is cached.
    cold_refs = {row["ref"] for row in result["cache_cold"]}
    assert cold_refs == {"U1", "U2", "J1", "R1"}, result["cache_cold"]
    assert {row["reason"] for row in result["cache_cold"]} == {pm.REASON_NOT_CACHED}

    # …and the reason is NOT the one that means "you are offline", which would
    # send a person to check their connection instead of warming the cache.
    assert pm.REASON_NO_NETWORK not in {row["reason"]
                                        for row in result["missing_models"]}

    # The gap names the verb that closes it, in both the machine field and the
    # sentence a person reads.
    assert board_3d.WARM_VERB in result["cache_cold_hint"]
    assert board_3d.WARM_VERB in result["summary"]

    # And it says where the file went and what can open it — this export's
    # entire value to somebody who cannot call a tool.
    assert result["path"].endswith(".glb")
    assert "Blender" in result["viewer_note"]


def test_an_offline_client_misses_where_an_online_one_would_fetch(
        cache, corpus_network):
    """The gate is BELOW the cache read: an offline client still serves a
    cached document, and only a MISS becomes ``not_cached``."""
    online = pm.VendorPartClient()
    assert not online.facts("C780769").absent
    assert corpus_network, "the online client should have fetched"

    offline = pm.VendorPartClient(offline=True)
    # Warmed by the call above -> served, in a different process-level memo.
    assert not offline.facts("C780769").absent
    # Never warmed -> the cache-miss reason, and no request.
    before = len(corpus_network)
    absent = offline.facts("C15850")
    assert absent.absent and absent.reason == pm.REASON_NOT_CACHED
    assert len(corpus_network) == before, "the offline client fetched"


# ---------------------------------------------------------------------------
# Warming is what the export reads
# ---------------------------------------------------------------------------


def test_warming_then_exporting_seats_the_parts_the_cold_run_could_not(
        board, cache, corpus_network, monkeypatch, tmp_path):
    """THE PAIR ORACLE. One cache, two verbs, and the second sees the first."""
    # The corpus server the fixture installed, held so it can be put back. NOT
    # monkeypatch.undo(): pytest hands one monkeypatch object to the whole test,
    # so undoing here would also unset MINERVA_PCB_CACHE_DIR and the two verbs
    # would silently stop sharing a cache — which is the very thing under test.
    corpus_serve = pm._http_get

    # 1. Cold: every part a prism, no network touched.
    monkeypatch.setattr(pm, "_http_get", _forbidden)
    cold = _export(board, tmp_path, name="cold")
    assert len(cold["cache_cold"]) == 4

    # 2. Warm, over the corpus. This is the only step allowed to fetch.
    monkeypatch.setattr(pm, "_http_get", corpus_serve)
    warm = board_3d.warm_cache(board, {})
    assert warm["ok"], warm
    result = warm["result"]
    assert sorted(result["requested"]) == list(ORDERED)
    assert [row["part"] for row in result["ready"]] == list(ORDERED), result["missing"]
    assert result["counts"]["ready"] == 4
    assert result["counts"]["fetched"] == 4
    assert result["counts"]["already_cached"] == 0
    assert result["cache_dir"], "the warm reported no cache directory"

    # The documents really are on disk under the tenant, not merely memoized in
    # a client this test happens to still hold.
    cached = {p.name for p in (cache / pm.CACHE_TENANT / "components").iterdir()}
    assert {"%s.json" % part for part in ORDERED} <= cached

    # 3. Cold again — a NEW process would be, so forbid the network once more.
    monkeypatch.setattr(pm, "_http_get", _forbidden)
    warmed = _export(board, tmp_path, name="warmed")
    assert warmed["cache_cold"] == [], warmed["cache_cold"]
    assert "cache_cold_hint" not in warmed
    assert warmed["missing_models"] == [], warmed["missing_models"]

    # AND THE PARTS CHANGED KIND. This is the assertion a shared flag could not
    # fake, and it is not the file size: a vendor mesh can be SMALLER than the
    # courtyard prism that stood in for it, so bytes prove nothing either way.
    def kinds(result):
        return {row["ref"]: row["kind"]
                for row in result["report"]["placement"]["parts"]}

    assert set(kinds(cold).values()) == {pp.KIND_PLACEHOLDER}
    assert set(kinds(warmed).values()) == {pp.KIND_MODEL}


def _forbidden(url, **_kwargs):
    raise AssertionError("this code path reached the network: %s" % url)


def test_a_second_warm_is_answered_from_disk(board, cache, corpus_network):
    """The cache is a cache: warming twice does not fetch twice."""
    board_3d.warm_cache(board, {})
    first = len(corpus_network)
    assert first > 0

    # A FRESH client, so the in-process memo cannot be what answers.
    again = board_3d.warm_cache(board, {}, client=pm.VendorPartClient())
    assert len(corpus_network) == first, "the second warm went back to the network"
    counts = again["result"]["counts"]
    assert counts["already_cached"] == 4 and counts["fetched"] == 0


def test_a_part_the_supplier_has_no_model_for_is_reported_not_refused(
        board, cache, monkeypatch):
    """A missing model is data. The verb still succeeds and names the refs."""
    def serve(url, **_kwargs):
        if url.startswith(pm.API_BASE):
            part = url[len(pm.API_BASE):].split("/", 1)[0]
            if part == "C265102":
                raise pm._Unreachable("HTTP 404 from %s" % url)
            return (VENDOR / f"{part}.json").read_bytes()
        return OBJ_BODY.encode("utf-8")

    monkeypatch.setattr(pm, "_http_get", serve)
    result = board_3d.warm_cache(board, {})["result"]

    missing = {row["part"]: row for row in result["missing"]}
    assert set(missing) == {"C265102"}, result["missing"]
    # NAMED BY REF. "C265102 is missing" tells nobody which part goes magenta.
    assert missing["C265102"]["refs"] == ["J1"]
    assert result["counts"]["ready"] == 3


# ---------------------------------------------------------------------------
# Refusals write nothing
# ---------------------------------------------------------------------------


def test_an_export_with_no_destination_reports_without_writing(
        board, cache, no_network, tmp_path):
    """out_dir is OPTIONAL, the way it is on the order package: no directory
    means build the model, hand back its size, digest and whole report, and put
    nothing on disk. The report is the point of this verb, and asking for it
    should not cost a directory and a cleanup."""
    reply = board_3d.export(board, {})
    assert reply["ok"], reply
    result = reply["result"]

    assert result["written"] is False
    assert result["path"] == "", "a path was reported for a file nobody wrote"
    assert result["filename"].endswith(".glb")
    assert result["bytes"] > 0 and len(result["sha256"]) == 64
    # The whole report is still there — that is what this mode is FOR.
    assert len(result["cache_cold"]) == 4
    assert result["tallest"] == result["report"]["placement"]["tallest"]
    assert "NOT written" in result["summary"]

    # Nothing on disk anywhere it could have guessed.
    assert list(tmp_path.iterdir()) == [tmp_path / "cache"]

    # And the SAME board with a destination writes the same bytes.
    written = _export(board, tmp_path)
    assert written["sha256"] == result["sha256"]
    assert written["written"] is True


def test_an_occupied_destination_is_not_replaced_unless_asked(
        board, cache, no_network, tmp_path, monkeypatch):
    first = _export(board, tmp_path)
    original = Path(first["path"]).read_bytes()

    # AND IT REFUSES BEFORE THE BAKE. A destination that is already occupied is
    # knowable from the parameters, so the caller must not pay for a whole
    # placement chain and two textures to be told so: the builder is made to
    # explode, and the refusal that comes back is still the named one.
    def exploded(*_args, **_kwargs):
        raise AssertionError("the export built the file before checking the path")
    builder = board_3d.gltf_export.export_board
    monkeypatch.setattr(board_3d.gltf_export, "export_board", exploded)

    with pytest.raises(board_3d.Board3DError) as caught:
        board_3d.export(board, {"out_dir": str(tmp_path / "out")})
    assert caught.value.code == "board_3d_exists"
    assert Path(first["path"]).read_bytes() == original, "the refusal wrote anyway"
    # Put the builder back BY HAND, not with monkeypatch.undo(): one monkeypatch
    # object serves the whole test, so undoing here would also unset the cache
    # root and the no-network guard the fixtures installed.
    monkeypatch.setattr(board_3d.gltf_export, "export_board", builder)

    again = _export(board, tmp_path, overwrite=True)
    assert again["path"] == first["path"]


def test_a_texture_scale_that_cannot_bake_refuses_before_the_bake(
        board, cache, no_network, tmp_path):
    for value in (0, -4, "wide"):
        with pytest.raises(board_3d.Board3DError) as caught:
            board_3d.export(board, {"out_dir": str(tmp_path / "out"),
                                    "scale_px_per_mm": value})
        assert caught.value.code == "board_3d_bad_parameter", value
    assert not (tmp_path / "out").exists(), "a refused export created its directory"


# ---------------------------------------------------------------------------
# The reports the panel and an agent both read
# ---------------------------------------------------------------------------


def test_the_reports_ride_the_reply_and_the_file_alike(
        board, cache, no_network, tmp_path):
    """A report that only reached the file is lost on the surface that has no
    parser; a report that only reached the reply is lost the moment somebody
    forwards the .glb. Both carry it."""
    result = _export(board, tmp_path)

    for key in ("missing_models", "unverified", "tallest",
                "unknown_height_refs", "advisories", "excluded"):
        assert key in result, key
    # The hoisted lists ARE the ones inside the file's own report, not a second
    # derivation that could drift.
    placement = result["report"]["placement"]
    assert result["missing_models"] == placement["fallbacks"]
    assert result["unverified"] == placement["unverified"]
    assert result["unknown_height_refs"] == placement["unknown_height_refs"]

    # And the file really carries it: the GLB's JSON chunk holds asset.extras.
    extras = _glb_json(Path(result["path"]))["asset"]["extras"]
    assert extras["placement"]["fallbacks"] == result["missing_models"]


def _glb_json(path: Path) -> dict:
    """The JSON chunk of a GLB, read by the container's own rules."""
    data = path.read_bytes()
    magic, _version, _length = struct.unpack_from("<4sII", data, 0)
    assert magic == b"glTF"
    chunk_length, chunk_type = struct.unpack_from("<II", data, 12)
    assert chunk_type == 0x4E4F534A, "first chunk is not JSON"
    return json.loads(data[20:20 + chunk_length].decode("utf-8"))


def test_the_file_is_named_for_the_board_and_never_doubles_its_suffix(
        board, cache, no_network, tmp_path):
    assert board_3d.output_name(board, {}).endswith(".glb")
    assert board_3d.output_name(board, {"name": "rev-b"}) == "rev-b.glb"
    assert board_3d.output_name(board, {"name": "rev-b.glb"}) == "rev-b.glb"
    # A name that would climb out of out_dir is flattened, not honoured.
    assert "/" not in board_3d.output_name(board, {"name": "../../etc/passwd"})


# ---------------------------------------------------------------------------
# A board with no catalogue numbers is DRAWN, not refused
# ---------------------------------------------------------------------------
#
# The purchasing identity contract (assembly_missing_identity) exists so a BOM
# row never carries a blank identity cell. It is a promise about a document a
# factory reads. Neither of these verbs emits one — the warm downloads models
# and the export draws a picture on this machine — and the rule for exactly
# this case is the opposite: a missing model or a missing catalogue number
# degrades to a courtyard prism and a report, never to a refusal.
#
# The oracle is the SAME BOARD refused by the artifact path and drawn by these:
# a test that only checked these two succeed would pass just as well if the
# gate had been deleted for everybody.


def test_the_artifact_path_still_refuses_the_board_these_verbs_draw(mpnless_board):
    """THE CONTROL. Without this, the two tests below prove nothing."""
    from pcb_worker import assembly_outputs as ao

    with pytest.raises(ao.AssemblyIdentityError) as caught:
        ao.emit(mpnless_board, "jlc")
    assert caught.value.code == "assembly_missing_identity"
    assert caught.value.component == "R1"
    assert caught.value.field == "assembly.mpn"


def test_warming_a_board_with_no_catalogue_numbers_reports_instead_of_refusing(
        mpnless_board, cache, no_network):
    """Nothing to fetch is not a failure to fetch — and NO NETWORK IS TOUCHED,
    because there is nothing to ask for."""
    result = board_3d.warm_cache(mpnless_board, {})["result"]

    assert result["requested"] == []
    assert result["ready"] == [] and result["missing"] == []
    # Every populated placement is named as one the board gave no number for.
    assert sorted(result["refs_without_part"]) == ["C1", "R1", "U1"]
    assert result["counts"]["requested"] == 0


def test_exporting_a_board_with_no_catalogue_numbers_draws_prisms_and_says_so(
        mpnless_board, cache, no_network, tmp_path):
    """A mid-layout board nobody has entered part numbers for is exactly when
    somebody wants to look at the thing."""
    result = _export(mpnless_board, tmp_path)

    assert Path(result["path"]).is_file()
    missing = {row["ref"]: row for row in result["missing_models"]}
    assert set(missing) == {"R1", "C1", "U1"}
    # NAMED for what is actually wrong: the board never gave a number, which is
    # not the same fault as a cold cache and must not be reported as one.
    assert {row["reason"] for row in missing.values()} == {pm.REASON_NO_PART_NUMBER}
    assert result["cache_cold"] == []
    assert "cache_cold_hint" not in result


def test_only_the_purchasing_requirement_is_lifted_for_a_local_draw(mpnless_board):
    """The drawing profile is the shipped one MINUS identity_required, and
    nothing else. A profile that had quietly lost its dialect or its row limits
    would still let both tests above pass."""
    from pcb_worker import assembly_outputs as ao

    shipped = ao.PROFILES["jlc"]
    drawing = board_3d.drawing_profile({})

    assert drawing.identity_required == ()
    assert shipped.identity_required, "the fixture must carry the trap"
    # Every OTHER field is the shipped profile's, field by field, so this can
    # never drift into a hand-built profile that gates nothing.
    for field in dataclasses.fields(shipped):
        if field.name == "identity_required":
            continue
        assert getattr(drawing, field.name) == getattr(shipped, field.name), field.name

    # And the house key the catalogue number is read under is untouched, so the
    # warm and the position file cannot disagree about what a part is called.
    assert drawing.house_part_id == shipped.house_part_id

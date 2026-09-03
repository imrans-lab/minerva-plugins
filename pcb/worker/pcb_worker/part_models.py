"""ONE client for vendor part data, keyed by the catalogue number a board
already carries.

WHY A CLIENT AND NOT A PRIVATE HELPER
-------------------------------------
A single request to

    easyeda.com/api/products/<part>/components?version=<pinned>

returns ONE document that two unrelated consumers both need. Its
``packageDetail.dataStr.shape`` array carries the ``PAD~`` records that
differential footprint verification measures our drawings against, AND the
``SVGNODE`` record a 3D export needs for its model uuid, origin, rotation and
z. Two independent fetchers would pull the identical payload twice and cache
it twice, and would drift apart on the unit scale. So this module fetches once,
caches once, and parses once into normalized facts that anybody can read.

The 3D export is this client's FIRST consumer. It is not its owner. Nothing
here knows what a consumer intends to do with a pad or a model.

THE FACTS ARE IN THE VENDOR'S FRAME — DELIBERATELY
--------------------------------------------------
Pads and the model origin are reported in millimetres RELATIVE TO THE
PAYLOAD'S OWN DATUM (``dataStr.head.x``/``.y``), so a payload re-fetched onto a
different canvas position parses to identical numbers. Mapping any of it into
OUR frame — solving a rotation offset, placing a model on a board — is a
consumer's arithmetic and is deliberately absent from this file. A shared
"compare two drawings" framework here would be the wrong shape: each consumer's
check is a subtraction it writes itself, against facts it did not have to fetch.

NOTHING FETCHED AT RUN TIME IS COMMITTED
----------------------------------------
Payloads and models are third-party vendor content served from a well-known
public channel, keyed by a catalogue number the board already stores. Whatever
this client fetches lands in the PER-USER cache
(:mod:`pcb_worker.cache_dir`) and nowhere else: not the repository, not the
installed bundle. A fresh clone rebuilds every render and carries no vendor
binary — these endpoints grant no redistribution terms.

The one deliberate exception is the TEST CORPUS: a small set of package-drawing
payloads is committed under ``tests/testdata/vendor_footprints/`` so the suite
can parse real vendor documents with no network. No 3D MODEL is committed.

WHAT WAS MEASURED RATHER THAN BELIEVED
--------------------------------------
* SCALE. Non-model shape coordinates are in units of 10 mil
  (:data:`VENDOR_UNIT_MM`). Re-derived from pitches the datasheets state, not
  taken on trust — see ``tests/test_part_models.py``.
* THE ``version`` QUERY STRING IS NOT REQUIRED. The endpoint answers 200
  without it. It is sent anyway: the API is unversioned, and pinning is the
  only lever there is if the shape changes under us.
* USER AGENT SENSITIVITY IS REAL AND NARROW. ``python-urllib/3.12`` is refused
  with HTTP 403; an empty agent and our own token both answer 200. So the block
  targets the stock Python agent specifically. We therefore send an HONEST
  identifying agent (:data:`USER_AGENT`) and do NOT impersonate a browser — the
  measurement says we do not have to.
* A MISSING PART ANSWERS HTTP **200**. The body is
  ``{"success": false, "code": 404, "message": "Component not found"}``. HTTP
  status is not the absence signal here, the body is, so a client that trusts
  the status caches "not found" as though it were a package drawing.
* THE MODEL ENDPOINT IS **NOT** AGENT-SENSITIVE and answers OBJ in millimetres.
  What the OBJ does and does not carry is measured in
  :mod:`pcb_worker.wavefront_obj` — including the fact that it DOES carry
  colours, inline, in a form a stock loader drops on the floor.

EVERY FAILURE IS A REPORTED ABSENCE
-----------------------------------
No catalogue number, no entry upstream, no network, a malformed response, an
unwritable cache: each is an :class:`Absence` carrying a machine-readable
``reason`` and a human ``detail``. Nothing in the public surface raises. An
export of forty parts must not be stopped by the one part whose supplier has
retired the drawing; it must render thirty-nine and say what it could not find.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import threading
import urllib.error
import urllib.request

from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, ClassVar, Iterable, Mapping, Sequence, Union

from . import cache_dir
from .wavefront_obj import Mesh, parse_obj

log = logging.getLogger(__name__)

#: EasyEDA/LCSC package drawings are in units of 10 mil. The same constant
#: exists in :mod:`pcb_worker.part_orientation`, which parsed these payloads
#: first; ``tests/test_part_models.py`` asserts the two agree AND re-derives
#: the value from known pitches, so the pair cannot drift silently. Folding
#: that module's parser onto this one belongs to the footprint-verification
#: work that owns its measurement, not here.
VENDOR_UNIT_MM = 0.254

#: Where cached payloads and models live, under the per-user cache root the Go
#: side states. Deleting the tree at any moment is safe; the next export
#: refetches.
CACHE_TENANT = "vendor_parts"

API_BASE = "https://easyeda.com/api/products/"
#: Pinned even though the endpoint answers without it — see the module header.
API_VERSION = "6.4.19.5"
MODEL_BASE = "https://modules.easyeda.com/3dmodel/"

#: Honest, identifying, and measured to be accepted. Do NOT replace this with a
#: browser string: the block we route around targets the stock Python agent,
#: and impersonating a browser would buy nothing while making us undiagnosable
#: in the vendor's logs.
USER_AGENT = "minerva-pcb/1.0 (+https://github.com/ipeerbhai/minerva-plugins)"

#: Per-request timeout, seconds. A cold run over a real board is ~86 requests,
#: so a hung connection must fail fast enough that the export still finishes.
TIMEOUT_S = 20.0

#: Concurrent requests. Capped low on purpose: this is an unauthenticated
#: public endpoint being asked for tens of documents in a burst, and being a
#: polite client is the cheapest way to keep it available to us.
MAX_WORKERS = 4

# Absence reasons. Strings rather than an enum because they cross the worker's
# JSON boundary into Go, where a name reads better than an ordinal.
REASON_NO_PART_NUMBER = "no_part_number"
REASON_NOT_FOUND = "not_found"
REASON_NO_NETWORK = "no_network"
REASON_MALFORMED = "malformed"
REASON_NO_MODEL = "no_model"

REASONS = (REASON_NO_PART_NUMBER, REASON_NOT_FOUND, REASON_NO_NETWORK,
           REASON_MALFORMED, REASON_NO_MODEL)

#: A catalogue number becomes a FILENAME in the cache, so it is validated
#: rather than escaped: anything outside this alphabet is a reported absence,
#: never a path that could climb out of the tenant directory.
_PART_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_UUID_RE = re.compile(r"^[0-9a-fA-F]{8,64}$")

# Vendor shape records are "~"-separated lines. For PAD the fields are, by
# index: 1 shape, 2 centre x, 3 centre y, 4 width, 5 height, 6 layer,
# 8 number, 9 rotation.
_PAD_SHAPE, _PAD_X, _PAD_Y, _PAD_W, _PAD_H = 1, 2, 3, 4, 5
_PAD_LAYER, _PAD_NUMBER, _PAD_ROTATION = 6, 8, 9
_PAD_MIN_FIELDS = 10


# ---------------------------------------------------------------------------
# The facts
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Provenance:
    """Where a number came from. Recorded for every fetch, carried through the
    cache, and readable by any consumer that has to justify a measurement."""

    url: str
    sha256: str
    fetched_at: str          # ISO-8601 UTC, of the ORIGINAL fetch
    size_bytes: int
    from_cache: bool = False


@dataclass(frozen=True)
class Absence:
    """"We have no vendor data for this part, and here is exactly why."

    A normal, common answer — not an error. ``reason`` is one of
    :data:`REASONS`; ``detail`` is the sentence to show a human.
    """

    part: str
    reason: str
    detail: str
    absent: ClassVar[bool] = True


@dataclass(frozen=True)
class VendorPad:
    """One ``PAD~`` record, in millimetres relative to the payload's datum.

    ``number`` is as written — ``"MP"`` and ``"17"`` are both real. Sizes are
    the land's own, unmodified; ``layer`` is the vendor's raw layer id, kept
    verbatim because deciding which layers count is a consumer's question.
    """

    number: str
    x_mm: float
    y_mm: float
    width_mm: float
    height_mm: float
    shape: str
    layer: str
    rotation_deg: float


@dataclass(frozen=True)
class ModelReference:
    """The ``SVGNODE`` record: which 3D model, and how the vendor sites it.

    Reported EXACTLY as the vendor states it, converted to millimetres and
    made relative to the payload datum, and no further. ``rotation_deg`` is the
    raw ``c_rotation`` triple (observed values include ``(0, 0, 180)``);
    ``z_mm`` is the vendor's own z (observed negative on a through-hole header,
    whose body hangs below the board). What any of that means once the part is
    placed on OUR board is not decided here.
    """

    uuid: str
    title: str
    origin_x_mm: float
    origin_y_mm: float
    rotation_deg: tuple[float, float, float]
    z_mm: float
    width_mm: float
    height_mm: float


@dataclass(frozen=True)
class PartFacts:
    """Everything one component document says, normalized once.

    ``head_origin`` is the raw datum in the vendor's canvas units, kept so a
    consumer can retrace the conversion; everything else is already relative to
    it and already in millimetres.
    """

    part: str
    title: str
    package: str
    package_uuid: str
    head_origin: tuple[float, float]
    pads: tuple[VendorPad, ...]
    duplicate_numbers: tuple[str, ...]
    model: Union[ModelReference, None] = None
    provenance: Union[Provenance, None] = None
    absent: ClassVar[bool] = False

    @property
    def pads_by_number(self) -> Mapping[str, VendorPad]:
        """Pads keyed by number, with any number that appears more than once
        REMOVED (it is listed in ``duplicate_numbers`` instead).

        Dropping rather than guessing is load-bearing for the consumer that
        anchors on pad numbers: a split thermal pad or a pair of mechanical
        tabs both called ``MP`` is ambiguous, and an arbitrary winner would
        make a rotation solve confidently wrong.
        """
        return {p.number: p for p in self.pads
                if p.number not in self.duplicate_numbers}


@dataclass(frozen=True)
class PartModel:
    """A fetched and parsed 3D model, in millimetres in the model's own frame."""

    part: str
    uuid: str
    mesh: Mesh
    provenance: Union[Provenance, None] = None
    absent: ClassVar[bool] = False


# ---------------------------------------------------------------------------
# Parsing — pure, offline, and the whole reason the tests need no network
# ---------------------------------------------------------------------------


def _f(value: Any, default: Union[float, None] = None) -> Union[float, None]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _model_reference(shapes: Sequence[Any], origin_x: float,
                     origin_y: float) -> Union[ModelReference, None]:
    """The first ``SVGNODE`` whose payload names a model uuid, or None.

    Every payload measured carries exactly one, an ``outline3D``. The record is
    ``SVGNODE~<json>``; the JSON's ``attrs`` hold the reference.
    """
    for record in shapes:
        if not isinstance(record, str) or not record.startswith("SVGNODE~"):
            continue
        try:
            node = json.loads(record.split("~", 1)[1])
        except (ValueError, IndexError):
            continue
        attrs = node.get("attrs") if isinstance(node, Mapping) else None
        if not isinstance(attrs, Mapping):
            continue
        uuid = str(attrs.get("uuid") or "").strip()
        if not _UUID_RE.match(uuid):
            continue
        cx, cy = origin_x, origin_y
        parts = str(attrs.get("c_origin") or "").split(",")
        if len(parts) == 2:
            cx = _f(parts[0], origin_x)
            cy = _f(parts[1], origin_y)
        rot = [_f(v, 0.0) or 0.0
               for v in str(attrs.get("c_rotation") or "0,0,0").split(",")]
        rot = (rot + [0.0, 0.0, 0.0])[:3]
        return ModelReference(
            uuid=uuid,
            title=str(attrs.get("title") or ""),
            origin_x_mm=(cx - origin_x) * VENDOR_UNIT_MM,
            origin_y_mm=(cy - origin_y) * VENDOR_UNIT_MM,
            rotation_deg=(rot[0], rot[1], rot[2]),
            z_mm=(_f(attrs.get("z"), 0.0) or 0.0) * VENDOR_UNIT_MM,
            width_mm=(_f(attrs.get("c_width"), 0.0) or 0.0) * VENDOR_UNIT_MM,
            height_mm=(_f(attrs.get("c_height"), 0.0) or 0.0) * VENDOR_UNIT_MM,
        )
    return None


def _pads(shapes: Sequence[Any], origin_x: float,
          origin_y: float) -> tuple[tuple[VendorPad, ...], tuple[str, ...]]:
    out: list[VendorPad] = []
    seen: dict[str, int] = {}
    for record in shapes:
        if not isinstance(record, str) or not record.startswith("PAD~"):
            continue
        f = record.split("~")
        if len(f) < _PAD_MIN_FIELDS:
            continue
        x, y = _f(f[_PAD_X]), _f(f[_PAD_Y])
        if x is None or y is None:
            continue
        number = f[_PAD_NUMBER].strip()
        if not number:
            continue
        seen[number] = seen.get(number, 0) + 1
        out.append(VendorPad(
            number=number,
            x_mm=(x - origin_x) * VENDOR_UNIT_MM,
            y_mm=(y - origin_y) * VENDOR_UNIT_MM,
            width_mm=(_f(f[_PAD_W], 0.0) or 0.0) * VENDOR_UNIT_MM,
            height_mm=(_f(f[_PAD_H], 0.0) or 0.0) * VENDOR_UNIT_MM,
            shape=f[_PAD_SHAPE],
            layer=f[_PAD_LAYER],
            rotation_deg=_f(f[_PAD_ROTATION], 0.0) or 0.0,
        ))
    dupes = tuple(sorted(n for n, c in seen.items() if c > 1))
    return tuple(out), dupes


def parse_component_payload(payload: Any, part: str = "",
                            provenance: Union[Provenance, None] = None,
                            ) -> Union[PartFacts, Absence]:
    """Normalize one component document. Pure: no network, no clock, no files.

    This is the function the offline tests drive against the committed vendor
    payloads, which is what lets the parse be tested against REAL data with no
    mock anywhere in the picture.
    """
    if not isinstance(payload, Mapping):
        return Absence(part, REASON_MALFORMED, "payload is not a JSON object")
    if payload.get("success") is False:
        message = str(payload.get("message") or "upstream reports no such part")
        return Absence(part, REASON_NOT_FOUND, message)
    result = payload.get("result")
    if not isinstance(result, Mapping):
        return Absence(part, REASON_MALFORMED, "payload states no `result`")
    detail = result.get("packageDetail")
    if not isinstance(detail, Mapping):
        return Absence(part, REASON_NOT_FOUND,
                       "the part carries no package drawing")
    data = detail.get("dataStr")
    head = data.get("head") if isinstance(data, Mapping) else None
    shapes = data.get("shape") if isinstance(data, Mapping) else None
    # `list`, not `Sequence`: a str IS a Sequence, so a payload whose `shape`
    # arrived as a string would iterate character by character and normalize
    # to a drawing with nothing in it instead of saying it was malformed.
    if not isinstance(head, Mapping) or not isinstance(shapes, (list, tuple)):
        return Absence(part, REASON_MALFORMED,
                       "the package drawing states no head/shape")
    origin_x, origin_y = _f(head.get("x")), _f(head.get("y"))
    if origin_x is None or origin_y is None:
        return Absence(part, REASON_MALFORMED,
                       "the package drawing states no origin")

    pads, dupes = _pads(shapes, origin_x, origin_y)
    model = _model_reference(shapes, origin_x, origin_y)
    if not pads and model is None:
        # Head and shape were both present and neither carried anything a
        # consumer could use. A truncated body looks exactly like this, and
        # reporting it as facts would hand every consumer an empty drawing.
        return Absence(part, REASON_MALFORMED,
                       "the package drawing carries neither pads nor a model")
    lcsc = result.get("lcsc")
    stated = str(lcsc.get("number") or "") if isinstance(lcsc, Mapping) else ""
    return PartFacts(
        part=part or stated,
        title=str(result.get("title") or ""),
        package=str(detail.get("title") or ""),
        package_uuid=str(detail.get("uuid") or ""),
        head_origin=(origin_x, origin_y),
        pads=pads,
        duplicate_numbers=dupes,
        model=model,
        provenance=provenance,
    )


# ---------------------------------------------------------------------------
# Transport — one place that touches the network
# ---------------------------------------------------------------------------


class _Unreachable(Exception):
    """Internal: the network said no. Converted to an Absence at the boundary
    and never allowed out of this module."""


def _http_get(url: str, *, user_agent: str, timeout: float) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": user_agent})
    try:
        # Fixed https hosts, both stated as module constants.
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            return response.read()
    except urllib.error.HTTPError as exc:
        raise _Unreachable(f"HTTP {exc.code} from {url}") from exc
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise _Unreachable(f"{type(exc).__name__}: {exc} ({url})") from exc


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ---------------------------------------------------------------------------
# The client
# ---------------------------------------------------------------------------


@dataclass(eq=False)
class VendorPartClient:
    """Fetch-at-most-once, cache, and parse. Safe to share across threads.

    Two layers of "do not fetch again", each answering a different question:

    * an in-process memo, keyed by part number, holding EVERY outcome
      including absences — so one export that touches a part forty times, or
      fails to reach the network once, issues one request at most; and
    * the on-disk per-user cache, holding only SUCCESSFUL bodies — so the next
      export, in the next process, costs no network either.

    Failures are deliberately not written to disk. A part absent today because
    a supplier added it yesterday must not stay absent forever, and a network
    outage must not be preserved across reboots.
    """

    api_base: str = API_BASE
    api_version: str = API_VERSION
    model_base: str = MODEL_BASE
    user_agent: str = USER_AGENT
    timeout: float = TIMEOUT_S
    max_workers: int = MAX_WORKERS

    _facts: dict = field(default_factory=dict, init=False, repr=False)
    _models: dict = field(default_factory=dict, init=False, repr=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, init=False,
                                  repr=False)

    # -- cache plumbing ----------------------------------------------------

    def _dir(self, sub: str) -> Union[Path, None]:
        """The cache subdirectory, or None when caching is unavailable.

        Resolved on EVERY call rather than at construction, because the
        contract in :mod:`pcb_worker.cache_dir` allows the tree to be deleted
        underneath us at any moment.
        """
        root = cache_dir.tenant_dir(CACHE_TENANT)
        if root is None:
            return None
        path = root / sub
        try:
            path.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            log.warning("vendor cache unavailable at %s (%s)", path, exc)
            return None
        return path

    def _cache_read(self, sub: str, name: str, url: str,
                    ) -> Union[tuple[bytes, Provenance], None]:
        """A cached body fetched from exactly ``url``, or None.

        THE URL IS PART OF THE KEY even though the filename is not. An entry is
        named for the catalogue number alone, so bumping :data:`API_VERSION` —
        the one lever there is when the payload shape changes upstream — would
        otherwise keep serving the old shape from a cache that never expires. A
        recorded url that differs from the one being requested is a MISS, and
        the refetch overwrites the entry.
        """
        directory = self._dir(sub)
        if directory is None:
            return None
        body, meta = directory / name, directory / f"{name}.meta.json"
        try:
            data = body.read_bytes()
            recorded = json.loads(meta.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        if str(recorded.get("url") or "") != url:
            return None
        digest = hashlib.sha256(data).hexdigest()
        if digest != recorded.get("sha256"):
            # A torn write or an edited cache entry. Refetch rather than trust
            # it: provenance that does not match its bytes is worse than none.
            log.warning("cache entry %s does not match its recorded hash", body)
            return None
        return data, Provenance(url=url,
                                sha256=digest,
                                fetched_at=str(recorded.get("fetched_at") or ""),
                                size_bytes=len(data),
                                from_cache=True)

    def _cache_write(self, sub: str, name: str, data: bytes,
                     provenance: Provenance) -> None:
        directory = self._dir(sub)
        if directory is None:
            return
        try:
            (directory / name).write_bytes(data)
            (directory / f"{name}.meta.json").write_text(json.dumps({
                "url": provenance.url,
                "sha256": provenance.sha256,
                "fetched_at": provenance.fetched_at,
                "size_bytes": provenance.size_bytes,
            }, indent=1, sort_keys=True), encoding="utf-8")
        except OSError as exc:
            # An unwritable cache costs speed, never correctness.
            log.warning("could not cache %s/%s (%s)", sub, name, exc)

    def _get(self, sub: str, name: str, url: str,
             ) -> Union[tuple[bytes, Provenance], _Unreachable]:
        hit = self._cache_read(sub, name, url)
        if hit is not None:
            return hit
        try:
            data = _http_get(url, user_agent=self.user_agent,
                             timeout=self.timeout)
        except _Unreachable as exc:
            return exc
        return data, Provenance(url=url,
                                sha256=hashlib.sha256(data).hexdigest(),
                                fetched_at=_now(), size_bytes=len(data))

    # -- the surface -------------------------------------------------------

    def facts(self, part: str) -> Union[PartFacts, Absence]:
        """Normalized vendor facts for one catalogue number. Never raises."""
        key = (part or "").strip()
        if not key:
            return Absence("", REASON_NO_PART_NUMBER,
                           "the placement carries no catalogue number")
        if not _PART_RE.match(key):
            return Absence(key, REASON_NO_PART_NUMBER,
                           f"{key!r} is not a usable catalogue number")
        with self._lock:
            memo = self._facts.get(key)
        if memo is not None:
            return memo
        answer = self._load_facts(key)
        with self._lock:
            self._facts.setdefault(key, answer)
            return self._facts[key]

    def _load_facts(self, part: str) -> Union[PartFacts, Absence]:
        url = f"{self.api_base}{part}/components?version={self.api_version}"
        got = self._get("components", f"{part}.json", url)
        if isinstance(got, _Unreachable):
            return Absence(part, REASON_NO_NETWORK, str(got))
        data, provenance = got
        try:
            payload = json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            return Absence(part, REASON_MALFORMED,
                           f"response is not JSON ({exc})")
        parsed = parse_component_payload(payload, part, provenance)
        # Only a real drawing is worth keeping. Caching a "component not
        # found" body — which arrives with HTTP 200 — would make a part the
        # supplier adds next week permanently invisible.
        if not parsed.absent and not provenance.from_cache:
            self._cache_write("components", f"{part}.json", data, provenance)
        return parsed

    def facts_for(self, parts: Iterable[str],
                  ) -> dict[str, Union[PartFacts, Absence]]:
        """:meth:`facts` for many parts, concurrently and at most once each.

        Deduplicated before dispatch, so a board that buys the same resistor
        thirty times issues one request.
        """
        wanted = sorted({(p or "").strip() for p in parts})
        if not wanted:
            return {}
        workers = max(1, min(self.max_workers, len(wanted)))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            return dict(zip(wanted, pool.map(self.facts, wanted)))

    def model(self, part_or_facts: Union[str, PartFacts, Absence],
              ) -> Union[PartModel, Absence]:
        """The 3D model a part's facts point at. Never raises.

        Accepts a catalogue number (facts are looked up, hitting the same memo)
        or facts already in hand, so a consumer that wants both pays for one
        document.
        """
        facts = (self.facts(part_or_facts)
                 if isinstance(part_or_facts, str) else part_or_facts)
        if facts.absent:
            return facts            # already says why
        if facts.model is None:
            return Absence(facts.part, REASON_NO_MODEL,
                           "the package drawing references no 3D model")
        uuid = facts.model.uuid
        with self._lock:
            memo = self._models.get(uuid)
        if memo is not None:
            return memo
        answer = self._load_model(facts.part, uuid)
        with self._lock:
            self._models.setdefault(uuid, answer)
            return self._models[uuid]

    def _load_model(self, part: str, uuid: str) -> Union[PartModel, Absence]:
        got = self._get("models", f"{uuid}.obj", f"{self.model_base}{uuid}")
        if isinstance(got, _Unreachable):
            return Absence(part, REASON_NO_NETWORK, str(got))
        data, provenance = got
        mesh = parse_obj(data.decode("utf-8", errors="replace"))
        if mesh.empty:
            # A retired uuid answers with an object-store XML error, not a 404
            # body we could recognise by status. An empty mesh IS the signal.
            return Absence(part, REASON_NO_MODEL,
                           f"model {uuid} carries no geometry")
        if not provenance.from_cache:
            self._cache_write("models", f"{uuid}.obj", data, provenance)
        return PartModel(part=part, uuid=uuid, mesh=mesh,
                         provenance=provenance)

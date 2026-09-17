"""Chunked transfer for replies a bounded caller cannot take whole.

HTML panels reach this plugin through `window.minerva.call`, which the host
rewrites to an IPC message bounded at 65,536 UTF-8 bytes in BOTH directions;
webviews have no bulk route, so a reply bigger than that is replaced by a
payload_too_large error and the panel gets nothing. `get_graph` (every symbol
and edge) and `get_diff` (before, after and unified text per changed file)
routinely cross that bound.

A caller that is bounded asks for the reply in parts:

    {...normal args..., "page": {"max_bytes": 49152}}   -> part 0 + a token
    {...normal args..., "page": {"token": "<t>", "part": k}}   -> part k

Each part is itself an ordinary ok-envelope carrying one `paged_envelope`
artifact whose `chunk` is a slice of the REAL envelope's JSON text. The caller
concatenates the chunks in order and parses the result, which IS the unpaged
envelope — so the reply shape stays exactly the same for a caller (an agent
over stdio) that never passes `page`.

Parts after the first are served from this process's cache, so the handler runs
once per transfer. A token that has been evicted fails loudly
(kind="paging_expired") rather than handing back a truncated document.
"""

from __future__ import annotations

import json
import time
import uuid
from collections import OrderedDict

from .errors import ToolError

PAGE_PARAM = "page"

# The host's control-lane bound. A caller should ask for less than this so the
# host's own reply wrapper still fits; we refuse to promise more.
CONTROL_BYTES = 64 * 1024
DEFAULT_CHUNK_BYTES = 32 * 1024
MIN_CHUNK_BYTES = 4096

# Transfers in flight, oldest touched first. A transfer is dropped the moment
# its last part is served, so a slot is held only while a caller is still
# walking one. 32 slots is far more than the work this plugin sees — a panel
# runs two transfers (graph + diff) at a time, so it covers a dozen panels
# mid-transfer at once — while still bounding memory, since each entry holds a
# whole serialized envelope.
_CACHE: "OrderedDict[str, dict]" = OrderedDict()
_ACTIVE_LIMIT = 32
# A transfer nobody has continued for this long has been abandoned (its panel
# closed or reloaded); it is evicted before any transfer still being walked.
_STALE_SECONDS = 300.0

ARTIFACT_TYPE = "paged_envelope"


def _clamp_budget(page):
    requested = page.get("max_bytes", DEFAULT_CHUNK_BYTES)
    if not isinstance(requested, (int, float)) or isinstance(requested, bool):
        raise ToolError("page.max_bytes must be a number", kind="invalid_args")
    return max(MIN_CHUNK_BYTES, min(CONTROL_BYTES, int(requested)))


# Room for the host's own frame around the part: {"success":true,"result":
# {"content":[{"type":"text","text":...}]},"id":"<uuid>"}.
_HOST_FRAME_BYTES = 192


def _wire_bytes(reply):
    """Bytes the host measures for one part.

    A part travels as MCP text content: this plugin marshals the envelope,
    nests that TEXT inside the tool result, and the host re-serializes the
    whole reply — so the envelope is escaped a second time on the way out and
    a quote-dense chunk nearly doubles. Measure that, not the envelope alone,
    or the cap is crossed by a reply that looked comfortably small here.
    """
    text = '{"ok":true,"result":' + json.dumps(reply) + "}"
    return len(json.dumps(text).encode("utf-8")) + _HOST_FRAME_BYTES


def _split(text, token, total_bytes, budget):
    """Slice `text` so each part's wire form fits `budget` bytes.

    Slicing is by code point, so no surrogate pair or escape sequence is split.
    """
    chunks = []
    i, n = 0, len(text)
    # Halve the first guess up front: the wire form of a chunk is roughly twice
    # its own length once escaped, so this usually lands in one measurement.
    take = max(1, budget // 2)
    while i < n:
        take = min(take, n - i)
        while True:
            piece = text[i:i + take]
            size = _wire_bytes(_reply(token, len(chunks), 999999, total_bytes, piece))
            if size <= budget or take <= 1:
                break
            # Shrink by the measured overshoot ratio: converges in a step or
            # two even when the slice is all quotes or all astral characters.
            take = max(1, min(take - 1, take * budget // size))
        chunks.append(piece)
        i += take
    return chunks


def _reply(token, part, parts, total_bytes, chunk):
    # Built here rather than via envelope.ok() to avoid an import cycle; the
    # router validates it like any other envelope.
    return {
        "status": "ok",
        "summary": "paged reply: part %d/%d (%d bytes total)" % (
            part + 1, parts, total_bytes),
        "artifacts": [{
            "type": ARTIFACT_TYPE,
            "token": token,
            "part": part,
            "parts": parts,
            "total_bytes": total_bytes,
            "encoding": "json",
            "chunk": chunk,
        }],
        "evidence_handles": [],
        "follow_ups": [],
    }


def _part_reply(token, entry, part):
    return _reply(token, part, len(entry["chunks"]), entry["total_bytes"],
                  entry["chunks"][part])


def _evict_one(now):
    """Drop the most expendable transfer: the longest-abandoned one, else the
    least recently touched."""
    stale = [t for t, e in _CACHE.items() if now - e["touched"] > _STALE_SECONDS]
    _CACHE.pop(stale[0] if stale else next(iter(_CACHE)), None)


def _remember(token, method, chunks, total_bytes):
    now = time.monotonic()
    while len(_CACHE) >= _ACTIVE_LIMIT:
        _evict_one(now)
    _CACHE[token] = {"method": method, "chunks": chunks,
                     "total_bytes": total_bytes, "touched": now}


def route(method, params, handler):
    """Run `handler`, paging its envelope when the caller asked for parts.

    Without a `page` argument this is a plain call — the handler's envelope is
    returned untouched.
    """
    page = params.get(PAGE_PARAM) if isinstance(params, dict) else None
    if not isinstance(page, dict):
        return handler(params)

    token = page.get("token")
    if token:
        entry = _CACHE.get(str(token))
        if entry is None or entry["method"] != method:
            raise ToolError(
                "paged reply %r is no longer available for %s; restart the "
                "transfer from part 0" % (token, method),
                kind="paging_expired")
        part = page.get("part", 0)
        if not isinstance(part, int) or isinstance(part, bool) \
                or not 0 <= part < len(entry["chunks"]):
            raise ToolError(
                "page.part must be an integer in 0..%d" % (len(entry["chunks"]) - 1),
                kind="invalid_args")
        reply = _part_reply(str(token), entry, part)
        if part == len(entry["chunks"]) - 1:
            # The caller has everything: free the slot now rather than waiting
            # for eviction to notice.
            _CACHE.pop(str(token), None)
        else:
            entry["touched"] = time.monotonic()
            _CACHE.move_to_end(str(token))
        return reply

    budget = _clamp_budget(page)
    inner = {k: v for k, v in params.items() if k != PAGE_PARAM}
    env = handler(inner)
    if not isinstance(env, dict) or env.get("status") != "ok":
        # Failures are small and must reach the caller as themselves, not as
        # part 0 of a transfer it would then have to reassemble to read.
        return env

    text = json.dumps(env, ensure_ascii=False, separators=(",", ":"))
    total_bytes = len(text.encode("utf-8"))
    new_token = uuid.uuid4().hex
    if _wire_bytes(_reply(new_token, 0, 999999, total_bytes, "")) >= budget:
        raise ToolError(
            "page.max_bytes %d leaves no room for a chunk" % budget,
            kind="invalid_args")
    chunks = _split(text, new_token, total_bytes, budget)
    _remember(new_token, method, chunks, total_bytes)
    reply = _part_reply(new_token, _CACHE[new_token], 0)
    if len(chunks) == 1:
        # Nothing left to fetch — the transfer never needs a slot.
        _CACHE.pop(new_token, None)
    return reply

"""Cross-language canonical bytes and stable PCB entity identifiers.

The canonical form is RFC 8785 JSON Canonicalization Scheme (JCS), not
``json.dumps(sort_keys=True)``.  JCS fixes string escaping, UTF-16 property
ordering, and ECMAScript's number spelling so Python and the future Go/YAML-v2
writer hash exactly the same bytes.

Only I-JSON values are accepted: mappings with string keys, sequences, strings,
booleans, ``None``, IEEE-754 finite floats, and integers in the exactly-safe
JSON range.  Callers deliberately build plain canonical payloads rather than
letting this module guess how arbitrary dataclasses should serialize.

Reference: RFC 8785 sections 3.1-3.2 and Appendix B.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
import hashlib
import math
import re
from typing import Any


class CanonicalizationError(ValueError):
    """Input cannot be represented by the project's RFC-8785 subset."""


_SAFE_INTEGER_MAX = (2**53) - 1
_CONTROL_OR_QUOTE = re.compile(r'[\x00-\x1f\\"]')
_SHORT_ESCAPES = {
    "\b": "\\b",
    "\t": "\\t",
    "\n": "\\n",
    "\f": "\\f",
    "\r": "\\r",
    '"': '\\"',
    "\\": "\\\\",
}


def _escape_string(value: str) -> bytes:
    """Return one JCS JSON string, rejecting lone Unicode surrogates."""

    def replace(match: re.Match[str]) -> str:
        char = match.group(0)
        return _SHORT_ESCAPES.get(char, f"\\u{ord(char):04x}")

    escaped = _CONTROL_OR_QUOTE.sub(replace, value)
    try:
        return ('"' + escaped + '"').encode("utf-8")
    except UnicodeEncodeError as exc:
        raise CanonicalizationError("strings must not contain lone surrogates") from exc


def _utf16_sort_key(value: str) -> bytes:
    try:
        return value.encode("utf-16be")
    except UnicodeEncodeError as exc:
        raise CanonicalizationError("object keys must not contain lone surrogates") from exc


def _number_bytes(value: float) -> bytes:
    """Serialize a float with ECMAScript/JCS spelling.

    CPython already chooses the shortest round-tripping significand.  The
    remaining work is applying ECMAScript's decimal-vs-exponent thresholds,
    suppressing ``.0``, normalizing exponent zeros, and canonicalizing -0.
    The RFC Appendix-B vectors pin edge behavior.
    """
    if not math.isfinite(value):
        raise CanonicalizationError("NaN and Infinity are not valid JCS numbers")
    if value == 0.0:
        return b"0"
    if value < 0.0:
        return b"-" + _number_bytes(-value)

    rendered = str(value)
    exponent = 0
    exponent_text = ""
    if "e" in rendered:
        mantissa, raw_exponent = rendered.split("e", 1)
        exponent = int(raw_exponent)
        exponent_text = f"e{exponent:+d}"
    else:
        mantissa = rendered

    if "." in mantissa:
        first, fraction = mantissa.split(".", 1)
    else:
        first, fraction = mantissa, ""
    if fraction == "0":
        fraction = ""

    # ECMAScript renders positive exponents below 21 as ordinary decimal.
    if 0 < exponent < 21:
        digits = first + fraction
        zeros = exponent - len(fraction)
        if zeros >= 0:
            rendered = digits + ("0" * zeros)
        else:
            split = len(digits) + zeros
            rendered = digits[:split] + "." + digits[split:]
        return rendered.encode("ascii")

    # ECMAScript renders e-1 through e-6 as ordinary leading-zero decimal.
    if -7 < exponent < 0:
        digits = first + fraction
        return ("0." + ("0" * (-exponent - 1)) + digits).encode("ascii")

    mantissa = first + (("." + fraction) if fraction else "")
    return (mantissa + exponent_text).encode("ascii")


def canonicalize(value: Any) -> bytes:
    """Return RFC-8785 canonical UTF-8 bytes for an I-JSON value."""
    if value is None:
        return b"null"
    if isinstance(value, bool):
        return b"true" if value else b"false"
    if isinstance(value, int):
        if not -_SAFE_INTEGER_MAX <= value <= _SAFE_INTEGER_MAX:
            raise CanonicalizationError(
                f"integer {value} exceeds the exactly-safe I-JSON range"
            )
        return str(value).encode("ascii")
    if isinstance(value, float):
        return _number_bytes(value)
    if isinstance(value, str):
        return _escape_string(value)
    if isinstance(value, Mapping):
        items: list[tuple[str, Any]] = []
        for key, item in value.items():
            if not isinstance(key, str):
                raise CanonicalizationError("object keys must be strings")
            items.append((key, item))
        items.sort(key=lambda pair: _utf16_sort_key(pair[0]))
        body = b",".join(
            _escape_string(key) + b":" + canonicalize(item)
            for key, item in items
        )
        return b"{" + body + b"}"
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return b"[" + b",".join(canonicalize(item) for item in value) + b"]"
    raise CanonicalizationError(f"unsupported canonical value type: {type(value).__name__}")


def content_id(value: Any) -> str:
    """Full SHA-256 hex digest of one canonical content payload."""
    return hashlib.sha256(canonicalize(value)).hexdigest()


def derive_id(entity_type: str, *identity_parts: Any) -> str:
    """Derive a 128-bit namespaced entity ID from canonical identity parts."""
    if not entity_type or ":" in entity_type:
        raise ValueError("entity_type must be a non-empty colon-free string")
    digest = content_id({"parts": list(identity_parts), "type": entity_type})
    return f"{entity_type}:{digest[:32]}"

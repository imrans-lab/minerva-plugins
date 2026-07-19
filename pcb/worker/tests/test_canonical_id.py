"""RFC-8785 canonical bytes are the persisted PCB identity foundation."""

from __future__ import annotations

import struct

import pytest

from pcb_worker.canonical_id import (
    CanonicalizationError,
    canonicalize,
    content_id,
    derive_id,
)


@pytest.mark.parametrize(("ieee_hex", "expected"), [
    ("0000000000000000", b"0"),
    ("8000000000000000", b"0"),
    ("0000000000000001", b"5e-324"),
    ("8000000000000001", b"-5e-324"),
    ("7fefffffffffffff", b"1.7976931348623157e+308"),
    ("ffefffffffffffff", b"-1.7976931348623157e+308"),
    ("4340000000000000", b"9007199254740992"),
    ("c340000000000000", b"-9007199254740992"),
    ("4430000000000000", b"295147905179352830000"),
    ("44b52d02c7e14af5", b"9.999999999999997e+22"),
    ("44b52d02c7e14af6", b"1e+23"),
    ("44b52d02c7e14af7", b"1.0000000000000001e+23"),
    ("444b1ae4d6e2ef4e", b"999999999999999700000"),
    ("444b1ae4d6e2ef4f", b"999999999999999900000"),
    ("444b1ae4d6e2ef50", b"1e+21"),
    ("3eb0c6f7a0b5ed8c", b"9.999999999999997e-7"),
    ("3eb0c6f7a0b5ed8d", b"0.000001"),
    ("43143ff3c1cb0959", b"1424953923781206.2"),
])
def test_rfc8785_appendix_b_number_vectors(ieee_hex, expected):
    value = struct.unpack(">d", bytes.fromhex(ieee_hex))[0]
    assert canonicalize(value) == expected


def test_rfc8785_recursive_utf16_sort_and_string_escaping():
    value = {
        "\u20ac": "Euro Sign",
        "\r": "Carriage Return",
        "\ufb33": "Hebrew Letter Dalet With Dagesh",
        "1": "One",
        "\U0001f600": "Emoji: Grinning Face",
        "\u0080": "Control",
        "\u00f6": "Latin Small Letter O With Diaeresis",
    }
    encoded = canonicalize(value).decode("utf-8")
    values = [
        "Carriage Return", "One", "Control",
        "Latin Small Letter O With Diaeresis", "Euro Sign",
        "Emoji: Grinning Face", "Hebrew Letter Dalet With Dagesh",
    ]
    assert [encoded.index(v) for v in values] == sorted(encoded.index(v) for v in values)
    assert canonicalize("€$\x0f\nA'B\"\\\\\"/") == (
        "\"€$\\u000f\\nA'B\\\"\\\\\\\\\\\"/\"".encode("utf-8")
    )


def test_canonical_structure_is_order_independent_and_compact():
    left = {"z": [None, True, False], "a": {"b": 1.0, "a": -0.0}}
    right = {"a": {"a": -0.0, "b": 1.0}, "z": [None, True, False]}
    expected = b'{"a":{"a":0,"b":1},"z":[null,true,false]}'
    assert canonicalize(left) == canonicalize(right) == expected
    assert content_id(left) == content_id(right)


def test_cross_language_content_and_entity_id_goldens():
    value = {
        "board": "board:α",
        "geometry": {"x": 1.0, "y": -0.0},
        "text": "<tag>&\u2028",
    }
    assert canonicalize(value) == (
        b'{"board":"board:\xce\xb1","geometry":{"x":1,"y":0},'
        b'"text":"<tag>&\xe2\x80\xa8"}'
    )
    assert content_id(value) == (
        "dcc2e501cb30c1579f38b173cc830fde09ca95f22e926d4865d57aea3439556a"
    )
    assert derive_id("trace", "board:one", "legacy-trace-0") == (
        "trace:cab27b43cec9cce580f4bfaad501883f"
    )


def test_canonicalization_rejects_non_ijson_values():
    for bad in (float("nan"), float("inf"), float("-inf"), 2**53, {1: "x"}):
        with pytest.raises(CanonicalizationError):
            canonicalize(bad)
    with pytest.raises(CanonicalizationError):
        canonicalize("\ud800")


def test_derive_id_is_namespaced_stable_and_128_bit():
    got = derive_id("trace", "board:one", "legacy-trace-0")
    assert got == derive_id("trace", "board:one", "legacy-trace-0")
    prefix, digest = got.split(":", 1)
    assert prefix == "trace"
    assert len(digest) == 32
    int(digest, 16)
    assert got != derive_id("trace", "board:two", "legacy-trace-0")
    assert got != derive_id("via", "board:one", "legacy-trace-0")

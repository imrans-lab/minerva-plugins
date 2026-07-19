from pcb_worker.pad_types import (
    is_known_pad_type,
    normalize_pad_type,
    semantic_pad_type,
)


def test_legacy_normalization_contract_is_unchanged():
    assert normalize_pad_type("smd") == "smd"
    assert normalize_pad_type("thru_hole") == "thru_hole"
    assert normalize_pad_type("np_thru_hole") == "np_thru_hole"
    assert normalize_pad_type("connect") == "smd"
    assert normalize_pad_type("unknown") == "smd"
    assert normalize_pad_type(None) == "smd"


def test_schema_semantics_preserve_connect_and_expose_unknown():
    assert semantic_pad_type("connect") == "connect"
    assert semantic_pad_type("unknown") == "smd"
    assert is_known_pad_type("connect") is True
    assert is_known_pad_type("unknown") is False

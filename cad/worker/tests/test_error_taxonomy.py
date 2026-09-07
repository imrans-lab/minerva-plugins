"""What an evaluate/export failure tells the reader.

Two questions, one suite:

* does each stage of the pipeline land on its OWN error kind — a typo is not a
  plugin crash — and does a syntax error carry the line and column that let an
  editor put a caret on it; and
* when the geometry kernel raises inside a build step, does the reply name the
  DSL binding that was building and carry the whole traceback?

ORACLE. The kinds are the contract the panel and the modeling skill are written
against (manifest.json §6: parse / translate / occt / python). The attribution
is checked
against the exception the kernel actually raises for the sources here — a fillet
larger than the solid, and the three-section `hump_in` loft of enclosure-rev3,
which is the reproduction on record for the tessellation failure. Neither source
is mocked and neither kind is asserted from a table: the worker builds the real
geometry and the assertions read its real reply.
"""

from __future__ import annotations

from pathlib import Path

import pytest

pytest.importorskip("build123d", reason="build123d not installed in this environment")

from mcad_worker import methods  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[2] / "tests" / "fixtures" / "smart-remote-v2"

#: A lex error (an unexpected character), a parse error (a well-formed token
#: stream the grammar rejects) and a translate error (valid syntax, no such
#: function). All three are ordinary user typos.
LEX_SOURCE = "part = cube(3);"
PARSE_SOURCE = "part = box(1, 1, 1)\npart = "
TRANSLATE_SOURCE = "part = boxx(1, 1, 1)"

#: A real kernel refusal inside one build step: no fillet of radius 20 fits on
#: a 10 mm cube, and build123d raises a bare ValueError that names no binding.
KERNEL_SOURCE = "part = cube(10, 10, 10)\nfillet part, [1], r=20"

#: The two-section loft in the committed rev-3 fixture, and the three-section
#: variant that fails in tessellation. Substituted rather than copied so the
#: fixture stays the single source of truth for the rest of the document.
TWO_SECTION_HUMP = (
    "hump_in = loft:\n"
    "    z=9: rect(68, 108)\n"
    "    z=21.5: rect(50, 94)\n"
)
THREE_SECTION_HUMP = (
    "hump_in = loft:\n"
    "    z=9: rect(68, 108)\n"
    "    z=17: rect(56, 98)\n"
    "    z=21.5: rect(50, 94)\n"
)


def _error(source: str) -> dict:
    methods.reset_caches()
    reply = methods._evaluate({"source": source})
    assert reply["ok"] is False, f"expected a failure, got {list(reply)}"
    return reply["error"]


def test_lex_parse_and_translate_errors_each_land_on_their_own_kind() -> None:
    lex = _error(LEX_SOURCE)
    assert lex["kind"] == "parse", lex
    assert lex["details"]["line"] == 1 and lex["details"]["col"] > 0, lex
    assert "traceback" not in lex, "a typo is not a plugin crash"

    parsed = _error(PARSE_SOURCE)
    assert parsed["kind"] == "parse", parsed
    assert parsed["details"]["line"] == 2, parsed

    translated = _error(TRANSLATE_SOURCE)
    assert translated["kind"] == "translate", translated
    assert "boxx" in translated["message"], translated


def test_export_reports_a_lex_error_the_same_way_evaluate_does(tmp_path: Path) -> None:
    methods.reset_caches()
    reply = methods._export(
        {"source": LEX_SOURCE, "format": "stl", "path": str(tmp_path / "x.stl")}
    )
    assert reply["ok"] is False
    assert reply["error"]["kind"] == "parse", reply["error"]
    assert reply["error"]["details"]["line"] == 1, reply["error"]


def test_a_kernel_failure_names_the_binding_and_keeps_its_traceback() -> None:
    err = _error(KERNEL_SOURCE)
    assert err["kind"] == "occt", err
    assert err["details"]["binding"] == "part", err
    assert err["details"]["stage"] == "build", err
    assert err["details"]["line"] == 2, err
    assert "part" in err["message"]
    # The innermost frame is what says which kernel call raised; a truncated
    # traceback loses exactly that line.
    tb = err.get("traceback", "")
    assert tb.startswith("Traceback (most recent call last):"), tb
    assert "ValueError" in tb.splitlines()[-1], tb
    assert "build123d" in tb, tb


def test_the_three_section_hump_attributes_its_tessellation_failure() -> None:
    source = (FIXTURES / "enclosure-rev3.mcad").read_text(encoding="utf-8")
    assert TWO_SECTION_HUMP in source, "the rev-3 fixture no longer holds hump_in"
    err_source = source.replace(TWO_SECTION_HUMP, THREE_SECTION_HUMP)

    methods.reset_caches()
    reply = methods._evaluate({"source": err_source})
    if reply["ok"]:
        pytest.skip("the kernel now tessellates the three-section hump")

    err = reply["error"]
    assert err["kind"] == "occt", err
    assert err["details"]["stage"] == "tessellate", err
    assert err["details"]["binding"] == "enclosure", err
    assert "enclosure" in err["message"]
    assert "Traceback (most recent call last):" in err.get("traceback", ""), err
    # The face probe runs on the failure path only; when OCCT names any face at
    # all it is a place in the model to look, so it must carry a location.
    for face in err["details"].get("untriangulated_faces", []):
        assert len(face["center"]) == 3, face


#: A build the kernel refuses at tessellation with a BUILTIN exception type —
#: `AttributeError: 'NoneType' object has no attribute 'NbNodes'` from a
#: zero-radius cylinder. The class alone cannot tell this apart from a bug in
#: the DSL's own frames, so it is the case the attribution has to get right.
KERNEL_BUILTIN_SOURCE = "part = cylinder(r=0, h=10)"


def _build_failure(cause: BaseException, *, binding: str, line: int):
    from mcad.build_trace import BuildFailure

    return BuildFailure(binding=binding, stage="build", cause=cause, line=line)


def test_a_kernel_failure_raised_as_a_builtin_is_still_a_kernel_failure() -> None:
    """The exception CLASS does not decide the kind; the frame that raised does.

    ORACLE: the real reply for a zero-radius cylinder. build123d hands back a
    shape OCCT will not mesh and the failure surfaces as a bare AttributeError
    — a type the DSL's own frames raise too — so a reader that split the kinds
    on the class would file this under the user's Python instead of the
    kernel, and the untriangulated-face list it carries would make no sense.
    """
    err = _error(KERNEL_BUILTIN_SOURCE)
    assert err["kind"] == "occt", err
    assert err["details"]["exception"] == "AttributeError", err
    assert err["details"]["stage"] == "tessellate", err
    assert "geometry kernel" in err["message"], err


def test_a_python_error_while_building_keeps_the_binding_but_not_the_kernel() -> None:
    """A non-kernel exception is attributed, not blamed on OCCT.

    The `except Exception` around each statement is a net for anything the
    kernel packages did not raise as well — an arithmetic slip, a bad keyword
    argument, a control-flow signal escaping its module. Those must keep the
    binding and the line, which is the whole point of running the statements
    one at a time, while reporting the kind that sends the reader to the right
    place.

    ORACLE: two exceptions that really were raised, one in this module's own
    frames and one inside build123d, put through the same constructor. No
    stand-ins: the kernel one is produced by asking build123d to build a solid
    with a negative dimension.

    Nothing in the V1 DSL is known to reach the python branch end to end —
    every arithmetic, argument and control-flow path measured is guarded and
    lands on `translate` or `parse` first — so the seam is tested where it
    exists rather than through a source string that cannot trigger it.
    """
    try:
        1 / 0
    except ZeroDivisionError as exc:
        arithmetic = _build_failure(exc, binding="lid", line=7)
    assert arithmetic.kind == "python"
    assert arithmetic.details()["binding"] == "lid"
    assert arithmetic.details()["line"] == 7
    assert "geometry kernel" not in str(arithmetic)
    assert "lid" in str(arithmetic) and "line 7" in str(arithmetic)

    from build123d import Box

    try:
        Box(-1, -1, -1)
    except BaseException as exc:  # noqa: BLE001 — whatever the kernel raises
        kernel = _build_failure(exc, binding="lid", line=7)
    else:
        pytest.skip("the kernel now accepts a negative box")
    assert kernel.kind == "occt"
    assert "geometry kernel" in str(kernel)

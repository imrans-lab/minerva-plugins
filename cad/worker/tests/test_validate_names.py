"""validate resolves names, so it cannot bless source the translator refuses.

Validate used to stop after parsing, which accepts any call shape at all: an
OpenSCAD ``difference()`` and a diameter keyword both parsed clean and only
failed one verb later, at evaluate. Every §0 anti-pattern the skill warns about
is checked here, each expected to produce exactly one error with a position.

ORACLE. An independent observation that would show this wrong: run
``cad_evaluate`` on the same source. Anything validate calls clean must
evaluate, and anything validate rejects must fail there too — the two verbs
share the builtin table, and a disagreement between them is the defect this
file exists to catch. The last case does exactly that comparison.
"""

import pytest

from mcad_worker.methods import _validate

# The §0 anti-patterns, each with what makes it wrong.
ANTI_PATTERNS = {
    "slash comment": "// a comment\npart = cube(3)\n",
    "semicolon": "part = cube(3);\n",
    "diameter keyword": "part = sphere(d=10)\n",
    "openscad difference": "part = difference(cube(3), cube(1))\n",
    "openscad union block": "union() {}\n",
}


def _result(source: str) -> dict:
    response = _validate({"source": source})
    assert response["ok"] is True
    return response["result"]


class TestTheAntiPatternsAreCaught:
    @pytest.mark.parametrize("name", sorted(ANTI_PATTERNS))
    def test_one_error_with_a_position(self, name):
        result = _result(ANTI_PATTERNS[name])
        assert result["ok"] is False
        assert len(result["errors"]) == 1, result["errors"]
        error = result["errors"][0]
        assert error["line"] >= 1
        assert "col" in error
        assert error["message"]

    def test_the_unknown_function_is_named_with_the_operator_to_use(self):
        result = _result(ANTI_PATTERNS["openscad difference"])
        message = result["errors"][0]["message"]
        assert "difference" in message
        assert "a - b" in message

    def test_the_diameter_keyword_is_named_with_the_radius_to_use(self):
        result = _result(ANTI_PATTERNS["diameter keyword"])
        message = result["errors"][0]["message"]
        assert "sphere()" in message
        assert "r=" in message


class TestValidStaysValid:
    def test_the_same_model_written_in_the_dsl_passes(self):
        result = _result(
            "part = cube(30,30,10) - translate([15,15,-1], cylinder(h=12,r=1.7))\n"
        )
        assert result["ok"] is True
        assert result["errors"] == []

    def test_a_user_module_is_not_an_unknown_function(self):
        result = _result(
            "module post(r):\n    return cylinder(h=5, r=r)\n\npart = post(2)\n"
        )
        assert result["ok"] is True, result["errors"]

    def test_a_command_keyword_is_checked_too(self):
        result = _result("part = cube(10,10,10)\nfillet part, 1, d=2\n")
        assert result["ok"] is False
        assert "fillet" in result["errors"][0]["message"]


class TestValidateAgreesWithTheTranslator:
    """The two must share one table; a name in one and not the other is the bug."""

    def test_every_builtin_the_translator_dispatches_is_in_the_table(self):
        import inspect
        import re

        from mcad import builtins
        from mcad.translator import Translator

        source = inspect.getsource(Translator._eval_func_call)
        dispatched = set(re.findall(r'node\.name == "(\w+)"', source))
        assert dispatched == set(builtins.BUILTIN_FUNCTIONS), (
            dispatched.symmetric_difference(builtins.BUILTIN_FUNCTIONS)
        )

    def test_every_command_the_translator_dispatches_is_in_the_table(self):
        import inspect
        import re

        from mcad import builtins
        from mcad.translator import Translator

        source = inspect.getsource(Translator._eval_command)
        dispatched = set(re.findall(r'node\.name == "(\w+)"', source))
        assert dispatched == set(builtins.BUILTIN_COMMANDS), (
            dispatched.symmetric_difference(builtins.BUILTIN_COMMANDS)
        )

    @pytest.mark.parametrize("name", sorted(ANTI_PATTERNS))
    def test_what_validate_rejects_evaluate_rejects(self, name):
        from mcad.evaluator import EvaluationError, evaluate_source
        from mcad.lexer import LexError

        # LexError is in the tuple because evaluate_source wraps parse and
        # translate errors but lets a lex error through raw; the point here is
        # only that no anti-pattern reaches geometry.
        with pytest.raises((EvaluationError, LexError)):
            evaluate_source(ANTI_PATTERNS[name])

"""The skill text is a contract with the agent that writes .mcad, so it has to
be true.

§1 of the cad skill lists the DSL's vocabulary, and an agent trusts it: a
function advertised there but unknown to the worker costs a whole round trip
before the agent finds out, and the failure looks like the model's mistake
rather than the manual's. ``polygon(points)`` sat in the 2D primitives list
while ``resolve_names`` answered "Unknown function: polygon" for it everywhere,
inside ``sketch:`` included.

ORACLE for these tests: add a plausible invented primitive to §1's indented
example lines — ``hexagon(r)``, say — and the first test goes red naming it.
Delete a real builtin from the table and the second goes red naming that.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from mcad.builtins import BUILTIN_COMMANDS, BUILTIN_FUNCTIONS

# Read with an explicit encoding: the skill text is full of typographic
# characters and another test in this suite leaves the default locale ASCII.
MANIFEST = Path(__file__).resolve().parents[2] / "manifest.json"

# Call-shaped names that are language forms rather than table builtins: the
# translator handles each as its own AST node, so they will never appear in
# BUILTIN_FUNCTIONS however correct they are.
LANGUAGE_FORMS = {"extrude", "point"}


def _section_one() -> str:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    prompt = manifest["skills"][0]["system_prompt"]
    start = prompt.index("DSL vocabulary")
    return prompt[start : prompt.index("Language constructs")]


def _advertised_calls() -> set[str]:
    """Names written as ``name(`` on §1's INDENTED example lines.

    Indented only, because §1's prose talks about names precisely to say the
    DSL does not have them.
    """
    lines = [
        re.sub(r"#.*", "", line)
        for line in _section_one().split("\n")
        if line.startswith("  ")
    ]
    return set(re.findall(r"\b([a-z_0-9]+)\(", "\n".join(lines)))


def test_every_function_the_skill_advertises_exists() -> None:
    advertised = _advertised_calls()
    assert advertised, "§1 of the skill lists no functions at all"
    unknown = sorted(advertised - set(BUILTIN_FUNCTIONS) - LANGUAGE_FORMS)
    assert not unknown, (
        "the skill advertises functions the worker will refuse: "
        + ", ".join(unknown)
    )


def test_polygon_is_not_advertised_because_it_does_not_exist() -> None:
    assert "polygon" not in BUILTIN_FUNCTIONS
    assert "polygon" not in _advertised_calls()


def test_the_commands_the_skill_names_are_the_commands_there_are() -> None:
    section = _section_one()
    named = {
        name
        for name in BUILTIN_COMMANDS
        if re.search(rf"(?m)^  {name} ", section)
    }
    assert named == set(BUILTIN_COMMANDS), (
        "§1 names %s but the worker accepts %s"
        % (sorted(named), sorted(BUILTIN_COMMANDS))
    )

"""The DSL's builtin vocabulary, and a name-resolution pass over a parsed AST.

The translator raises "Unknown function: difference" only once it is already
building geometry, which is expensive and needs OCCT. Validate wants the same
verdict for free: this module holds the one table both consult and walks a
parsed program checking every call against it.

Keeping the table here rather than deriving it from the translator is a
deliberate duplication of *names* only — the translator still owns every
argument's meaning. The pair is held honest by a test that walks the
translator's dispatch chain and compares it against ``BUILTIN_FUNCTIONS``.
"""

from __future__ import annotations

from typing import Any

from .ast_nodes import (
    Assignment,
    AtClause,
    BinOp,
    Command,
    Export,
    Extrude,
    FuncCall,
    If,
    Index,
    Loft,
    LoftSection,
    MethodCall,
    ModuleDef,
    Program,
    Return,
    SketchBlock,
    Tuple as TupleNode,
    UnaryOp,
    While,
    ForLoop,
)

# name -> keyword arguments the translator accepts. A name mapped to None takes
# no keywords at all.
BUILTIN_FUNCTIONS: dict[str, frozenset[str]] = {
    "rect": frozenset(),
    "circle": frozenset(),
    "oval": frozenset(),
    "cube": frozenset({"center", "size"}),
    "sphere": frozenset({"r"}),
    "cylinder": frozenset({"center", "h", "r", "r1", "r2"}),
    "polyhedron": frozenset({"points", "faces"}),
    "mesh": frozenset({"units", "up"}),
    "translate": frozenset(),
    "rotate": frozenset(),
    "scale": frozenset(),
    "mirror": frozenset(),
}

# Statement-level commands (``fillet beam, 2, r=4``) and their keywords.
BUILTIN_COMMANDS: dict[str, frozenset[str]] = {
    "fillet": frozenset({"r"}),
    "chamfer": frozenset({"d"}),
    "shell": frozenset({"t", "thickness", "open"}),
}

# What an OpenSCAD habit should be told to write instead. The DSL is not
# OpenSCAD and the mistake is common enough that the bare "unknown" is a poor
# answer.
_SUGGESTIONS: dict[str, str] = {
    "difference": "use the '-' operator: part = a - b",
    "union": "use the '+' operator: part = a + b",
    "intersection": "intersection is not in the DSL; build the overlap directly",
    "linear_extrude": "use 'part = extrude profile, height'",
    "rotate_extrude": "rotate_extrude is not in the DSL",
    "hull": "hull is not in the DSL; use loft: for a swept body",
    "minkowski": "minkowski is not in the DSL",
    "square": "use rect(width, height)",
    "cone": "use cylinder(h=..., r1=..., r2=...)",
}

# Diameter keywords are the single most common wrong keyword: the DSL is
# radius-only.
_DIAMETER_KEYWORDS: frozenset[str] = frozenset({"d", "d1", "d2", "diameter"})


def resolve_names(program: Program) -> list[dict[str, Any]]:
    """Return one finding per unresolvable call in *program*.

    A finding is {line, col, message}, in source order. Only names and keyword
    argument spellings are decided here — nothing is evaluated, no geometry is
    built, and OCCT is never imported.
    """
    findings: list[dict[str, Any]] = []
    modules: set[str] = {
        stmt.name for stmt in program.statements if isinstance(stmt, ModuleDef)
    }
    for stmt in program.statements:
        _walk(stmt, modules, findings)
    findings.sort(key=lambda f: (f["line"], f["col"]))
    return findings


def _finding(node: Any, message: str) -> dict[str, Any]:
    return {
        "line": int(getattr(node, "line", 0)),
        "col": int(getattr(node, "col", 0)),
        "message": message,
    }


def _check_call(node: FuncCall, modules: set[str], findings: list) -> None:
    name = node.name
    if name in modules:
        return  # a user module's own signature is the translator's business
    if name not in BUILTIN_FUNCTIONS:
        hint = _SUGGESTIONS.get(name)
        message = f"Unknown function: {name}"
        if hint:
            message += f" — {hint}"
        findings.append(_finding(node, message))
        return
    allowed = BUILTIN_FUNCTIONS[name]
    for kw in sorted(node.kwargs):
        if kw in allowed:
            continue
        message = f"{name}() has no keyword argument '{kw}'"
        if kw in _DIAMETER_KEYWORDS and "r" in allowed:
            message += " — the DSL is radius-only; halve it and pass r="
        elif allowed:
            message += f" (accepts: {', '.join(sorted(allowed))})"
        else:
            message += " (it takes no keyword arguments)"
        findings.append(_finding(node, message))


def _check_command(node: Command, findings: list) -> None:
    if node.name not in BUILTIN_COMMANDS:
        findings.append(_finding(node, f"Unknown command: {node.name}"))
        return
    allowed = BUILTIN_COMMANDS[node.name]
    for kw in sorted(node.kwargs):
        if kw not in allowed:
            findings.append(
                _finding(
                    node,
                    f"{node.name} has no keyword argument '{kw}'"
                    f" (accepts: {', '.join(sorted(allowed))})",
                )
            )


def _walk(node: Any, modules: set[str], findings: list) -> None:
    """Depth-first walk of every expression and statement that can hold a call."""
    if node is None or isinstance(node, (str, int, float, bool)):
        return
    if isinstance(node, (list, tuple)):
        for item in node:
            _walk(item, modules, findings)
        return
    if isinstance(node, dict):
        for item in node.values():
            _walk(item, modules, findings)
        return

    if isinstance(node, FuncCall):
        _check_call(node, modules, findings)
        _walk(node.args, modules, findings)
        _walk(node.kwargs, modules, findings)
        return
    if isinstance(node, Command):
        _check_command(node, findings)
        _walk(node.args, modules, findings)
        _walk(node.kwargs, modules, findings)
        return
    if isinstance(node, Assignment):
        _walk(node.value, modules, findings)
        return
    if isinstance(node, BinOp):
        _walk(node.left, modules, findings)
        _walk(node.right, modules, findings)
        return
    if isinstance(node, UnaryOp):
        _walk(node.operand, modules, findings)
        return
    if isinstance(node, Index):
        _walk(node.target, modules, findings)
        _walk(node.index, modules, findings)
        return
    if isinstance(node, MethodCall):
        _walk(node.target, modules, findings)
        _walk(node.args, modules, findings)
        _walk(node.kwargs, modules, findings)
        return
    if isinstance(node, AtClause):
        _walk(node.target, modules, findings)
        _walk(node.position, modules, findings)
        return
    if isinstance(node, TupleNode):
        _walk(node.elements, modules, findings)
        return
    if isinstance(node, SketchBlock):
        _walk(node.statements, modules, findings)
        return
    if isinstance(node, ForLoop):
        _walk(node.iterable, modules, findings)
        _walk(node.body, modules, findings)
        return
    if isinstance(node, If):
        _walk(node.condition, modules, findings)
        _walk(node.then_body, modules, findings)
        _walk(node.else_body, modules, findings)
        return
    if isinstance(node, While):
        _walk(node.condition, modules, findings)
        _walk(node.body, modules, findings)
        return
    if isinstance(node, ModuleDef):
        _walk(node.body, modules, findings)
        return
    if isinstance(node, Return):
        _walk(node.value, modules, findings)
        return
    if isinstance(node, Extrude):
        _walk(node.profile, modules, findings)
        _walk(node.length, modules, findings)
        return
    if isinstance(node, Loft):
        _walk(node.sections, modules, findings)
        return
    if isinstance(node, LoftSection):
        _walk(node.position, modules, findings)
        _walk(node.profile, modules, findings)
        return
    if isinstance(node, Export):
        return
    # Leaf literals (Number, String, Bool, Identifier) hold no calls.

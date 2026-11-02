"""Syntactic structure advice from parsed MCAD source; no geometry or expansion."""
from __future__ import annotations

from collections import defaultdict
from dataclasses import fields, is_dataclass
from typing import TypedDict

from mcad import ast_nodes as ast
from mcad.lexer import LexError
from mcad.parser import ParseError, parse


class Finding(TypedDict):
    rule: str
    line: int
    message: str
    fix: str


StructureReport = TypedDict("StructureReport", {"pass": bool, "findings": list[Finding]})


class WorkerError(TypedDict):
    kind: str
    message: str


class StructureReply(TypedDict, total=False):
    id: object
    ok: bool
    result: StructureReport
    error: WorkerError


def _children(node: object) -> list[object]:
    """AST fields are heterogeneous; line/column fields are metadata."""
    if isinstance(node, (list, tuple)):
        return list(node)
    if isinstance(node, dict):
        return list(node.values())
    if is_dataclass(node):
        return [getattr(node, field.name) for field in fields(node) if field.name not in ("line", "col")]
    return []


def _key(node: object) -> object:
    if isinstance(node, ast.FuncCall) and node.name in ("translate", "rotate") and node.args:
        return _key(node.args[-1])
    if isinstance(node, ast.AtClause):
        return _key(node.target)
    if is_dataclass(node):
        return (type(node).__name__, *(_key(child) for child in _children(node)))
    if isinstance(node, (list, tuple)):
        return tuple(_key(child) for child in node)
    if isinstance(node, dict):
        return tuple((key, _key(value)) for key, value in sorted(node.items()))
    return node


def _fit_intent(node: object, bindings: dict[str, object], seen: frozenset[str] = frozenset()) -> bool | None:
    if isinstance(node, ast.Identifier):
        if node.name.startswith("g_"):
            return True
        if node.name not in bindings or node.name in seen:
            return None
        return _fit_intent(bindings[node.name], bindings, seen | {node.name})
    if isinstance(node, ast.FuncCall) and node.name in ("clear_r", "tap_r", "press_r"):
        return True
    decisions = [_fit_intent(child, bindings, seen) for child in _children(node)]
    if any(decision is True for decision in decisions):
        return True
    if any(decision is None for decision in decisions) or isinstance(node, ast.FuncCall):
        return None
    return False


def _allowance(node: object, bindings: dict[str, object], seen: frozenset[str] = frozenset()) -> bool:
    if isinstance(node, ast.Identifier) and node.name in bindings and node.name not in seen:
        return _allowance(bindings[node.name], bindings, seen | {node.name})
    if isinstance(node, ast.BinOp) and node.op == "+":
        division, value = node.left, node.right
        if (isinstance(division, ast.BinOp) and division.op == "/"
                and isinstance(division.right, ast.Number) and division.right.value == 2
                and isinstance(value, ast.Number)):
            return True
    return any(_allowance(child, bindings, seen) for child in _children(node))


def check_program(program: ast.Program) -> StructureReport:
    """Count source syntax once; modules, loops and branches are never expanded."""
    findings: list[Finding] = []
    emitted: set[tuple[str, int, str]] = set()
    literals: dict[float, list[int]] = defaultdict(list)
    shapes: dict[object, list[int]] = defaultdict(list)

    def emit(rule: str, line: int, message: str, fix: str) -> None:
        identity = (rule, line, message)
        if identity not in emitted:
            emitted.add(identity)
            findings.append({"rule": rule, "line": line, "message": message, "fix": fix})

    def syntax(node: object, line: int = 1, structured: bool = False) -> None:
        line = getattr(node, "line", 0) or line
        structured = structured or isinstance(node, (ast.ModuleDef, ast.ForLoop, ast.While))
        if isinstance(node, ast.Number) and node.value not in (0, 1, 2, 0.5, 90, 180, 360):
            literals[node.value].append(line)
        if (not structured and isinstance(node, ast.FuncCall)
                and node.name in ("cube", "cylinder", "sphere", "polyhedron", "rect", "circle", "oval")):
            shapes[_key(node)].append(line)
        for child in _children(node):
            syntax(child, line, structured)

    def holes(node: object, bindings: dict[str, object], line: int, negative: bool = False,
              seen: frozenset[str] = frozenset()) -> None:
        line = getattr(node, "line", 0) or line
        if isinstance(node, ast.Identifier):
            if node.name in bindings and node.name not in seen:
                holes(bindings[node.name], bindings, line, negative, seen | {node.name})
            elif negative and node.name in seen:
                emit("analysis-limit", line, "A cyclic binding prevents deciding the subtracted shape.",
                     "Give the hole primitive and its radius explicit acyclic names with a g_* process global or fit helper.")
            return
        if isinstance(node, ast.BinOp) and node.op == "-":
            holes(node.left, bindings, line, negative, seen)
            holes(node.right, bindings, line, not negative, seen)
            return
        if isinstance(node, ast.FuncCall) and node.name == "cylinder":
            radii = [node.kwargs[key] for key in ("r", "r1", "r2") if key in node.kwargs]
            if len(node.args) > 1:
                radii.append(node.args[1])
            if any(_allowance(radius, bindings) for radius in radii):
                emit("tolerance-literal", line, "Radius adds a literal allowance to a diameter / 2.",
                     "Replace the added allowance with g_xyTolerance (a radial process allowance).")
            if negative:
                decisions = [_fit_intent(radius, bindings) for radius in radii]
                if any(decision is False for decision in decisions):
                    emit("hole-without-fit", line, "Subtracted cylinder has no explicit process fit intent.",
                         "Reference a g_* radial process global or clear_r/tap_r/press_r in the radius expression.")
                if any(decision is None for decision in decisions):
                    emit("analysis-limit", line, "An unresolved radius prevents deciding the hole's fit intent.",
                         "State fit intent in the radius expression with a g_* process global or clear_r/tap_r/press_r.")
        for child in _children(node):
            holes(child, bindings, line, negative, seen)

    def statements(nodes: list[object], inherited: dict[str, object]) -> None:
        bindings = inherited.copy()
        for node in nodes:
            line = getattr(node, "line", 0) or 1
            if isinstance(node, ast.ModuleDef):
                local = {key: value for key, value in bindings.items() if key not in {p.name for p in node.params}}
                statements(node.body, local)
                continue
            if isinstance(node, (ast.ForLoop, ast.While)):
                local = bindings.copy()
                if isinstance(node, ast.ForLoop):
                    local.pop(node.variable, None)
                statements(node.body, local)
                continue
            if isinstance(node, ast.If):
                # Each syntactic branch has its own bindings. Neither runs.
                statements(node.then_body, bindings)
                statements(node.else_body, bindings)
                continue
            value = node.value if isinstance(node, (ast.Assignment, ast.Return)) else node
            holes(value, bindings, line)
            if isinstance(node, ast.Assignment):
                bindings[node.name] = value

    syntax(program)
    statements(program.statements, {})
    for lines in shapes.values():
        if len(lines) >= 3:
            emit("repeated-shape", lines[0], f"The same primitive occurs {len(lines)} times outside a module or loop.",
                 "Define the composite once in a module and place copies with a loop or pattern.")
    for value, lines in literals.items():
        if len(lines) >= 3:
            emit("repeated-literal", lines[0], f"Numeric literal {value:g} occurs {len(lines)} times.",
                 "Introduce a named parameter for this value and reference it at each use.")
    findings.sort(key=lambda finding: (finding["line"], finding["rule"], finding["message"]))
    return {"pass": not findings, "findings": findings}


def check_structure(params: object) -> StructureReply:
    """Worker boundary: syntax failures are findings; malformed requests are errors."""
    source = params.get("source") if isinstance(params, dict) else None
    if not isinstance(source, str):
        return {"ok": False, "error": {"kind": "parse", "message": "check_structure requires source: str"}}
    try:
        report = check_program(parse(source))
    except (LexError, ParseError) as error:
        token = getattr(error, "token", None)
        line = getattr(error, "line", 0) or getattr(token, "line", 0) or 1
        report = {"pass": False, "findings": [{"rule": "syntax", "line": line,
                  "message": str(error), "fix": "Correct the reported DSL syntax before checking structure."}]}
    return {"ok": True, "result": report}

"""Source structure advice from the parsed MCAD AST, without geometry or I/O."""
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


# The wire name is 'pass'; Python reserves that word in class syntax.
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
    """AST fields are heterogeneous by design; source locations are metadata."""
    if isinstance(node, (list, tuple)):
        return list(node)
    if isinstance(node, dict):
        return list(node.values())
    if is_dataclass(node):
        return [getattr(node, field.name) for field in fields(node) if field.name not in ("line", "col")]
    return []


def _key(node: object) -> object:
    if is_dataclass(node):
        return (type(node).__name__, *(_key(child) for child in _children(node)))
    if isinstance(node, (list, tuple)):
        return tuple(_key(child) for child in node)
    if isinstance(node, dict):
        return tuple((key, _key(value)) for key, value in sorted(node.items()))
    return node


def _fit_intent(node: object, bindings: dict[str, object], seen: frozenset[str] = frozenset()) -> bool:
    if isinstance(node, ast.Identifier):
        return node.name.startswith("g_") or (
            node.name in bindings and node.name not in seen
            and _fit_intent(bindings[node.name], bindings, seen | {node.name})
        )
    if isinstance(node, ast.FuncCall) and node.name in ("clear_r", "tap_r", "press_r"):
        return True
    return any(_fit_intent(child, bindings, seen) for child in _children(node))


def _placements(node: object, bindings: dict[str, object], groups: set[str], seen: frozenset[str] = frozenset()) -> int:
    if isinstance(node, ast.Index):
        return _placements(node.target, bindings, groups, seen)
    if isinstance(node, ast.Tuple):
        return max((_placements(child, bindings, groups, seen) for child in node.elements), default=0)
    if isinstance(node, ast.Identifier):
        if node.name in groups:
            return 2
        if node.name in bindings and node.name not in seen:
            return _placements(bindings[node.name], bindings, groups, seen | {node.name})
    if isinstance(node, ast.AtClause):
        return 1
    if isinstance(node, ast.FuncCall):
        if node.name == "translate":
            return 1
        if node.name in groups:
            return 2
    if isinstance(node, ast.MethodCall):
        return 1 if node.method == "translate" else _placements(node.target, bindings, groups, seen)
    if isinstance(node, ast.BinOp):
        if node.op == "+":
            return _placements(node.left, bindings, groups, seen) + _placements(node.right, bindings, groups, seen)
        if node.op == "-":
            return _placements(node.left, bindings, groups, seen)
    return 0


def check_program(program: ast.Program) -> StructureReport:
    """Return deterministic findings; this is a structure critic, not a fit check."""
    findings: list[Finding] = []
    emitted: set[tuple[str, int, str]] = set()
    literals: dict[float, list[int]] = defaultdict(list)
    shapes: dict[tuple, list[int]] = defaultdict(list)

    def emit(rule: str, line: int, message: str, fix: str) -> None:
        identity = (rule, line, message)
        if identity not in emitted:
            emitted.add(identity)
            findings.append({"rule": rule, "line": line, "message": message, "fix": fix})

    def syntax(node: object, line: int = 1, structured: bool = False, pose: tuple = ()) -> None:
        line = getattr(node, "line", 0) or line
        structured = structured or isinstance(node, (ast.ModuleDef, ast.ForLoop, ast.While))
        if isinstance(node, ast.Number) and node.value not in (0, 1, 2, 0.5, 90, 180, 360):
            literals[node.value].append(line)
        if isinstance(node, ast.FuncCall):
            if node.name in ("rotate", "scale", "mirror"):
                # Only translation may differ within a repeated-shape group.
                pose = (*pose, (node.name, _key(node.args[:-1])))
            if not structured and node.name in ("cube", "cylinder", "sphere", "polyhedron", "rect", "circle", "oval"):
                shapes[(_key(node), pose)].append(line)
        for child in _children(node):
            syntax(child, line, structured, pose)

    def allowance(node: object, bindings: dict[str, object], seen: frozenset[str] = frozenset()) -> bool:
        if isinstance(node, ast.Identifier) and node.name in bindings and node.name not in seen:
            return allowance(bindings[node.name], bindings, seen | {node.name})
        if isinstance(node, ast.BinOp) and node.op == "+":
            division, value = node.left, node.right
            if (isinstance(division, ast.BinOp) and division.op == "/"
                    and isinstance(division.right, ast.Number) and division.right.value == 2
                    and isinstance(value, ast.Number)):
                return True
        return any(allowance(child, bindings, seen) for child in _children(node))

    def holes(node: object, bindings: dict[str, object], line: int, negative: bool = False,
              seen: frozenset[str] = frozenset()) -> None:
        line = getattr(node, "line", 0) or line
        if isinstance(node, ast.Identifier):
            if node.name in bindings and node.name not in seen:
                holes(bindings[node.name], bindings, line, negative, seen | {node.name})
            return
        if isinstance(node, ast.BinOp) and node.op == "-":
            holes(node.left, bindings, line, negative, seen)
            holes(node.right, bindings, line, not negative, seen)
            return
        if isinstance(node, ast.FuncCall) and node.name == "cylinder":
            radii = [node.kwargs[key] for key in ("r", "r1", "r2") if key in node.kwargs]
            if len(node.args) > 1:
                radii.append(node.args[1])
            if any(allowance(radius, bindings) for radius in radii):
                emit("tolerance-literal", line, "Radius adds a literal allowance to a diameter / 2.",
                     "Replace the added allowance with g_xyTolerance (a radial process allowance).")
            if negative and radii and any(not _fit_intent(radius, bindings) for radius in radii):
                emit("hole-without-fit", line, "Subtracted cylinder has no explicit process fit intent.",
                     "Reference a g_* radial process global or clear_r/tap_r/press_r in the radius expression.")
        for child in _children(node):
            holes(child, bindings, line, negative, seen)

    def statements(nodes: list[object], inherited: dict[str, object], inherited_groups: set[str],
                   loop: bool = False) -> set[str]:
        bindings, groups = inherited.copy(), inherited_groups.copy()
        for node in nodes:
            line = getattr(node, "line", 0) or 1
            if isinstance(node, ast.ModuleDef):
                local = {key: value for key, value in bindings.items() if key not in {p.name for p in node.params}}
                module_groups = statements(node.body, local, groups - {p.name for p in node.params})
                if any(isinstance(statement, ast.Return) and _placements(statement.value, local, module_groups) >= 2 for statement in node.body):
                    groups.add(node.name)
                continue
            if isinstance(node, (ast.ForLoop, ast.While)):
                groups.update(statements(node.body, bindings, groups, loop=True))
                continue
            if isinstance(node, ast.If):
                groups.update(statements(node.then_body, bindings, groups, loop))
                groups.update(statements(node.else_body, bindings, groups, loop))
                continue
            if (isinstance(node, ast.Command) and node.name in ("fillet", "chamfer") and node.args
                    and _placements(node.args[0], bindings, groups) >= 2):
                emit("finish-on-assembly", line, "Edge finish is applied after assembling several placed copies.",
                     "Apply the fillet/chamfer to the composite module before placing its copies.")
            value = node.value if isinstance(node, (ast.Assignment, ast.Return)) else node
            holes(value, bindings, line)
            if isinstance(node, ast.Assignment):
                count = _placements(value, bindings, groups)
                if count >= 2 or (loop and isinstance(value, ast.BinOp) and value.op == "+" and count >= 1):
                    groups.add(node.name)
                else:
                    groups.discard(node.name)
                bindings[node.name] = value
        return groups

    syntax(program)
    statements(program.statements, {}, set())
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

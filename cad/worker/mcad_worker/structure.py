"""Source structure advice from the parsed MCAD AST, without geometry or I/O."""
from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass, field, fields, is_dataclass
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


@dataclass
class _Shape:
    """Symbolic component identity and the placed copies it contains."""
    key: tuple
    copies: Counter[tuple] = field(default_factory=Counter)
    items: tuple[_Shape, ...] | None = None


def _qualified(shape: _Shape, call: tuple) -> _Shape:
    """Module arguments distinguish components even when their bodies match."""
    return _Shape((call, shape.key), Counter({(call, key): count for key, count in shape.copies.items()}),
                  tuple(_qualified(item, call) for item in shape.items) if shape.items is not None else None)


def _shape(node: object, symbols: dict[str, _Shape], modules: dict[str, _Shape]) -> _Shape:
    if isinstance(node, ast.Identifier):
        return symbols.get(node.name, _Shape(("name", node.name)))
    if isinstance(node, ast.Tuple):
        items = tuple(_shape(child, symbols, modules) for child in node.elements)
        return _Shape(("tuple", *(item.key for item in items)), items=items)
    if isinstance(node, ast.Index):
        target = _shape(node.target, symbols, modules)
        items = target.items or ()
        if (isinstance(node.index, ast.Number) and -len(items) <= node.index.value < len(items)
                and node.index.value % 1 == 0):
            return items[int(node.index.value)]
        return _Shape(("index", target.key, _key(node.index)))
    if isinstance(node, ast.BinOp):
        left, right = _shape(node.left, symbols, modules), _shape(node.right, symbols, modules)
        copies = left.copies + right.copies if node.op == "+" else left.copies.copy() if node.op == "-" else Counter()
        return _Shape((node.op, left.key, right.key), copies)
    if isinstance(node, ast.AtClause):
        target = _shape(node.target, symbols, modules)
        return _Shape(("at", target.key, _key(node.position)), target.copies.copy() or Counter({target.key: 1}))
    if isinstance(node, ast.FuncCall):
        args = [_shape(child, symbols, modules) for child in node.args]
        keywords = tuple((key, _shape(value, symbols, modules).key) for key, value in sorted(node.kwargs.items()))
        key = (node.name, tuple(arg.key for arg in args), keywords)
        if node.name in ("translate", "rotate", "scale", "mirror") and args:
            target = args[-1]
            copies = target.copies.copy()
            if node.name == "translate":
                copies = copies or Counter({target.key: 1})
            else:
                copies = Counter({(node.name, tuple(arg.key for arg in args[:-1]), item): count for item, count in copies.items()})
            return _Shape(key, copies)
        if node.name in modules:
            return _qualified(modules[node.name], key)
        return _Shape(key)
    if isinstance(node, ast.MethodCall):
        target = _shape(node.target, symbols, modules)
        args = tuple(_shape(child, symbols, modules).key for child in node.args)
        key = (node.method, target.key, args)
        copies = target.copies.copy()
        if node.method == "translate":
            copies = copies or Counter({target.key: 1})
        else:
            copies = Counter({(node.method, args, item): count for item, count in copies.items()})
        return _Shape(key, copies)
    return _Shape((_key(node),))


def check_program(program: ast.Program) -> StructureReport:
    """Return deterministic findings; this is a structure critic, not a fit check."""
    findings: list[Finding] = []
    emitted: set[tuple[str, int, str]] = set()
    literals: dict[float, list[int]] = defaultdict(list)
    shapes: dict[tuple, list[int]] = defaultdict(list)
    remaining = 10000  # Bound symbolic expansion; never return a false pass at exhaustion.

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

    def statements(nodes: list[object], bindings: dict[str, object], symbols: dict[str, _Shape],
                   modules: dict[str, _Shape]) -> _Shape | None:
        nonlocal remaining
        returned = None
        for node in nodes:
            line = getattr(node, "line", 0) or 1
            remaining -= 1
            if remaining < 0:
                emit("analysis-limit", line, "Symbolic source analysis exceeded its bounded expansion.",
                     "Reduce the literal placement list or split the part into smaller composite modules before checking again.")
                return returned
            if isinstance(node, ast.ModuleDef):
                parameters = {p.name for p in node.params}
                local = {key: value for key, value in bindings.items() if key not in parameters}
                local_symbols = {key: value for key, value in symbols.items() if key not in parameters}
                result = statements(node.body, local, local_symbols, modules.copy())
                if result is not None:
                    modules[node.name] = result
                continue
            if isinstance(node, ast.ForLoop):
                iterable = _shape(node.iterable, symbols, modules)
                if iterable.items is None:
                    emit("analysis-limit", line, "The placement loop's iterable is not statically known.",
                         "Use a literal list of positions (or a named literal list) so copy structure can be checked.")
                    continue
                for item in iterable.items or ():
                    symbols[node.variable] = item
                    statements(node.body, bindings, symbols, modules)
                    if remaining < 0:
                        break
                continue
            if isinstance(node, ast.While):
                emit("analysis-limit", line, "While-loop copy counts are not statically known.",
                     "Use a bounded for loop over explicit positions for repeatable placement structure.")
                continue
            if isinstance(node, ast.If):
                condition = node.condition
                visited: set[str] = set()
                while isinstance(condition, ast.Identifier) and condition.name in bindings and condition.name not in visited:
                    visited.add(condition.name)
                    condition = bindings[condition.name]
                if isinstance(condition, ast.Bool):
                    statements(node.then_body if condition.value else node.else_body, bindings, symbols, modules)
                else:
                    statements(node.then_body, bindings, symbols, modules)
                    statements(node.else_body, bindings, symbols, modules)
                continue
            if (isinstance(node, ast.Command) and node.name in ("fillet", "chamfer") and node.args
                    and max(_shape(node.args[0], symbols, modules).copies.values(), default=0) >= 2):
                emit("finish-on-assembly", line, "Edge finish is applied after assembling several placed copies.",
                     "Apply the fillet/chamfer to the composite module before placing its copies.")
            value = node.value if isinstance(node, (ast.Assignment, ast.Return)) else node
            holes(value, bindings, line)
            if isinstance(node, ast.Assignment):
                symbols[node.name] = _shape(value, symbols, modules)
                bindings[node.name] = value
            if isinstance(node, ast.Return):
                returned = _shape(node.value, symbols, modules)
        return returned

    syntax(program)
    statements(program.statements, {}, {}, {})
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

"""Attributing a geometry-kernel failure to the DSL binding that was building.

The kernel (OCCT, reached through build123d) raises plain Python exceptions —
``ValueError: Failed creating a fillet``, ``AttributeError: 'NoneType' object
has no attribute 'NbNodes'`` — that say nothing about the source. Running the
statements one at a time here, instead of inside ``Translator.translate``,
costs nothing extra (it is the same single pass over the same AST) and turns
those into a :class:`BuildFailure` that names the binding, the line and the
stage. Nothing in this module re-translates or re-evaluates anything.
"""

from __future__ import annotations

import time
import traceback
from typing import Any

from .ast_nodes import (
    Assignment,
    Command,
    Export,
    Extrude,
    ForLoop,
    Identifier,
    If,
    Loft,
    ModuleDef,
    Program,
    Return,
    SketchBlock,
    While,
)
from .parser import ParseError
from .translator import Translator, TranslatorError

#: Statement forms ``Translator._eval_statement`` handles itself. Anything
#: else is an expression statement, and as the final statement of a program it
#: names the result. Mirrors the dispatch in ``_eval_statement``.
_STATEMENT_NODES = (
    Assignment,
    SketchBlock,
    ForLoop,
    If,
    While,
    Command,
    Export,
    ModuleDef,
    Return,
    Extrude,
    Loft,
)

#: Binding name given to a trailing expression that is not a bare name, so the
#: reply, the exports and the checks always have something to call the result.
_RESULT_BINDING = "result"

#: Bounds on the failure-path face probe. It only ever runs after the shape
#: has already failed to tessellate, but a shell of thousands of faces must
#: not turn a failed evaluation into a hung one.
_MAX_FACES_PROBED = 400
_MAX_PROBE_SECONDS = 10.0


class BuildFailure(Exception):
    """A kernel error raised while building or tessellating one binding.

    ``binding`` is the DSL name being produced, ``stage`` is ``"build"`` or
    ``"tessellate"``, and ``cause_traceback`` is the full formatted traceback
    of the underlying exception — the reply carries it verbatim, because the
    innermost frame is the only part that says which kernel call failed.
    """

    def __init__(
        self,
        *,
        binding: str,
        stage: str,
        cause: BaseException,
        line: int = 0,
        faces: list[dict[str, Any]] | None = None,
    ) -> None:
        self.binding = binding
        self.stage = stage
        self.line = line
        self.cause = cause
        self.faces = faces or []
        self.cause_traceback = "".join(
            traceback.format_exception(type(cause), cause, cause.__traceback__)
        )
        where = f" (line {line})" if line else ""
        verb = "Tessellating" if stage == "tessellate" else "Building"
        detail = f"{type(cause).__name__}: {cause}"
        super().__init__(
            f"{verb} '{binding}'{where} failed in the geometry kernel — {detail}"
        )

    def details(self) -> dict[str, Any]:
        """The structured half of the error payload."""
        detail: dict[str, Any] = {
            "binding": self.binding,
            "stage": self.stage,
            "exception": type(self.cause).__name__,
        }
        if self.line:
            detail["line"] = self.line
        if self.faces:
            detail["untriangulated_faces"] = self.faces
        return detail


def describe_statement(stmt: Any) -> tuple[str, int]:
    """Return (binding name, line) for a top-level statement.

    The binding is the name the statement produces: the assignment target, or
    for a mutating command (``fillet part, [1], r=4``) the shape it names as
    its first argument.
    """
    if isinstance(stmt, Assignment):
        return stmt.name, getattr(stmt.value, "line", 0) or 0
    if isinstance(stmt, Command):
        first = stmt.args[0] if stmt.args else None
        target = first.name if isinstance(first, Identifier) else stmt.name
        return target, stmt.line
    if isinstance(stmt, Export):
        return stmt.name, 0
    if isinstance(stmt, ForLoop):
        return "for loop", 0
    if isinstance(stmt, While):
        return "while loop", 0
    if isinstance(stmt, If):
        return "if block", 0
    if isinstance(stmt, ModuleDef):
        return stmt.name, 0
    return type(stmt).__name__.lower(), 0


def translate_program(translator: Translator, program: Program) -> None:
    """Translate *program* statement by statement, attributing kernel errors.

    ``Translator.translate`` runs the same loop; it is repeated here (via the
    per-statement entry point) only so the statement boundary is still in
    scope when an exception escapes. DSL-level errors — lex, parse, translate
    — pass through untouched so their own kinds survive.

    A program whose last statement is a bare expression (``hump_in``) selects
    that expression as the result; without one, the last-assigned part stands.
    """
    statements = program.statements
    for index, stmt in enumerate(statements):
        last = index == len(statements) - 1
        try:
            if last and not isinstance(stmt, _STATEMENT_NODES):
                _select_result(translator, stmt)
            else:
                translator._eval_statement(stmt)
        except (ParseError, TranslatorError, BuildFailure):
            raise
        except Exception as exc:
            binding, line = describe_statement(stmt)
            raise BuildFailure(
                binding=binding, stage="build", cause=exc, line=line
            ) from exc


def _select_result(translator: Translator, expr: Any) -> None:
    """Evaluate a trailing bare expression and make it the render target.

    Evaluated once, here, rather than for side effects and again for its
    value — a trailing ``a + b`` would otherwise build the boolean twice.
    """
    value = translator._eval_expr(expr)
    name = expr.name if isinstance(expr, Identifier) else _RESULT_BINDING
    if not translator.is_part(value):
        subject = f"'{expr.name}'" if isinstance(expr, Identifier) else "expression"
        raise TranslatorError(
            f"The program's final {subject} is a {type(value).__name__}, not a "
            "3D shape. A trailing bare expression selects what the program "
            "evaluates to, so it must name a solid; drop the line to keep the "
            "last assigned part."
        )
    translator.select_result(name, value)


def tessellate_shape(
    shape: Any,
    binding: str,
    *,
    tolerance: float,
    angular_tolerance: float,
) -> tuple[Any, Any]:
    """Tessellate *shape*, raising :class:`BuildFailure` naming *binding*."""
    try:
        return shape.tessellate(
            tolerance=float(tolerance), angular_tolerance=float(angular_tolerance)
        )
    except Exception as exc:
        raise BuildFailure(
            binding=binding,
            stage="tessellate",
            cause=exc,
            faces=untriangulated_faces(shape, tolerance),
        ) from exc


def untriangulated_faces(shape: Any, tolerance: float) -> list[dict[str, Any]]:
    """Locate the faces that defeat the tessellator, as {index, center}.

    Runs only after the whole-shape tessellation has already failed, and only
    on faces the shape already holds — no geometry is rebuilt. Bounded in both
    face count and wall clock so a diagnosis never outlasts the failure it is
    explaining; a partial list is still a place to look.
    """
    found: list[dict[str, Any]] = []
    deadline = time.monotonic() + _MAX_PROBE_SECONDS
    try:
        faces = list(shape.faces())
    except Exception:
        return found
    for index, face in enumerate(faces[:_MAX_FACES_PROBED]):
        if time.monotonic() > deadline:
            break
        try:
            face.tessellate(tolerance=float(tolerance))
        except Exception:
            found.append({"index": index, "center": _face_center(face)})
            if len(found) >= 3:
                break
    return found


def _face_center(face: Any) -> list[float]:
    """Best-effort [x, y, z] of a face's center; empty when OCCT will not say."""
    try:
        c = face.center()
        return [round(float(c.X), 3), round(float(c.Y), 3), round(float(c.Z), 3)]
    except Exception:
        return []

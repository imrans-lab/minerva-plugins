"""Attributing a geometry-kernel failure to the DSL binding that was building.

The kernel (OCCT, reached through build123d) raises plain Python exceptions —
``ValueError: Failed creating a fillet``, ``AttributeError: 'NoneType' object
has no attribute 'NbNodes'`` — that say nothing about the source. Running the
statements one at a time here, instead of inside ``Translator.translate``,
costs nothing extra (it is the same single pass over the same AST) and turns
those into a :class:`BuildFailure` that names the binding, the line and the
stage. Nothing in this module re-translates or re-evaluates anything.

The attribution is per exception, not per statement: a failure raised from
inside the kernel packages is reported as a kernel failure, while one raised
in the DSL's own frames (a division by zero in an expression, a bad keyword
argument) keeps the binding and the line but is reported as a Python failure.
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

#: Import roots whose code IS the geometry kernel. A failure raised from
#: inside one of these is a kernel failure; a ZeroDivisionError or a TypeError
#: raised in the DSL's own frames is a Python failure that happens to have
#: occurred while a binding was building, and calling it "occt" sends the
#: reader to look for a geometry problem that is not there.
_KERNEL_PACKAGES = ("OCP", "OCC", "build123d", "cadquery")


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
        self.kind = _failure_kind(cause)
        where = f" (line {line})" if line else ""
        verb = "Tessellating" if stage == "tessellate" else "Building"
        blame = ("failed in the geometry kernel" if self.kind == "occt"
                 else "raised a Python error")
        detail = f"{type(cause).__name__}: {cause}"
        super().__init__(f"{verb} '{binding}'{where} {blame} — {detail}")

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


def _failure_kind(cause: BaseException) -> str:
    """"occt" when the kernel raised, "python" otherwise.

    The kernel's own exception classes live in the kernel packages, but it
    also raises plain ``ValueError``/``AttributeError`` from inside them, so
    the deepest frame the traceback reached decides: that is the code that
    actually failed. With no traceback to read, only the class can speak.
    """
    if _in_kernel(type(cause).__module__):
        return "occt"
    frame = cause.__traceback__
    deepest = None
    while frame is not None:
        deepest = frame
        frame = frame.tb_next
    if deepest is not None:
        module = deepest.tb_frame.f_globals.get("__name__", "")
        if _in_kernel(module):
            return "occt"
    return "python"


def _in_kernel(module: str) -> bool:
    root = (module or "").split(".", 1)[0]
    return root in _KERNEL_PACKAGES


def describe_statement(stmt: Any) -> tuple[str, int]:
    """Return (binding name, line) for a top-level statement.

    The binding is the name the statement produces: the assignment target, or
    for a mutating command (``fillet part, [1], r=4``) the shape it names as
    its first argument.
    """
    if isinstance(stmt, Assignment):
        # The value node's own position when it has one (a call carries it),
        # and the assignment target's otherwise: `a = b * c` is an operator
        # expression, and no node under it knows what line it was written on.
        return stmt.name, getattr(stmt.value, "line", 0) or stmt.line
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


def source_frame(source: str, binding: str, line: int) -> str:
    """The DSL frame a translate-time error is shown with: the binding it was
    producing, the line number, and that line of the program as written.

    The kernel path has a Python traceback whose innermost frame says which
    call failed; a translate error never reaches Python code the reader owns,
    so the equivalent "where" is the source line itself.
    """
    if not binding and not line:
        return ""
    head = f"'{binding}' (line {line})" if line else f"'{binding}'"
    lines = source.splitlines()
    if 1 <= line <= len(lines):
        return f"{head}\n  {lines[line - 1].strip()}"
    return head


def translate_program(translator: Translator, program: Program) -> None:
    """Translate *program* statement by statement, attributing kernel errors.

    ``Translator.translate`` runs the same loop; it is repeated here (via the
    per-statement entry point) only so the statement boundary is still in
    scope when an exception escapes. DSL-level errors — lex, parse, translate
    — pass through untouched so their own kinds survive, except that a
    translate error is told WHERE it happened on the way out: it is raised
    from inside expression evaluation, which does not know which statement is
    running, and this loop is the only place that does.

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
        except TranslatorError as exc:
            binding, line = describe_statement(stmt)
            exc.locate(binding, line)
            raise
        except (ParseError, BuildFailure):
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

"""High-level MCAD source evaluation helpers for the Flask API."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .build_trace import translate_program
from .parser import ParseError, parse
from .translator import Translator, TranslatorError, export_shape

@dataclass
class EvaluationResult:
    mesh: dict[str, list]
    edges: list[dict[str, Any]]
    shape_name: str
    # Number of solid bodies in the rendered shape. 1 for an ordinary part;
    # >1 when the last binding is a compound of separated bodies (two halves
    # of an enclosure, say), which is otherwise invisible in the reply.
    body_count: int = 0
    # Foreign mesh files the source referenced, each with its composed pose.
    # The worker never opens them; the panel resolves and loads them.
    references: list[dict[str, Any]] = field(default_factory=list)
    annotations: list[dict[str, Any]] = field(default_factory=list)
    # The live B-Rep the mesh was tessellated from. NOT serializable and never
    # part of the reply: it is here so a caller that already paid to build the
    # part can export it without translating the DSL a second time.
    shape: Any = None
    document: Any = None
    model: dict = field(default_factory=dict)
    # Final solid bindings share the already-built geometry; never serialized.
    bindings: dict[str, Any] = field(default_factory=dict)


def body_count_of(shape: Any) -> int:
    """Number of separate solid bodies in *shape*.

    A shape that reports no solids (a bare sketch never reaches here) still
    counts as one body so the reply never claims an empty part.
    """
    try:
        count = len(shape.solids())
    except Exception:
        return 1
    return count if count > 0 else 1


class EvaluationError(Exception):
    """Raised when MCAD source cannot be evaluated into mesh output."""


class ExportError(Exception):
    """Raised when MCAD source cannot be exported."""


def evaluate_source(
    source: str, *, tolerance: float = 0.1, angular_tolerance: float = 0.1,
    document: Any = None, selection: str = "", configuration: str = "",
) -> EvaluationResult:
    """Compile once, then select and tessellate from the immutable document."""
    from .document import EvaluatedDocument
    try:
        if document is None:
            translator = Translator()
            translate_program(translator, parse(source))
            document = EvaluatedDocument.from_translator(translator)
        return document.render(selection, configuration, tolerance=tolerance,
                               angular_tolerance=angular_tolerance)
    except (ParseError, TranslatorError, ValueError) as exc:
        cause = exc if isinstance(exc, (ParseError, TranslatorError)) else TranslatorError(str(exc))
        raise EvaluationError(str(exc)) from cause


def export_source(source: str, *, format: str, path: str) -> str:
    """Parse source, build geometry, and export the final solid."""
    try:
        evaluated = evaluate_source(source)
    except EvaluationError as exc:
        raise ExportError(str(exc)) from exc
    if evaluated.shape is None:
        raise ExportError("No 3D part produced to export")
    return export_built(evaluated.shape, format=format, path=path, node_name=evaluated.shape_name)


def export_built(shape: Any, *, format: str, path: str,
                 node_name: str = "part") -> str:
    """Write an ALREADY-BUILT shape out; everything past the translation.

    Split from export_source so a caller holding the shape the panel just
    evaluated can write the file without translating the DSL again — on a
    lofted shell with a hundred booleans that second translation is minutes,
    and it is the whole cost of an export the panel has already paid for.
    """
    export_format = format.strip().lower()
    if export_format not in {"step", "stp", "stl", "3mf", "glb"}:
        raise ExportError(f"Unsupported export format: {format}")

    if path.strip() == "":
        raise ExportError("Export request must include non-empty string field 'path'")

    # Path resolution rules (must match the §8 skill prompt contract):
    #   - absolute (``/foo``, ``C:\foo``) → used as-is
    #   - ``~``-prefixed → expanded to the user's home directory
    #   - bare relative (``test.stl``, ``temp/test.stl``) → resolved against home
    # Without this, ``~/temp/test.stl`` is treated as a literal directory named
    # ``~`` under the worker's CWD — file lands somewhere the user can't find.
    requested_path = Path(path).expanduser()
    if not requested_path.is_absolute():
        requested_path = Path.home() / requested_path
    if requested_path.suffix == "":
        requested_path = requested_path.with_suffix("." + export_format)

    try:
        return export_shape(shape, str(requested_path), node_name=node_name or "part")
    except TranslatorError as exc:
        raise ExportError(str(exc)) from exc

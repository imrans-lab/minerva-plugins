"""High-level MCAD source evaluation helpers for the Flask API."""

from __future__ import annotations

import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .build_trace import tessellate_shape, translate_program
from .parser import ParseError, parse
from .translator import Translator, TranslatorError, export_shape

_DEBUG_EDGE_PICK = True
_DEBUG_LOG_PATH = "/tmp/cad-worker-edges.log"


def _dbg(msg: str) -> None:
    """Trace line for edge picking. Never allowed to fail the evaluation.

    Both sinks are written as explicit UTF-8 with a replacing error handler:
    *msg* echoes DSL source, which carries non-ASCII, and under a C/POSIX
    locale the default codec is ASCII -- an encode error here would surface as
    a bogus "python" error on an otherwise good evaluate.
    """
    if not _DEBUG_EDGE_PICK:
        return
    line = f"[edge-pick-worker] {msg}"
    try:
        stderr = sys.stderr.buffer  # bypass the locale-encoded text wrapper
    except AttributeError:
        stderr = None
    try:
        if stderr is not None:
            stderr.write((line + "\n").encode("utf-8", "replace"))
            stderr.flush()
        else:
            print(line, file=sys.stderr, flush=True)
    except (OSError, ValueError):
        pass
    try:
        with open(_DEBUG_LOG_PATH, "a", encoding="utf-8", errors="replace") as f:
            f.write(f"{time.strftime('%H:%M:%S')} pid={os.getpid()} {msg}\n")
    except (OSError, ValueError):
        pass


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
    # The live B-Rep the mesh was tessellated from. NOT serializable and never
    # part of the reply: it is here so a caller that already paid to build the
    # part can export it without translating the DSL a second time.
    shape: Any = None
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
    source: str,
    *,
    tolerance: float = 0.1,
    angular_tolerance: float = 0.1,
) -> EvaluationResult:
    """Parse source, build geometry, and return a tessellated mesh."""
    try:
        program = parse(source)
        translator = Translator()
        translate_program(translator, program)
    except (ParseError, TranslatorError) as exc:
        raise EvaluationError(str(exc)) from exc

    references = translator.get_references()

    shape_name, shape = translator.last_part()
    if shape_name is None or shape is None:
        # A document made only of references is legitimate: the panel has
        # something to show even though the B-Rep side is empty.
        if references:
            return EvaluationResult(
                mesh={"vertices": [], "faces": []},
                edges=[],
                shape_name="",
                body_count=0,
                references=references,
            )
        message = "No 3D part produced. Define a shape with extrude(...) before evaluating."
        raise EvaluationError(message) from TranslatorError(message)

    # A kernel failure here is attributed to the render-target binding rather
    # than surfacing as a bare AttributeError from inside build123d.
    vertices, faces = tessellate_shape(
        shape,
        shape_name,
        tolerance=tolerance,
        angular_tolerance=angular_tolerance,
    )
    if not vertices or not faces:
        raise EvaluationError("Tessellation produced no mesh data")

    mesh = {
        "vertices": [[v.X, v.Y, v.Z] for v in vertices],
        "faces": [list(face) for face in faces],
    }
    edge_registry = translator.get_edge_registry(shape_name)

    shape_edges_attr = hasattr(shape, "edges")
    try:
        raw_edge_count = len(list(shape.edges())) if shape_edges_attr else -1
    except Exception as exc:
        raw_edge_count = -2
        _dbg(f"shape.edges() raised: {type(exc).__name__}: {exc}")
    registry_keys = list(translator._logical_edge_registry.keys())
    _dbg(
        f"evaluate_source shape_name={shape_name!r} "
        f"shape_type={type(shape).__name__} "
        f"shape_has_edges_attr={shape_edges_attr} "
        f"raw_edges={raw_edge_count} "
        f"registry[{shape_name!r}].size={len(edge_registry)} "
        f"all_registry_keys={registry_keys} "
        f"pending_size={len(translator._pending_edge_registry)}\n"
        f"--- source ---\n{source}\n--- end source ---"
    )

    return EvaluationResult(
        mesh=mesh,
        edges=edge_registry,
        shape_name=shape_name,
        body_count=body_count_of(shape),
        references=references,
        shape=shape,
        bindings={name: value for name, value in translator.env.items()
                  if translator.is_part(value)},
    )


def export_source(source: str, *, format: str, path: str) -> str:
    """Parse source, build geometry, and export the final solid."""
    try:
        program = parse(source)
        translator = Translator()
        translate_program(translator, program)
    except (ParseError, TranslatorError) as exc:
        raise ExportError(str(exc)) from exc

    shape_name, shape = translator.last_part()
    if shape_name is None or shape is None:
        raise ExportError(
            "No 3D part produced. Define a shape with extrude(...) or another 3D primitive before exporting."
        )

    return export_built(shape, format=format, path=path, node_name=shape_name)


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

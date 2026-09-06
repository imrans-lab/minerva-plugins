"""Request handlers for the Go-Python bridge worker.

This module is pure (no I/O apart from the explicit `export` method, which
writes a single user-named file) so it can be tested directly without stdio.
Callers pass a decoded request dict and receive a response dict.

Per design §8, only `init` and `shutdown` are real in Round 1 (scaffold).
Round 2 Unit A adds a real `validate` implementation.
Round 3 Unit A adds real `evaluate` and `list_edges` implementations.
Round 4 adds `export` (STL binary / 3MF / STEP AP214) atop the existing
``mcad.evaluator`` helpers — ``export_built`` when the part is already in the
cache the last evaluation left, ``export_source`` when it has to be built.
The remaining stub is `deviation`.

`clearance` lives in its own module (``mcad_worker.clearance``) and is
imported at call time: it pulls in numpy and python-fcl, and a worker that
never measures a clearance should not pay for them.
"""

from __future__ import annotations

import hashlib
import os
import traceback
from pathlib import Path
from typing import Any, Optional, Tuple

WORKER_VERSION = "0.1.0"

# Module-level last-program cache (design §5).
# Keyed by hash(source); holds the last evaluation result as a plain dict.
# Size 1: replaced on each new source. Threadsafe is not required — the worker
# is single-threaded by design (§2 process model).
_last_program: Optional[Tuple[int, dict]] = None

# The B-Rep the last evaluation built, as (source digest, shape_name, shape).
# Separate from _last_program because it is a different product of the same
# source: the mesh reply is what the panel draws, this is what an export
# writes. Keeping it means an export of source the panel has already rendered
# costs a file write instead of a second translation — on a lofted shell of
# ~60 booleans that translation is minutes, and it was the whole reason a
# heavy document could render and then fail to export.
#
# Keyed by SHA-256, not hash(): two sources colliding in a 64-bit hash would
# write one document's geometry into the other's file with no signal at all.
_last_shape: Optional[Tuple[str, str, Any]] = None


def _digest(source: str) -> str:
    return hashlib.sha256(source.encode("utf-8")).hexdigest()


def reset_caches() -> None:
    """Forget the last evaluation and the part it built. For tests."""
    global _last_program, _last_shape
    _last_program = None
    _last_shape = None


# Best-effort OCCT version string, resolved once at module import.
_OCCT_VERSION: str = "unknown"
try:
    import OCP  # type: ignore[import]
    _OCCT_VERSION = getattr(OCP, "__version__", "unknown")
except Exception:
    try:
        # cadquery-ocp exposes the version differently on some installs.
        import OCC.Core.BRep  # type: ignore[import]
        _OCCT_VERSION = "7.x"
    except Exception:
        pass

# Best-effort build123d version, resolved once at module import.
_BUILD123D_VERSION: str = "unknown"
try:
    import build123d  # type: ignore[import]
    _BUILD123D_VERSION = getattr(build123d, "__version__", "unknown")
except Exception:
    pass


def _mesh_bbox(mesh: dict) -> Optional[dict]:
    """The axis-aligned bounds of a tessellated mesh, or None when it has no
    vertices. Millimetres, in the same frame the mesh is reported in."""
    vertices = mesh.get("vertices") or []
    if not vertices:
        return None
    xs = [v[0] for v in vertices]
    ys = [v[1] for v in vertices]
    zs = [v[2] for v in vertices]
    return {
        "min": [min(xs), min(ys), min(zs)],
        "max": [max(xs), max(ys), max(zs)],
        "size": [max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs)],
    }


def _mesh_defects(mesh: dict) -> dict:
    """The four ways a tessellation can be wrong, counted over its faces.

    A summary reply carries no mesh, so it has to carry what a reader would
    otherwise have checked the mesh for: an open edge is a hole in the
    surface, a non-manifold edge is three faces meeting on one edge, a
    degenerate face repeats a vertex index and a duplicate face is the same
    triangle twice. Only non-zero counts are reported — a clean mesh has
    nothing to say. The panel counts the same four over the same
    tessellation, so the two agree.
    """
    faces = mesh.get("faces") or []
    edge_uses: dict = {}
    seen_faces: set = set()
    degenerate = 0
    duplicate = 0
    for face in faces:
        if len(set(face)) != len(face):
            degenerate += 1
            continue
        key = tuple(sorted(face))
        if key in seen_faces:
            duplicate += 1
        else:
            seen_faces.add(key)
        for i in range(len(face)):
            a, b = face[i], face[(i + 1) % len(face)]
            edge = (a, b) if a < b else (b, a)
            edge_uses[edge] = edge_uses.get(edge, 0) + 1
    open_edges = sum(1 for count in edge_uses.values() if count == 1)
    non_manifold = sum(1 for count in edge_uses.values() if count > 2)
    reported = {
        "open_edges": open_edges,
        "non_manifold_edges": non_manifold,
        "degenerate_faces": degenerate,
        "duplicate_faces": duplicate,
    }
    return {name: count for name, count in reported.items() if count > 0}


def _summarise(result: dict) -> dict:
    """An evaluation reply WITHOUT its mesh: what the geometry is, how big it
    is and whether the tessellation is sound. On a real enclosure the mesh is
    the whole cost of the reply, and a caller checking that an edit landed
    never reads a vertex. The mesh is one more call away (summary=false)."""
    mesh: dict = result.get("mesh") or {}
    summary = {
        "summary": True,
        "shape_name": result.get("shape_name", ""),
        "body_count": result.get("body_count", 0),
        "bbox": _mesh_bbox(mesh),
        "vertex_count": len(mesh.get("vertices") or []),
        "face_count": len(mesh.get("faces") or []),
        "edge_count": len(result.get("edges") or []),
        "reference_count": len(result.get("references") or []),
    }
    defects = _mesh_defects(mesh)
    if defects:
        summary["mesh_defects"] = defects
    return summary


def _evaluate(params: dict) -> dict:
    """Run the full mcad pipeline (lex → parse → translate → tessellate).

    Returns {ok: True, result: {shape_name, body_count, mesh: {vertices,
    faces}, edges, references}}
    or {ok: False, error: {kind, message, ...}}.

    Maintains the module-level ``_last_program`` cache (design §5): if the
    same source is evaluated twice, the second call returns the cached dict
    without re-tessellating.

    ``params.summary`` replaces the reply with :func:`_summarise` — the same
    evaluation, reported without its mesh. The cache still holds the full
    result, so a summary call followed by a full one costs one tessellation.
    """
    global _last_program, _last_shape

    source = params.get("source")
    if not isinstance(source, str):
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "evaluate requires params.source: str",
            },
        }

    tolerance: float = float(params.get("tolerance", 0.1))
    angular_tolerance: float = float(params.get("angular_tolerance", 0.1))

    summary_only = bool(params.get("summary", False))

    h = hash(source)
    if _last_program is not None and _last_program[0] == h:
        cached = _last_program[1]
        return {"ok": True, "result": _summarise(cached) if summary_only else cached}

    try:
        from mcad.evaluator import EvaluationError, evaluate_source
        from mcad.lexer import LexError
        from mcad.parser import ParseError
        from mcad.translator import TranslatorError
    except ImportError as exc:
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": f"mcad package unavailable: {exc}",
            },
        }

    try:
        result = evaluate_source(
            source,
            tolerance=tolerance,
            angular_tolerance=angular_tolerance,
        )
    except LexError as exc:
        # LexError is not wrapped by EvaluationError; lex is conceptually part
        # of the parse phase per design §7. Surface as kind: "parse" with
        # line/col from the exception attributes.
        return {
            "ok": False,
            "error": {
                "kind": "parse",
                "message": str(exc),
                "details": {
                    "line": getattr(exc, "line", 0),
                    "col": getattr(exc, "col", 0),
                },
            },
        }
    except EvaluationError as exc:
        # EvaluationError wraps both ParseError and TranslatorError (and plain
        # "no 3D part produced" / "tessellation produced no mesh data" messages).
        # We inspect the __cause__ to pick the right kind.
        cause = exc.__cause__
        if isinstance(cause, ParseError):
            kind = "parse"
            tok = getattr(cause, "token", None)
            detail: dict = {}
            if tok is not None:
                detail = {"line": tok.line, "col": tok.col}
            return {
                "ok": False,
                "error": {
                    "kind": kind,
                    "message": str(exc),
                    "details": detail,
                },
            }
        if isinstance(cause, TranslatorError):
            return {
                "ok": False,
                "error": {
                    "kind": "translate",
                    "message": str(exc),
                },
            }
        # No typed cause or unrecognised cause → treat as OCCT/build123d error.
        return {
            "ok": False,
            "error": {
                "kind": "occt",
                "message": str(exc),
            },
        }
    except Exception as exc:
        return {
            "ok": False,
            "error": {
                "kind": "python",
                "message": str(exc),
                "traceback": traceback.format_exc(),
            },
        }

    result_dict: dict = {
        "shape_name": result.shape_name,
        "body_count": result.body_count,
        "mesh": result.mesh,
        "edges": result.edges,
        "references": result.references,
    }
    _last_program = (h, result_dict)
    # A document made only of references builds no part; leave the previous
    # shape in place rather than caching a None an export would trip over.
    if result.shape is not None:
        _last_shape = (_digest(source), result.shape_name, result.shape)
    if summary_only:
        return {"ok": True, "result": _summarise(result_dict)}
    return {"ok": True, "result": result_dict}


def _list_edges(params: dict) -> dict:
    """Return just the edges list for a given source (design §8.4).

    Reuses the ``_last_program`` cache when the source was evaluated recently,
    avoiding a redundant tessellation pass.
    """
    global _last_program

    source = params.get("source")
    if not isinstance(source, str):
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "list_edges requires params.source: str",
            },
        }

    h = hash(source)
    if _last_program is not None and _last_program[0] == h:
        return {"ok": True, "result": _without_polylines(_last_program[1]["edges"])}

    # Cache miss — run the full evaluate pipeline.
    response = _evaluate({"source": source})
    if not response.get("ok"):
        return response  # propagate error unchanged

    return {"ok": True, "result": _without_polylines(response["result"]["edges"])}


def _without_polylines(edges: list) -> list:
    """The edge list without the sampled points each entry carries.

    The polyline exists so the panel can DRAW an edge; a reader asking what
    edges a part has does not need forty points per arc, and on a real
    enclosure they are more than half the listing.
    """
    return [
        {key: value for key, value in entry.items() if key != "polyline"}
        for entry in edges
    ]


_SUPPORTED_EXPORT_FORMATS: frozenset[str] = frozenset(
    {"stl", "step", "stp", "3mf", "glb"}
)


def _export(params: dict) -> dict:
    """Export the last 3D part of *source* to *path* in *format*.

    Params:
        source: str — full .mcad source text.
        format: str — "stl" | "step" | "stp" | "3mf" | "glb" (case-insensitive).
                A .glb is written in the glTF frame (metres, Y-up) so
                mesh("that.glb") mounts it back at the same size and pose.
        path:   str — absolute or ~-prefixed path; relative paths resolve
                against the user's home directory (delegated to evaluator).

    Returns:
        {ok: True, result: {path: str, bytes_written: int, format: str}}
        on success, or {ok: False, error: {kind, message, ...}} on failure.

    Failure kinds:
        - "internal" — bad params (missing/wrong type).
        - "parse"    — DSL syntax error (propagated from evaluator).
        - "translate" — DSL is well-formed but produces no shape, or the
                         export call rejected the result.
        - "io"       — disk write failed (permission, missing parent dir
                       even after mkdir, etc).
        - "python"   — unhandled exception; includes traceback.
    """
    source = params.get("source")
    if not isinstance(source, str):
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "export requires params.source: str",
            },
        }

    fmt_raw = params.get("format")
    if not isinstance(fmt_raw, str) or fmt_raw.strip() == "":
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "export requires params.format: str",
            },
        }
    fmt = fmt_raw.strip().lower()
    if fmt not in _SUPPORTED_EXPORT_FORMATS:
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": (
                    f"unsupported export format: {fmt_raw!r} "
                    f"(supported: {sorted(_SUPPORTED_EXPORT_FORMATS)})"
                ),
            },
        }

    path = params.get("path")
    if not isinstance(path, str) or path.strip() == "":
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "export requires params.path: non-empty str",
            },
        }

    try:
        from mcad.evaluator import ExportError, export_built, export_source
        from mcad.lexer import LexError
        from mcad.parser import ParseError
        from mcad.translator import TranslatorError
    except ImportError as exc:
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": f"mcad package unavailable: {exc}",
            },
        }

    # The part the last evaluation built, when it was built from THIS source.
    # Reusing it is the difference between an export that costs a file write
    # and one that re-runs every boolean in the document; the digest is what
    # keeps an edited buffer off the cached shape.
    cached = _last_shape
    reused = cached is not None and cached[0] == _digest(source)

    try:
        if reused:
            written_path = export_built(cached[2], format=fmt, path=path,
                                        node_name=cached[1])
        else:
            written_path = export_source(source, format=fmt, path=path)
    except LexError as exc:
        # Lex errors aren't wrapped by ExportError (which only catches
        # ParseError/TranslatorError); surface as parse kind so callers
        # see a uniform "bad DSL" signal.
        return {
            "ok": False,
            "error": {
                "kind": "parse",
                "message": str(exc),
                "details": {
                    "line": getattr(exc, "line", 0),
                    "col": getattr(exc, "col", 0),
                },
            },
        }
    except ExportError as exc:
        cause = exc.__cause__
        if isinstance(cause, ParseError):
            kind = "parse"
        elif isinstance(cause, TranslatorError):
            kind = "translate"
        else:
            kind = "translate"
        return {
            "ok": False,
            "error": {"kind": kind, "message": str(exc)},
        }
    except OSError as exc:
        return {
            "ok": False,
            "error": {
                "kind": "io",
                "message": f"failed to write export: {exc}",
            },
        }
    except Exception as exc:
        return {
            "ok": False,
            "error": {
                "kind": "python",
                "message": str(exc),
                "traceback": traceback.format_exc(),
            },
        }

    bytes_written = 0
    try:
        bytes_written = os.path.getsize(written_path)
    except OSError:
        # File should exist (export_source already wrote it); if stat fails
        # we still report ok=True with bytes_written=0 rather than spuriously
        # failing the export call.
        pass

    return {
        "ok": True,
        "result": {
            "path": str(Path(written_path)),
            "bytes_written": bytes_written,
            "format": fmt,
            # Whether the part came from the last evaluation or was built for
            # this call. A reader watching an export get slow can tell the two
            # apart without guessing.
            "reused_evaluation": reused,
        },
    }


def _stub_not_implemented(req: dict) -> dict:
    """Return the standard scaffold stub error response."""
    return {
        "id": req.get("id"),
        "ok": False,
        "error": {
            "kind": "internal",
            "message": "not implemented in scaffold",
        },
    }


def _validate(params: dict) -> dict:
    """Validate .mcad source: lex + parse, but skip tessellation.

    Returns {ok: bool, errors: [...], warnings: [...]}. Lex and parse
    errors populate the errors list as data; they do NOT raise to the
    bridge layer. Only catastrophic Python failures (unhandled exceptions)
    propagate to the bridge as {ok: false, error: {kind: ...}}.

    Three phases, all OCCT-free so validate stays cheap enough for the LLM's
    inner loop: lex, parse, then resolve every call against the builtin name
    table (``mcad.builtins``). The third phase is what stops a clean bill of
    health for source the translator will refuse — an OpenSCAD ``difference()``
    or a diameter keyword parses perfectly well. Nothing is evaluated and no
    geometry is built; translator.py, which imports build123d at module level,
    is never imported.
    """
    source = params.get("source", "")
    if not isinstance(source, str):
        return {
            "ok": False,
            "error": {
                "kind": "internal",
                "message": "validate requires params.source: str",
            },
        }

    errors: list[dict] = []
    warnings: list[dict] = []

    try:
        from mcad.lexer import LexError, tokenize
        from mcad.parser import ParseError, Parser

        # Phase 1: lex
        try:
            tokens = tokenize(source)
        except LexError as exc:
            errors.append({"line": exc.line, "col": exc.col, "message": str(exc)})
            return {
                "ok": True,
                "result": {"ok": False, "errors": errors, "warnings": warnings},
            }

        # Phase 2: parse
        try:
            parser = Parser(tokens)
            program = parser.parse()
        except ParseError as exc:
            tok = exc.token
            if tok is not None:
                errors.append({"line": tok.line, "col": tok.col, "message": str(exc)})
            else:
                errors.append({"line": 0, "col": 0, "message": str(exc)})
            return {
                "ok": True,
                "result": {"ok": False, "errors": errors, "warnings": warnings},
            }

        # Phase 3: resolve names and keyword arguments against the builtin
        # table. Parsing accepts any call shape, so this is the only phase that
        # can say a name does not exist.
        from mcad.builtins import resolve_names

        errors.extend(resolve_names(program))

    except Exception as exc:
        return {
            "ok": False,
            "error": {
                "kind": "python",
                "message": str(exc),
                "traceback": traceback.format_exc(),
            },
        }

    return {
        "ok": True,
        "result": {
            "ok": len(errors) == 0,
            "errors": errors,
            "warnings": warnings,
        },
    }


def handle_request(req: dict) -> dict | None:
    """Dispatch a decoded request dict and return a response dict.

    Returns None only for inbound notifications (no id field and no
    expected response). For all recognised requests a dict is returned.

    Args:
        req: Decoded JSON request with at minimum a ``method`` key.

    Returns:
        Response dict with ``id``, ``ok``, and either ``result`` or
        ``error``; or None for pure notifications.
    """
    method: str = req.get("method", "")
    req_id = req.get("id")

    # Inbound notifications have no id and need no response.
    if req_id is None and method not in ("init", "shutdown"):
        return None

    if method == "init":
        return {
            "id": req_id,
            "ok": True,
            "result": {
                "worker_version": WORKER_VERSION,
                "occt_version": _OCCT_VERSION,
            },
        }

    if method == "shutdown":
        # Caller (dispatcher) uses the None sentinel to exit cleanly.
        return None  # dispatcher handles exit

    if method == "validate":
        result = _validate(req.get("params") or {})
        result["id"] = req_id
        return result

    if method == "evaluate":
        result = _evaluate(req.get("params") or {})
        result["id"] = req_id
        return result

    if method == "list_edges":
        result = _list_edges(req.get("params") or {})
        result["id"] = req_id
        return result

    if method == "export":
        result = _export(req.get("params") or {})
        result["id"] = req_id
        return result

    if method == "clearance":
        from .clearance import clearance
        result = clearance(req.get("params") or {})
        result["id"] = req_id
        return result

    if method == "cylindrical_features":
        from .features import cylindrical_features
        result = cylindrical_features(req.get("params") or {})
        result["id"] = req_id
        return result

    # Remaining geometry stub — filled in by per-tool grandchildren.
    if method == "deviation":
        return _stub_not_implemented(req)

    # Unknown method.
    return {
        "id": req_id,
        "ok": False,
        "error": {
            "kind": "internal",
            "message": f"unknown method: {method!r}",
        },
    }

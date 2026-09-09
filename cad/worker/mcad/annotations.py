"""Source-owned overlays in final model coordinates, independent of topology."""
from __future__ import annotations

import math
import re


def annotation_record(args: list, kwargs: dict, index: int, line: int) -> dict:
    from .builtins import BUILTIN_COMMANDS
    unknown = sorted(set(kwargs) - BUILTIN_COMMANDS["annotate"])
    if unknown:
        raise ValueError("unknown annotation arguments: " + ", ".join(unknown))
    if len(args) != 1:
        raise ValueError("annotate expects one model-coordinate point [x,y,z]")
    point = args[0]
    if not isinstance(point, list) or len(point) != 3 or not all(_finite(v) for v in point):
        raise ValueError("annotation point must contain three finite millimetre coordinates")
    text = kwargs.get("text", "")
    if not isinstance(text, str) or len(text) > 2000:
        raise ValueError("annotation text must be a string of at most 2000 characters")
    identifier = kwargs.get("id", f"annotation-{index + 1}")
    if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]{0,127}", identifier):
        raise ValueError("annotation id must be a short identifier starting with a letter or underscore")
    record = {"id": identifier, "at_mm": [float(v) for v in point], "text": text,
              "source_line": line, "coordinate_frame": "model", "association": "coordinate_only"}
    dimensional = any(k in kwargs for k in ("dimension", "nominal", "tolerance"))
    if dimensional:
        dimension = kwargs.get("dimension")
        nominal = kwargs.get("nominal")
        if dimension not in ("diameter", "radius", "length") or not _finite(nominal) or nominal <= 0:
            raise ValueError("dimension requires diameter, radius or length and a positive finite nominal in mm")
        record.update(dimension=dimension, nominal_mm=float(nominal))
        if "tolerance" in kwargs:
            limits = kwargs["tolerance"]
            if (not isinstance(limits, list) or len(limits) != 2 or
                    not all(_finite(v) for v in limits) or limits[0] > limits[1] or nominal + limits[0] <= 0):
                raise ValueError("tolerance must be ordered finite [lower,upper] deviations with positive finished size")
            record["deviations_mm"] = [float(v) for v in limits]
    elif not text.strip():
        raise ValueError("annotation needs text or an explicit nominal dimension")
    return record


def _finite(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

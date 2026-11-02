"""Neutral measurement-record v0 contract; validation has no I/O or geometry."""
from __future__ import annotations

import math
from typing import Literal, TypedDict


class Part(TypedDict):
    name: str
    units: Literal["mm"]


class Frame(TypedDict):
    origin: list[float]
    axes: dict[str, list[float]]


class Source(TypedDict):
    kind: Literal["photo", "laser", "caliper", "manual"]
    reference: str


class Feature(TypedDict):
    id: str
    kind: Literal["plane_height", "outline_rect", "slot", "point"]
    params: dict[str, float]
    sigma: dict[str, float]
    source: Source


class StillNeeded(TypedDict):
    param: str
    reason: Literal["below resolution", "occluded", "not measured"]
    suggest: str


class MeasurementRecord(TypedDict):
    part: Part
    frame: Frame
    features: list[Feature]
    still_needed: list[StillNeeded]


PARAMETERS: dict[str, tuple[str, ...]] = {
    "plane_height": ("z",),
    "outline_rect": ("x", "y", "width", "depth"),
    "slot": ("x", "y", "width", "length", "angle_deg"),
    "point": ("x", "y", "z"),
}


def _number(value: object) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _text(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def validate_record(record: object) -> list[str]:
    """Return path-qualified errors for decoded, untrusted JSON; [] is valid.

    Measurements remain nominal. Sigma is uncertainty, never a manufacturing
    allowance, and a missing measurement belongs in still_needed.
    """
    errors: list[str] = []

    def mapping(value: object, path: str, keys: tuple[str, ...]) -> dict[str, object]:
        if not isinstance(value, dict):
            errors.append(f"{path}: expected an object")
            return {}
        for key in keys:
            if key not in value:
                errors.append(f"{path}.{key}: required")
        for key in value:
            if key not in keys:
                errors.append(f"{path}.{key}: unknown v0 field")
        return value

    def vector(value: object, path: str) -> list[float] | None:
        if not isinstance(value, list) or len(value) != 3 or not all(_number(v) for v in value):
            errors.append(f"{path}: expected three finite numbers")
            return None
        return [float(v) for v in value]

    root = mapping(record, "record", ("part", "frame", "features", "still_needed"))
    part = mapping(root.get("part"), "part", ("name", "units"))
    if not _text(part.get("name")):
        errors.append("part.name: expected a nonempty name")
    if part.get("units") != "mm":
        errors.append("part.units: only mm is supported")
    frame = mapping(root.get("frame"), "frame", ("origin", "axes"))
    vector(frame.get("origin"), "frame.origin")
    axes = mapping(frame.get("axes"), "frame.axes", ("x", "y", "z"))
    vectors = [vector(axes.get(key), f"frame.axes.{key}") for key in ("x", "y", "z")]
    if all(v is not None for v in vectors):
        x, y, z = vectors
        # Each axis is a unit direction; scaling belongs in measured parameters.
        if any(abs(sum(a * a for a in v) - 1) > 1e-6 for v in vectors):
            errors.append("frame.axes: directions must have unit length")
        if any(abs(sum(a * b for a, b in zip(vectors[i], vectors[j]))) > 1e-6 for i, j in ((0, 1), (0, 2), (1, 2))):
            errors.append("frame.axes: directions must be orthogonal")
        cross = [x[1]*y[2]-x[2]*y[1], x[2]*y[0]-x[0]*y[2], x[0]*y[1]-x[1]*y[0]]
        if sum(a * b for a, b in zip(cross, z)) < 1 - 1e-6:
            errors.append("frame.axes: directions must be right-handed")
    features = root.get("features")
    if not isinstance(features, list):
        errors.append("features: expected an array")
        features = []
    identifiers: set[str] = set()
    for index, value in enumerate(features):
        path = f"features[{index}]"
        feature = mapping(value, path, ("id", "kind", "params", "sigma", "source"))
        identifier = feature.get("id")
        if not _text(identifier):
            errors.append(f"{path}.id: expected a nonempty identifier")
        elif identifier in identifiers:
            errors.append(f"{path}.id: duplicate identifier {identifier}")
        else:
            identifiers.add(identifier)
        kind = feature.get("kind")
        keys = PARAMETERS.get(kind) if isinstance(kind, str) else None
        if keys is None:
            errors.append(f"{path}.kind: unknown feature kind {kind!r}")
        params = feature.get("params")
        if not isinstance(params, dict):
            errors.append(f"{path}.params: expected an object")
            params = {}
        elif keys is not None and set(params) != set(keys):
            errors.append(f"{path}.params: {kind} requires exactly {', '.join(keys)}")
        for key, parameter in params.items():
            if not _number(parameter):
                errors.append(f"{path}.params.{key}: expected a finite number")
            elif key in ("width", "depth", "length") and parameter <= 0:
                errors.append(f"{path}.params.{key}: must be positive")
        if (kind == "slot" and _number(params.get("length")) and _number(params.get("width"))
                and params["length"] < params["width"]):
            errors.append(f"{path}.params.length: slot overall length must be at least its width")
        sigma = feature.get("sigma")
        if not isinstance(sigma, dict):
            errors.append(f"{path}.sigma: required per-parameter uncertainty object")
        else:
            if set(sigma) != set(params):
                errors.append(f"{path}.sigma: keys must match params exactly")
            for key, uncertainty in sigma.items():
                if not _number(uncertainty) or uncertainty < 0:
                    errors.append(f"{path}.sigma.{key}: expected a finite nonnegative uncertainty")
        source = mapping(feature.get("source"), f"{path}.source", ("kind", "reference"))
        if source.get("kind") not in ("photo", "laser", "caliper", "manual"):
            errors.append(f"{path}.source.kind: expected photo, laser, caliper or manual")
        if not _text(source.get("reference")):
            errors.append(f"{path}.source.reference: expected a nonempty reference")
    needed = root.get("still_needed")
    if not isinstance(needed, list):
        errors.append("still_needed: expected an array")
        needed = []
    for index, value in enumerate(needed):
        path = f"still_needed[{index}]"
        entry = mapping(value, path, ("param", "reason", "suggest"))
        for key in ("param", "suggest"):
            if not _text(entry.get(key)):
                errors.append(f"{path}.{key}: expected nonempty text")
        if entry.get("reason") not in ("below resolution", "occluded", "not measured"):
            errors.append(f"{path}.reason: expected below resolution, occluded or not measured")
    return errors

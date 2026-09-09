"""Bounded translation-path checks over cached B-Reps, without motion planning."""
import math


class BudgetExceeded(Exception):
    pass


def _number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{label} must be finite numeric data")
    return float(value)


def motion(params):
    try:
        return {"ok": True, "result": _run(params)}
    except (ValueError, TypeError) as exc:
        return {"ok": False, "error": {"kind": "validation", "message": str(exc)}}


def _run(params):
    from build123d import Location
    from OCP.BRepExtrema import BRepExtrema_DistShapeShape
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Common
    from OCP.BRepGProp import BRepGProp
    from OCP.GProp import GProp_GProps
    from . import methods

    source = params.get("source", "")
    selection = params.get("selection", "")
    configuration = params.get("configuration", "")
    against = params.get("against", [])
    path = params.get("path_mm", [])
    if any(k in params for k in ("rotations", "rotation", "poses", "rotations_deg")):
        raise ValueError("motion supports translation offsets only; rotation is unsupported")
    if not isinstance(selection, str) or not selection or not isinstance(against, list) or not 1 <= len(against) <= 64:
        raise ValueError("motion requires a selection and 1–64 explicit obstacle selectors in against")
    if any(not isinstance(s, str) or not s for s in against) or len(set(against)) != len(against):
        raise ValueError("against must contain distinct nonempty selectors")
    if not isinstance(path, list) or not 2 <= len(path) <= 64:
        raise ValueError("path_mm must contain 2–64 translation offsets")
    points = []
    for point in path:
        if not isinstance(point, list) or len(point) != 3:
            raise ValueError("each path_mm offset must be [x,y,z]")
        points.append(tuple(_number(v, "path_mm") for v in point))
    if not any(a != b for a, b in zip(points, points[1:])):
        raise ValueError("path has no movement; use a static fit check")
    required = _number(params.get("required_mm", 0), "required_mm")
    tolerance = _number(params.get("numeric_tolerance_mm", 1e-6), "numeric_tolerance_mm")
    maximum = _number(params.get("max_samples", 64), "max_samples")
    if required < 0 or not 1e-7 <= tolerance <= 0.01 or maximum != int(maximum) or not 2 <= maximum <= 512:
        raise ValueError("required_mm must be nonnegative, numeric_tolerance_mm in [1e-7,0.01], max_samples an integer in [2,512]")
    initial = methods._evaluate({"source": source, "configuration": configuration, "summary": True})
    if not initial["ok"]:
        raise ValueError(initial["error"]["message"])
    document = methods._shape_documents[methods._digest(source)]
    _, shape, moving_refs, model = document.select(selection, configuration)
    if not model.get("physical", initial["result"].get("model", {}).get("physical", True)):
        return {"checked": False, "pass": None, "reason": "Presentation-only configuration cannot pass physical validation"}
    if moving_refs or shape is None or not hasattr(shape, "solids") or not shape.solids() or not shape.is_valid:
        raise ValueError("moving selection must be a valid solid B-Rep; imported mesh motion is unsupported")
    moving_bodies = list(shape.solids())
    obstacles = []
    for name in against:
        _, obstacle, obstacle_refs, _ = document.select(name, configuration)
        if obstacle_refs or obstacle is None or not hasattr(obstacle, "solids") or not obstacle.solids() or not obstacle.is_valid:
            raise ValueError(f"obstacle {name!r} has no valid solid B-Rep; imported mesh obstacles are unsupported")
        obstacles.extend((name, solid) for solid in obstacle.solids())
    pair_count = len(moving_bodies) * len(obstacles)
    if pair_count > 256:
        raise ValueError("motion exceeds 256 solid-body pairs; narrow the declared scope")
    samples = {}
    queries = 0

    def sample(point):
        nonlocal queries
        if point in samples:
            return samples[point]
        if len(samples) >= maximum or queries + pair_count > 4096:
            raise BudgetExceeded()
        best = {"distance_mm": math.inf, "overlap": False, "offset_mm": list(point)}
        for body in moving_bodies:
            moved = body.moved(Location(point))
            for name, obstacle in obstacles:
                queries += 1
                distance = BRepExtrema_DistShapeShape(moved.wrapped, obstacle.wrapped)
                if not distance.IsDone() or distance.NbSolution() <= 0:
                    raise ValueError("OCCT could not determine a body-pair distance")
                value = float(distance.Value())
                overlap = bool(distance.InnerSolution())
                if value <= tolerance and not overlap:
                    common = BRepAlgoAPI_Common(moved.wrapped, obstacle.wrapped)
                    if not common.IsDone():
                        raise ValueError("OCCT could not distinguish contact from overlap")
                    props = GProp_GProps()
                    BRepGProp.VolumeProperties_s(common.Shape(), props)
                    overlap = abs(props.Mass()) > tolerance ** 3
                if value < best["distance_mm"] or overlap:
                    a, b = distance.PointOnShape1(1), distance.PointOnShape2(1)
                    best = {"distance_mm": value, "overlap": overlap, "offset_mm": list(point),
                            "against": name, "solid_point_mm": [a.X(), a.Y(), a.Z()],
                            "obstacle_point_mm": [b.X(), b.Y(), b.Z()]}
                if overlap:
                    break
            if best["overlap"]:
                break
        samples[point] = best
        return best

    pending = [(index, a, b) for index, (a, b) in reversed(list(enumerate(zip(points, points[1:]))))]
    unknown, violations = [], []
    certified = 0
    lower_bound = math.inf
    while pending:
        index, a, b = pending.pop()
        try:
            left, right = sample(a), sample(b)
        except BudgetExceeded:
            unknown.append({"segment": index, "from_mm": list(a), "to_mm": list(b)})
            continue
        bad = next((s for s in (left, right) if s["overlap"] or s["distance_mm"] + tolerance < required), None)
        if bad:
            violations.append({"segment": index, **bad})
            break
        bound = min(left["distance_mm"], right["distance_mm"]) - math.dist(a, b) / 2 - tolerance
        if bound >= required:
            certified += 1
            lower_bound = min(lower_bound, bound)
            continue
        middle = tuple((x + y) / 2 for x, y in zip(a, b))
        if middle in (a, b) or len(samples) >= maximum or queries + pair_count > 4096:
            unknown.append({"segment": index, "from_mm": list(a), "to_mm": list(b)})
        else:
            pending.extend([(index, middle, b), (index, a, middle)])
    verdict = "fail" if violations else ("unknown" if unknown else "pass")
    return {"checked": True, "pass": True if verdict == "pass" else (False if verdict == "fail" else None),
            "verdict": verdict, "mode": "translation_path", "units": "mm", "configuration": configuration,
            "selection": selection, "against": against, "path_mm": [list(p) for p in points],
            "required_mm": required, "numeric_tolerance_mm": tolerance,
            "samples": len(samples), "distance_queries": queries, "certified_intervals": certified,
            "certified_clearance_lower_bound_mm": lower_bound if math.isfinite(lower_bound) else None,
            "violations": violations, "unmeasured_intervals": unknown,
            "stopped_on_violation": bool(violations), "remaining_intervals": len(pending),
            "coverage": "declared obstacle selectors only",
            "scope_exclusions": ["Objects outside against are not obstacles in this check"],
            "unsupported": ["rotation", "imported mesh bodies"], "engine": "OCCT B-Rep distance/intersection",
            "bound": "Translation distance is 1-Lipschitz. Each certified interval uses min(endpoint clearance) minus half travel minus numerical allowance; sample-budget exhaustion is unknown.",
            "provenance": {**initial["result"].get("provenance", {}), "selection": selection, "configuration": configuration}}

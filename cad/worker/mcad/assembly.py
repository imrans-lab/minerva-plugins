"""Immutable placed instances; grouping never performs a Boolean union."""
from __future__ import annotations

from dataclasses import dataclass, replace
import re
from typing import Any

from .reference import IDENTITY, Matrix, MeshReference, multiply


@dataclass(frozen=True)
class Instance:
    id: str
    definition: str
    value: Any
    matrix: Matrix = IDENTITY
    source: str = ""
    accuracy: str = "unspecified"

    def posed(self, matrix: Matrix) -> Instance:
        return replace(self, matrix=multiply(matrix, self.matrix))


@dataclass(frozen=True)
class Assembly:
    instances: tuple[Instance, ...]
    physical: bool = True

    def posed(self, matrix: Matrix) -> Assembly:
        return replace(self, instances=tuple(i.posed(matrix) for i in self.instances))


def identifier(value: Any) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]{0,127}", value):
        raise ValueError("instance and definition IDs must be short identifiers")
    return value


def make_instance(value: Any, *, id: str, definition: str, source: str = "",
                  accuracy: str = "unspecified") -> Instance:
    if not isinstance(value, (MeshReference, Assembly)) and (not hasattr(value, "tessellate") or float(getattr(value, "volume", 0)) <= 0):
        raise ValueError("instance() requires a solid, mesh reference or assembly")
    if accuracy not in ("unspecified", "supplier", "measured", "approximate"):
        raise ValueError("accuracy must be unspecified, supplier, measured or approximate")
    if not isinstance(source, str) or len(source) > 2000:
        raise ValueError("component source must be text of at most 2000 characters")
    return Instance(identifier(id), identifier(definition), value, source=source, accuracy=accuracy)


def make_assembly(instances: Any) -> Assembly:
    if not isinstance(instances, list) or not instances or len(instances) > 1000:
        raise ValueError("assembly() requires a nonempty list of at most 1000 instances")
    if not all(isinstance(i, Instance) for i in instances):
        raise ValueError("assembly() entries must be explicit instance() values")
    if len({i.id for i in instances}) != len(instances):
        raise ValueError("assembly instance IDs must be unique")
    result = Assembly(tuple(instances), physical=all(
        not isinstance(i.value, Assembly) or i.value.physical for i in instances))
    flatten(result)  # Catch conflicting definitions before any geometry is built.
    return result


def configure(base: Any, replacements: Any, *, physical: bool = False,
              include: Any = None) -> Assembly:
    if not isinstance(base, Assembly) or not isinstance(replacements, list):
        raise ValueError("configuration() requires an assembly and a list of instance replacements")
    if not isinstance(physical, bool):
        raise ValueError("configuration physical must be true or false")
    originals = {i.id: i for i in base.instances}
    seen = set()
    for item in replacements:
        if not isinstance(item, Instance) or item.id not in originals or item.id in seen:
            raise ValueError("configuration replacements must name distinct existing instances")
        old = originals[item.id]
        if old.definition != item.definition or old.value is not item.value:
            raise ValueError("configuration may change placement, not instance definition")
        originals[item.id] = item
        seen.add(item.id)
    if include is not None:
        if not isinstance(include, list) or not include or any(x not in originals for x in include):
            raise ValueError("configuration include must name existing instances")
        if len(set(include)) != len(include):
            raise ValueError("configuration include IDs must be unique")
    ids = include if include is not None else list(originals)
    return Assembly(tuple(originals[i] for i in ids), physical=physical)


def flatten(value: Assembly | Instance) -> list[Instance]:
    """Stable hierarchical IDs and composed poses, retaining shared definitions."""
    out: list[Instance] = []
    definitions: dict[str, Any] = {}

    def visit(item: Instance, prefix: str, pose: Matrix) -> None:
        name = prefix + item.id
        matrix = multiply(pose, item.matrix)
        if isinstance(item.value, Assembly):
            for child in item.value.instances:
                visit(child, name + "/", matrix)
        else:
            if item.definition in definitions and definitions[item.definition] is not item.value:
                raise ValueError(f"definition {item.definition!r} names different geometry")
            definitions[item.definition] = item.value
            out.append(replace(item, id=name, matrix=matrix))
        if len(out) > 1000:
            raise ValueError("assembly exceeds 1000 flattened instances")

    for instance in value.instances if isinstance(value, Assembly) else (value,):
        visit(instance, "", IDENTITY)
    return out


def posed_shape(instance: Instance) -> Any:
    from build123d import Location
    from OCP.gp import gp_Trsf
    transform = gp_Trsf()
    transform.SetValues(*(v for row in instance.matrix[:3] for v in row))
    return instance.value.moved(Location(transform))


def evaluate_assembly(value: Assembly | Instance) -> tuple[Any, list[dict], dict, dict]:
    """Return solid compound, reference records, selectable solids and metadata."""
    from build123d import Compound
    shapes: dict[str, Any] = {}
    references: list[dict] = []
    definitions: dict[str, dict] = {}
    instances: list[dict] = []
    for item in flatten(value):
        reference = isinstance(item.value, MeshReference)
        definitions.setdefault(item.definition, {"id": item.definition,
            "kind": "reference" if reference else "solid", "source": item.source,
            "accuracy": item.accuracy, "units": "mm", "up": "z"})
        for field, supplied, unspecified in (("source", item.source, ""), ("accuracy", item.accuracy, "unspecified")):
            previous = definitions[item.definition][field]
            if supplied != unspecified:
                if previous not in (unspecified, supplied):
                    raise ValueError(f"conflicting {field} for definition {item.definition!r}")
                definitions[item.definition][field] = supplied
        row = {"id": item.id, "definition": item.definition,
               "matrix": [list(r) for r in item.matrix]}
        if reference:
            ref = item.value.posed(item.matrix).renamed(item.id).to_dict()
            ref.update(definition=item.definition, source=item.source, accuracy=item.accuracy)
            references.append(ref)
            definitions[item.definition].update(path=item.value.path, units=item.value.units, up=item.value.up)
        else:
            shape = posed_shape(item)
            shape.label = item.id
            shapes[item.id] = shape
        instances.append(row)
    groups = []

    def group_members(item: Instance, prefix: str = "") -> None:
        name = prefix + item.id
        if isinstance(item.value, Assembly):
            groups.append({"id": name, "instances": [row["id"] for row in instances
                           if row["id"].startswith(name + "/")]})
            for child in item.value.instances:
                group_members(child, name + "/")

    for item in value.instances if isinstance(value, Assembly) else (value,):
        group_members(item)
    compound = Compound(children=list(shapes.values())) if shapes else None
    return compound, references, shapes, {"definitions": list(definitions.values()),
        "instances": instances, "groups": groups,
        "physical": value.physical if isinstance(value, Assembly) else True}

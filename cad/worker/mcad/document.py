"""One immutable evaluation authority for bindings, placements and named selection."""
from __future__ import annotations

from dataclasses import dataclass, field
from collections import OrderedDict
from typing import Any

from .assembly import Assembly, Instance, evaluate_assembly
from .reference import MeshReference


@dataclass
class EvaluatedDocument:
    target: str
    bindings: dict[str, Any]
    references: list[dict]
    annotations: list[dict]
    edge_registries: dict[str, list]
    _scenes: dict[str, tuple] = field(default_factory=dict)
    _renders: OrderedDict[tuple, Any] = field(default_factory=OrderedDict)

    @classmethod
    def from_translator(cls, translator):
        name, _ = translator.last_part()
        return cls(name or "", dict(translator.env), translator.get_references(),
                   translator.annotations, dict(translator._logical_edge_registry))

    def scene(self, configuration: str = "") -> tuple:
        name = configuration or self.target
        if configuration and not isinstance(self.bindings.get(name), Assembly):
            raise ValueError(f"unknown assembly configuration {name!r}")
        if name not in self._scenes:
            value = self.bindings.get(name)
            if isinstance(value, (Assembly, Instance)):
                shape, refs, instances, metadata = evaluate_assembly(value)
            else:
                shape, refs, instances, metadata = value, self.references, {}, {}
            self._scenes[name] = (name, shape, refs, instances, metadata)
        return self._scenes[name]

    def select(self, selection: str = "", configuration: str = "") -> tuple:
        name, shape, references, instances, metadata = self.scene(configuration)
        if not selection:
            return name, shape, references, metadata
        kind, separator, key = selection.partition(":")
        if not separator:
            key, kind = selection, ""
        if kind not in ("", "binding", "instance", "reference"):
            raise ValueError(f"unknown selection namespace {kind!r}")
        candidates = []
        value = self.bindings.get(key)
        if kind in ("", "binding") and value is not None:
            if isinstance(value, (Assembly, Instance)):
                solid, refs, _, model = evaluate_assembly(value)
                candidates.append((key, solid, refs, model))
            elif isinstance(value, MeshReference):
                candidates.append((key, None, [value.renamed(key).to_dict()], {}))
            elif hasattr(value, "tessellate"):
                candidates.append((key, value, [], {}))
        if kind in ("", "instance") and key in instances:
            candidates.append((key, instances[key], [], metadata))
        if kind in ("", "reference", "instance"):
            for ref in references:
                if ref.get("name") == key and (kind != "instance" or metadata):
                    # A legacy reference binding and its scene entry are one object.
                    if not (kind == "" and isinstance(value, MeshReference)):
                        candidates.append((key, None, [ref], metadata))
        if len(candidates) != 1:
            state = "ambiguous" if candidates else "unknown"
            raise ValueError(f"{state} selection {selection!r}; use binding:, instance: or reference: explicitly")
        return candidates[0]

    def render(self, selection: str = "", configuration: str = "", *,
               tolerance: float = 0.1, angular_tolerance: float = 0.1):
        from .evaluator import EvaluationResult, body_count_of
        from .build_trace import tessellate_shape
        from .translator import Translator
        cache_key = (selection, configuration, tolerance, angular_tolerance)
        if cache_key in self._renders:
            self._renders.move_to_end(cache_key)
            return self._renders[cache_key]
        name, shape, references, assembly = self.select(selection, configuration)
        if shape is None:
            if not references:
                raise ValueError("No 3D part produced. Define a shape before evaluating.")
            mesh, edges, count = {"vertices": [], "faces": []}, [], 0
        else:
            vertices, faces = tessellate_shape(shape, name, tolerance=tolerance,
                                               angular_tolerance=angular_tolerance)
            if not vertices or not faces:
                raise ValueError("Tessellation produced no mesh data")
            mesh = {"vertices": [[v.X, v.Y, v.Z] for v in vertices], "faces": [list(f) for f in faces]}
            edges = self.edge_registries.get(name)
            if edges is None or assembly:
                edges = Translator()._enumerate_edges(shape)
            count = body_count_of(shape)
        model = {**assembly, "configuration": (configuration or self.target) if assembly else "",
                 "selection": selection, "configurations": [
                     {"name": n, "physical": v.physical} for n, v in self.bindings.items()
                     if isinstance(v, Assembly)]}
        result = EvaluationResult(mesh=mesh, edges=edges, shape_name=name, body_count=count,
            references=references, annotations=self.annotations, shape=shape,
            bindings={n:v for n,v in self.bindings.items() if Translator.is_part(v)},
            document=self, model=model)
        self._renders[cache_key] = result
        while len(self._renders) > 32:
            self._renders.popitem(last=False)
        return result

extends RefCounted
## gauge_seed.gd — the ray-grid fallback, used only when the fitter proposed
## nothing at all. Rays on a grid down an axis; a miss whose neighbours all hit
## is inside an opening rather than off the edge of the part, and clusters of
## such cells become seeds a normal gauge search can refine.
##
## The physics is one question — "does this ray hit anything" — handed in as a
## Callable, so the grid arithmetic and the clustering are testable without a
## physics space and mesh_gauge.gd stays about queries.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/gauge_seed.gd")

const _Shapes: Script = preload("gauge_shapes.gd")

## A missing ray whose neighbours this far away all hit is inside an enclosed
## opening rather than off the edge of the part.
const SEED_NEIGHBOUR_CELLS: int = 4
## Clearance either side of the bounds when a seeding ray is cast.
const SEED_PAD_MM: float = 3.0
## Cells a single pass may cast. Past this the pitch is wrong, and saying so is
## more useful than spending a minute proving it.
const MAX_CELLS: int = 250000


## Seeds for one axis. `hits` is called as hits.call(from: Vector3, to: Vector3)
## and must answer whether the segment struck anything. Returns
## {seeds: [{center, axis, radius_hint_mm, cells}]}.
static func seed_grid(bounds: AABB, axis: Vector3, pitch: float, hits: Callable) -> Dictionary:
	if bounds.size.length() <= 0.0 or pitch <= 0.0:
		return {"seeds": []}

	var basis: Basis = _Shapes.basis_for_axis(axis)
	var u := basis.x
	var v := basis.y
	var centre := bounds.get_center()
	var reach := bounds.size.length()
	var half := reach * 0.5 + SEED_PAD_MM

	var extent_u: float = _Shapes.extent_along(bounds, u) * 0.5 + pitch
	var extent_v: float = _Shapes.extent_along(bounds, v) * 0.5 + pitch
	var cols := int(ceil(extent_u * 2.0 / pitch)) + 1
	var rows := int(ceil(extent_v * 2.0 / pitch)) + 1
	if cols * rows > MAX_CELLS:
		return {"seeds": [], "error": "seed grid too large; raise pitch_mm"}

	var hit_grid := {}
	for c in range(cols):
		for r in range(rows):
			var p := centre \
				+ u * (-extent_u + float(c) * pitch) \
				+ v * (-extent_v + float(r) * pitch)
			var from := p + axis * half
			var to := p - axis * half
			hit_grid[Vector2i(c, r)] = bool(hits.call(from, to))

	var enclosed := {}
	for key in hit_grid.keys():
		var cell: Vector2i = key
		if bool(hit_grid[cell]):
			continue
		if _neighbours_hit(hit_grid, cell):
			enclosed[cell] = true

	var seeds: Array = []
	while not enclosed.is_empty():
		var start: Vector2i = enclosed.keys()[0]
		var cluster: Array = []
		var frontier: Array = [start]
		enclosed.erase(start)
		while not frontier.is_empty():
			var cell: Vector2i = frontier.pop_back()
			cluster.append(cell)
			for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var next: Vector2i = cell + step
				if enclosed.has(next):
					enclosed.erase(next)
					frontier.append(next)
		var sum := Vector2.ZERO
		for cell in cluster:
			sum += Vector2(float((cell as Vector2i).x), float((cell as Vector2i).y))
		var mean := sum / float(cluster.size())
		var seed_point := centre \
			+ u * (-extent_u + mean.x * pitch) \
			+ v * (-extent_v + mean.y * pitch)
		seeds.append({
			"center": seed_point,
			"axis": axis,
			"radius_hint_mm": sqrt(float(cluster.size())) * pitch * 0.5,
			"cells": cluster.size(),
		})
	return {"seeds": seeds}


## True when the four cells this far away in each direction were all hit: the
## cell is inside an enclosed opening, not off the edge of the part.
static func _neighbours_hit(grid: Dictionary, cell: Vector2i) -> bool:
	for step in [
		Vector2i(SEED_NEIGHBOUR_CELLS, 0),
		Vector2i(-SEED_NEIGHBOUR_CELLS, 0),
		Vector2i(0, SEED_NEIGHBOUR_CELLS),
		Vector2i(0, -SEED_NEIGHBOUR_CELLS),
	]:
		var neighbour: Vector2i = cell + step
		if not grid.has(neighbour) or not bool(grid[neighbour]):
			return false
	return true

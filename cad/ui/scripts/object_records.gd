extends RefCounted
## Adapt native definitions to the same triangle-picking contract as imports.
const References := preload("reference_meshes.gd")

static func build(result: Dictionary, references: Array) -> Array:
	var records: Array = []
	for reference_record: Dictionary in references:
		records.append(reference_record.duplicate())
	var meshes: Dictionary = {}
	for definition: String in result.get("picking", {}):
		var data: Dictionary = result.picking[definition]
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		var vertices := PackedVector3Array()
		var indices := PackedInt32Array()
		for vertex: Array in data.get("vertices", []):
			vertices.append(Vector3(vertex[0], vertex[1], vertex[2]))
		for face: Array in data.get("faces", []):
			indices.append_array(PackedInt32Array(face))
		if vertices.is_empty() or indices.is_empty():
			continue
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		meshes[definition] = {"mesh": mesh, "stamp": JSON.stringify(data).sha256_text()}
	var model: Dictionary = result.get("model", {})
	for record: Dictionary in records:
		for instance: Dictionary in model.get("instances", []):
			if str(instance.id) == str(record.name):
				record["metadata"] = instance.duplicate(true)
				for definition: Dictionary in model.get("definitions", []):
					if str(definition.id) == str(instance.definition):
						record.metadata["definition_info"] = definition
	var instances: Array = model.get("instances", []).duplicate()
	if instances.is_empty() and not meshes.is_empty():
		instances.append({"id": result.get("shape_name", "solid"), "definition": meshes.keys()[0]})
	for instance: Dictionary in instances:
		var definition := str(instance.get("definition", ""))
		if not meshes.has(definition):
			continue
		var mesh: ArrayMesh = meshes[definition].mesh
		var pose := References.transform_from_matrix(instance.get("matrix", []))
		var info: Dictionary = instance.duplicate(true)
		for entry: Dictionary in model.get("definitions", []):
			if str(entry.id) == definition:
				info["definition_info"] = entry
		records.append({"name": str(instance.id), "kind": "solid", "metadata": info,
			"pose": pose, "stamp": meshes[definition].stamp,
			"world_aabb": References.transform_aabb(pose, mesh.get_aabb()),
			"node_bounds": [{"name": definition, "path": definition, "aabb": mesh.get_aabb()}],
			"parts": [{"name": definition, "node_path": definition, "mesh": mesh,
				"aabb": mesh.get_aabb(), "transform": Transform3D.IDENTITY}]})
	return records

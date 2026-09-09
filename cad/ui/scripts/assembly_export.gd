extends RefCounted
## Assemble shared definition meshes with the evaluated instance transforms.
const Files := preload("package_files.gd")

static func write(library: RefCounted, evaluated: Dictionary, definitions: Dictionary, directory: String) -> Dictionary:
	var root := Node3D.new()
	root.name = "CADAssembly"
	# CAD millimetres/Z-up to glTF metres/Y-up, once for the whole scene.
	root.transform = Transform3D(Basis(Vector3(.001, 0, 0), Vector3(0, 0, -.001), Vector3(0, .001, 0)), Vector3.ZERO)
	var nodes: Array = []
	var references: Dictionary = {}
	for reference: Dictionary in evaluated.get("references", []):
		references[str(reference.get("name", ""))] = reference
	var instances: Array = evaluated.get("model", {}).get("instances", []).duplicate(true)
	if instances.is_empty():
		if evaluated.get("body_count", 0) > 0:
			instances.append({"id": evaluated.get("shape_name", "solid"), "definition": "_solid"})
		for name in references:
			instances.append({"id": name, "definition": ""})
	var error := ""
	for instance: Dictionary in instances:
		var id := str(instance.id)
		var definition := str(instance.get("definition", ""))
		var placement = instance.get("matrix", [])
		var path := str(definitions.get(definition, ""))
		var units := ""
		var up := ""
		if references.has(id):
			var reference: Dictionary = references[id]
			var resolved: Dictionary = library.resolve(str(reference.path), directory.path_join("model.mcad"))
			if not str(resolved.get("error", "")).is_empty():
				error = str(resolved.error)
				break
			path = str(resolved.path)
			units = str(reference.get("units", ""))
			up = str(reference.get("up", ""))
			placement = reference.get("matrix", [])
		var loaded = library.load_file(path, units, up)
		if not loaded.is_ok():
			error = "Cannot export instance %s: %s" % [id, loaded.error]
			break
		var node := Node3D.new()
		node.name = "part_" + id.sha256_text().left(24)
		node.transform = transform(placement)
		root.add_child(node)
		node.owner = root
		for part: Dictionary in loaded.parts:
			var mesh := MeshInstance3D.new()
			mesh.mesh = part.mesh
			mesh.transform = part.transform
			node.add_child(mesh)
			mesh.owner = root
		nodes.append({"id": id, "definition": definition, "gltf_node": str(node.name), "matrix": placement})
	if error.is_empty():
		var gltf := GLTFDocument.new()
		var state := GLTFState.new()
		var code := gltf.append_from_scene(root, state)
		if code == OK:
			code = gltf.write_to_filesystem(state, directory.path_join("assembly.glb"))
		if code != OK:
			error = "Cannot write assembly glTF: " + error_string(code)
	root.free()
	return {"error": error} if not error.is_empty() else {"instances": nodes, "path": "assembly.glb", "units": "m", "up": "y"}

static func transform(matrix: Array) -> Transform3D:
	if matrix.is_empty():
		return Transform3D.IDENTITY
	return Transform3D(Basis(Vector3(matrix[0][0], matrix[1][0], matrix[2][0]),
		Vector3(matrix[0][1], matrix[1][1], matrix[2][1]), Vector3(matrix[0][2], matrix[1][2], matrix[2][2])),
		Vector3(matrix[0][3], matrix[1][3], matrix[2][3]))

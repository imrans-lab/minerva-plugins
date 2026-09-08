extends SceneTree
## Synthetic stepped bores and metre-scale annular seats, with real physics.
const Gauge = preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")
const Probe = preload("res://../../minerva-plugins/cad/ui/scripts/fastener_checks.gd")
const Geometry = preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")
var passed := 0
var failed := 0

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)

func _init() -> void:
	await process_frame
	var module = Probe.new()
	var bore := {"dia_mm": 2.5, "axis": Vector3(0,0,1), "centre": Vector3(0,0,6), "start": Vector3(0,0,3), "end": Vector3(0,0,9)}
	var holes := [_hole(6.4, 0.5, 1), _hole(3.8, 2, 2)]
	var paired: Dictionary = module._pair([bore], holes, {"dia_mm":3}, {})
	check("adjacent coaxial steps pair once to the clearance step", paired["pairs"].size() == 1 and paired["pairs"][0]["hole"]["dia_mm"] == 3.8 and paired["unpaired"]["reference_holes"].is_empty())
	var separated := [_hole(6.4, -0.5, 1), _hole(3.8, 2, 2)]
	paired = module._pair([bore], separated, {"dia_mm":3}, {})
	check("an axial air gap leaves separate mounting locations", paired["unpaired"]["reference_holes"].size() == 1)
	var other: Array = holes.duplicate(true)
	other[0]["node"] = "other"
	paired = module._pair([bore], other, {"dia_mm":3}, {})
	check("different nodes never collapse", paired["unpaired"]["reference_holes"].size() == 1)
	paired = module._pair([bore], holes, {"dia_mm":3}, {"pairs":[{"solid_feature":0,"reference_hole":0}]})
	check("explicit hole indices retain their original meaning", paired["pairs"][0]["hole"]["dia_mm"] == 6.4)
	var gauge = Gauge.new()
	root.add_child(gauge)
	# Profile is revolved about Z. The counterbore floor is z=1, with 2 mm
	# of bearing material; mesh vertices are metres, just as in GLB.
	var flat := [Vector2(6,0), Vector2(3.2,0), Vector2(3.2,1), Vector2(1.9,1), Vector2(1.9,3), Vector2(6,3)]
	var report := await _support(gauge, module, flat, 1.0, {})
	check("metre-scale counterbore lands every flat-seat ray", report["landed"] == report["rays"] and report["rays"] > 0)
	check("flat seat has near-zero gap", absf(float(report["gap_mm"])) < 0.001)
	report = await _support(gauge, module, flat, 0.7, {})
	check("a genuinely recessed floor is unsupported", report["landed"] == 0 and absf(float(report["gap_mm"]) - 0.3) < 0.001)
	var cone := [Vector2(6,0), Vector2(3,0), Vector2(1.9,1.1), Vector2(1.9,3), Vector2(6,3)]
	var head := {"head_kind":"countersunk", "head_angle_deg":90, "dia_mm":3}
	report = await _support(gauge, module, cone, 0.0, head)
	check("90-degree countersink matches both head-profile rings", report["landed"] == report["rays"] and report["rays"] > 29)
	report = await _support(gauge, module, cone, 0.0, {})
	check("the same cone does not support a flat head on its top plane", report["landed"] == 0)
	report = await _support(gauge, module, flat, 0.0, head)
	check("a flat shelf cannot masquerade as a cone", report["landed"] < report["rays"])
	var solid = Geometry.new()
	var solid_host := Node3D.new()
	root.add_child(solid_host)
	solid.attach(solid_host)
	await process_frame
	var tube := _revolve([Vector2(4,4),Vector2(1.25,4),Vector2(1.25,10),Vector2(4,10)])
	var vertices: Array = []
	var faces: Array = []
	for point in tube.get_faces():
		vertices.append([point.x*1000,point.y*1000,point.z*1000])
	for i in range(0,vertices.size(),3):
		faces.append([i,i+1,i+2])
	solid.build_solid({"vertices":vertices,"faces":faces})
	await _support(gauge,module,cone,0.0,head)
	var hole := _hole(3.8,2.05,1.9)
	var pair := {"bore":bore,"hole":hole,"hole_axis":Vector3(0,0,1),"hole_centre":Vector3(0,0,2.05),"bore_axis":Vector3(0,0,1),"bore_start":Vector3(0,0,4),"bore_end":Vector3(0,0,10),"fit":"thread"}
	var screw := {"dia_mm":3,"head_dia_mm":6,"length_mm":8,"head_kind":"countersunk","head_angle_deg":90,"seat":"reference"}
	var row: Dictionary = module._one_screw(gauge,gauge.space_state(),solid.solid_space(),solid,pair,screw,{"engagement_min_d":1},gauge.mask_for("door"),"door",20,[])
	if not row.get("pass",false):
		print("COUNTERSUNK ROW ", row)
	check("a complete countersunk joint passes with a supported seat at z=0", row.get("pass",false) and row.get("seat_kind") == "countersunk" and row.get("head_seat_supported",0.0) == 1.0 and absf(row["seat_mm"]["world"][2]) < 0.001)
	await _support(gauge,module,flat,0.0,{})
	screw["head_kind"] = "flat"
	screw["seat"] = "offset"
	screw["seat_offset_mm"] = -2.05
	row = module._one_screw(gauge,gauge.space_state(),solid.solid_space(),solid,pair,screw,{"engagement_min_d":1},gauge.mask_for("door"),"door",20,[])
	check("an unsupported head fails even when the path and engagement clear", not row.get("pass",true) and row.get("head_seat_clear",false) and row.get("engagement_ok",false) and not row.get("head_support_ok",true))
	solid_host.queue_free()
	gauge.queue_free()
	await process_frame
	print("=== Results: %d passed, %d failed ===" % [passed,failed])
	quit(1 if failed else 0)

func _hole(dia: float, z: float, depth: float) -> Dictionary:
	return {"dia_mm":dia,"center_mm":{"world":[0,0,z]},"axis":{"world":[0,0,1]},"extent_mm":depth,"depth_mm":depth,"reference":"door","node":"door"}

func _support(gauge: Node, module: RefCounted, profile: Array, plane: float, head: Dictionary) -> Dictionary:
	var mesh := _revolve(profile)
	gauge.build([{"mesh":mesh,"transform":Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 1000),Vector3.ZERO),"reference":"door","node":"door"}], str(profile))
	await physics_frame
	await physics_frame
	return module._seat_support(gauge,gauge.space_state(),null,null,Vector3(0,0,-20),Vector3(0,0,1),3.0,1.5,plane,Vector3.ZERO,gauge.mask_for("door"),"door",false,head)

func _revolve(profile: Array) -> ArrayMesh:
	var vertices := PackedVector3Array()
	for i in range(profile.size()):
		var p: Vector2 = profile[i]
		var q: Vector2 = profile[(i+1)%profile.size()]
		for j in range(128):
			var a := TAU * j / 128.0
			var b := TAU * (j+1) / 128.0
			var corners := [Vector3(p.x*cos(a),p.x*sin(a),p.y),Vector3(p.x*cos(b),p.x*sin(b),p.y),Vector3(q.x*cos(b),q.x*sin(b),q.y),Vector3(q.x*cos(a),q.x*sin(a),q.y)]
			for k in [0,1,2,0,2,3]:
				vertices.append(corners[k] * 0.001)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

extends RefCounted
## One frozen package job per panel, reusing the worker's explicit export jobs.
const Files := preload("package_files.gd")
const Assembly := preload("assembly_export.gd")
const Evaluation := preload("evaluation_state.gd")
const Reply := preload("worker_reply.gd")
const META := "cad_package_export"
const Note := preload("cad_note.gd")

static func handle(panel: Node, args: Dictionary) -> Dictionary:
	var action := str(args.get("action", "start"))
	if action == "restore_view":
		var source_path := str(panel.get_document_state().get("path", ""))
		var file := FileAccess.open(source_path + Files.SUFFIX, FileAccess.READ)
		if file == null or file.get_length() > 4 * 1024 * 1024:
			return {"success": false, "error": "No readable CAD package recipe beside this document"}
		var parsed := JSON.new()
		if parsed.parse(file.get_as_text()) != OK or not parsed.data is Dictionary or parsed.data.get("schema") != Files.SCHEMA:
			return {"success": false, "error": "Invalid CAD package recipe"}
		var manifest: Dictionary = parsed.data
		var cameras = manifest.get("cameras", {})
		var recipe = manifest.get("recipe", {})
		if not cameras is Dictionary or not recipe is Dictionary:
			return {"success": false, "error": "Invalid package camera or configuration data"}
		var shown: Dictionary = panel._model_views.handle({"action": "show", "configuration": recipe.get("configuration", ""), "selection": ""})
		if shown.get("success", false):
			panel.set_meta(Note.PENDING_CAMERA_META, cameras)
			Note.apply_cameras(panel, cameras)
		return shown
	var job: Dictionary = panel.get_meta(META, {})
	if action in ["collect", "cancel"]:
		if job.is_empty() or str(args.get("ticket", "")) != str(job.ticket):
			return {"success": false, "error": "Unknown CAD package ticket"}
		if action == "cancel":
			job.cancelled = true
		return await _wait(panel, job, args)
	if action != "start":
		return {"success": false, "error": "action must be start, collect, cancel or restore_view"}
	if not job.is_empty() and job.reply.is_empty():
		return await _wait(panel, job, args)
	var before := Evaluation.preflight(panel, args, true)
	if not before.get("success", false):
		return before
	var path := str(args.get("path", "")).simplify_path()
	if not path.is_absolute_path() or DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(path):
		return {"success": false, "error": "Choose an absolute path for a new package directory"}
	var configuration := str(args.get("configuration", before.document.get("model", {}).get("configuration", "")))
	var key := JSON.stringify([path, before.document.get("source", ""), configuration]).sha256_text()
	job = {"ticket": "package-" + key.left(24), "reply": {}, "cancelled": false,
		"path": path, "configuration": configuration, "deadline": Time.get_ticks_msec() + 900000, "phase": "freezing", "document": before.document.duplicate(true), "cameras": Note.cameras_of(panel)}
	panel.set_meta(META, job)
	_execute(panel, job)
	return await _wait(panel, job, args)

static func _wait(panel: Node, job: Dictionary, args: Dictionary) -> Dictionary:
	var deadline := Time.get_ticks_msec() + clampi(int(args.get("wait_ms", 1000)), 0, 20000)
	while job.reply.is_empty() and Time.get_ticks_msec() < deadline:
		await panel.get_tree().process_frame
	if not job.reply.is_empty():
		return job.reply
	return {"success": true, "status": "running", "ticket": job.ticket, "phase": job.phase,
		"artifact_provenance": job.document.get("provenance", {})}

static func _execute(panel: Node, job: Dictionary) -> void:
	var stage: String = job.path + ".staging-" + str(Time.get_ticks_usec())
	var result := await _build(panel, job, stage)
	if result.has("error"):
		job.reply = {"success": false, "status": "failed", "error": result.error, "staging_path": stage}
		return
	if DirAccess.dir_exists_absolute(job.path) or FileAccess.file_exists(job.path):
		job.reply = {"success": false, "status": "failed", "error": "Package destination appeared during export", "staging_path": stage}
		return
	var error := DirAccess.rename_absolute(stage, job.path)
	if error != OK:
		job.reply = {"success": false, "status": "failed", "error": "Cannot publish package: " + error_string(error), "staging_path": stage}
		return
	job.reply = {"success": true, "status": "completed", "path": job.path,
		"source_path": str(job.path).path_join("model.mcad"), "manifest": str(job.path).path_join("model.mcad" + Files.SUFFIX),
		"assembly": str(job.path).path_join("assembly.glb"), "artifact_provenance": job.document.get("provenance", {}),
		"configuration": job.configuration, "source_digest": str(job.document.source).sha256_text(),
		"historical": panel.evaluation_freshness().get("stale", false) or panel.get_evaluation_state().get("provenance", {}) != job.document.get("provenance", {})}

static func _build(panel: Node, job: Dictionary, stage: String) -> Dictionary:
	var source: String = job.document.get("source", "")
	var source_path: String = job.document.get("path", "")
	var evaluated := Reply.unwrap(await panel.call_backend("cad.evaluate", {
		"source": source, "configuration": job.configuration, "summary": true}, 600000), "package model")
	if evaluated.has("error"):
		return evaluated
	var library = panel._reference_library.fork()
	library.refresh_stamps()
	for dependency: String in job.document.get("dependencies", {}):
		if library.file_stamp(dependency) != str(job.document.dependencies[dependency]):
			return {"error": "A painted dependency changed before export: " + dependency}
	var frozen := Files.freeze(library, evaluated.get("model", {}).get("dependencies", evaluated.get("references", [])), source_path, stage)
	if frozen.has("error"):
		return frozen
	library.refresh_stamps()
	for dependency: String in job.document.get("dependencies", {}):
		if library.file_stamp(dependency) != str(job.document.dependencies[dependency]):
			return {"error": "A painted dependency changed while freezing: " + dependency}
	var manifest := {"schema": Files.SCHEMA, "source": "model.mcad", "source_sha256": source.sha256_text(),
		"paths": frozen.paths, "files": frozen.files, "model": evaluated.get("model", {}),
		"source_provenance": job.document.get("provenance", {}), "evaluation_provenance": evaluated.get("provenance", {}), "cameras": job.cameras,
		"annotations": evaluated.get("annotations", []),
		"recipe": {"tool": "minerva_cad_package", "configuration": job.configuration, "selection": "",
			"units": "mm", "up": "z", "solid_tessellation_mm": 0.1, "solid_angular_tolerance": 0.1},
		"reproducibility": "Source, dependency bytes, instance identities and world transforms are retained. Rebuilds use the installed geometry kernel; third-party output bytes are not guaranteed identical."}
	var error := Files.write_bytes(stage.path_join("model.mcad"), source.to_utf8_buffer())
	if error.is_empty():
		error = _write_manifest(stage, manifest)
	if not error.is_empty():
		return {"error": error}
	if not source_path.is_empty() and FileAccess.file_exists(source_path + ".checks.json"):
		var requirements := FileAccess.open(source_path + ".checks.json", FileAccess.READ)
		if requirements == null or requirements.get_length() > preload("validation_spec.gd").MAX_BYTES:
			return {"error": "Cannot copy validation specification, or it exceeds 256 KiB"}
		var requirement_path := stage.path_join("model.mcad.checks.json")
		error = Files.write_bytes(requirement_path, requirements.get_buffer(requirements.get_length()))
		if not error.is_empty():
			return {"error": error}
		manifest.files["model.mcad.checks.json"] = {"sha256": FileAccess.get_sha256(requirement_path)}
	job.phase = "exporting definitions"
	var definitions: Dictionary = {}
	var declared: Array = evaluated.get("model", {}).get("definitions", [])
	if declared.is_empty() and evaluated.get("body_count", 0) > 0:
		declared = [{"id": "_solid", "kind": "solid"}]
	if declared.size() > 128:
		return {"error": "Package exceeds 128 geometry definitions; export a smaller configuration"}
	for definition: Dictionary in declared:
		if definition.get("kind") != "solid":
			continue
		if job.cancelled:
			return {"error": "Package cancelled; staged files were not published"}
		var id := str(definition.id)
		var path := stage.path_join("definitions/" + id.sha256_text() + ".glb")
		var selection := "definition:" + id if id != "_solid" else ""
		var exported := Reply.unwrap(await panel.call_backend("cad.export", {
			"source": source, "configuration": job.configuration, "selection": selection,
			"format": "glb", "path": path, "wait_ms": 0}, 30000), "package definition")
		var deadline: int = job.deadline
		while exported.get("status") == "pending" and Time.get_ticks_msec() < deadline:
			exported = Reply.unwrap(await panel.call_backend("cad.export", {"job_id": exported.get("job_id", ""), "wait_ms": 1000}, 30000), "package definition")
		if exported.has("error") or exported.get("status") == "pending":
			return {"error": exported.get("error", "Definition export exceeded 15 minutes")}
		definitions[id] = path
	if job.cancelled:
		return {"error": "Package cancelled; staged files were not published"}
	job.phase = "assembling glTF"
	var assembly := Assembly.write(library, evaluated, definitions, stage)
	if assembly.has("error"):
		return assembly
	manifest["assembly_export"] = assembly
	manifest["files"]["assembly.glb"] = {"sha256": FileAccess.get_sha256(stage.path_join("assembly.glb"))}
	for id in definitions:
		var path: String = definitions[id]
		manifest.files[path.trim_prefix(stage + "/")] = {"sha256": FileAccess.get_sha256(path)}
	error = _write_manifest(stage, manifest)
	return {"error": error} if not error.is_empty() else manifest


static func _write_manifest(stage: String, manifest: Dictionary) -> String:
	var bytes := JSON.stringify(manifest, "\t", true).to_utf8_buffer()
	if bytes.size() > 4 * 1024 * 1024:
		return "Package metadata exceeds 4 MiB"
	return Files.write_bytes(stage.path_join("model.mcad" + Files.SUFFIX), bytes)

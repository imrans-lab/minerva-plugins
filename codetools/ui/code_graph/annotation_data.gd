extends RefCounted
## Off-tree plugin script: NO class_name
## Annotation data model inspired by Minerva's PCBAnnotation.
## Stores code annotations anchored to line numbers.

enum Type { TEXT, REGION, ARROW }

var annotations: Array[Dictionary] = []
var _next_id := 1
var file_path: String = ""


func add_text(file: String, line: int, text: String, author: String = "human",
		symbol_id: String = "", boundary_name: String = "") -> Dictionary:
	var ann := {
		"id": "ann_%04d" % _next_id,
		"type": Type.TEXT,
		"file": file,
		"line_start": line,
		"line_end": line,
		"text": text,
		"author": author,
		"created_at": Time.get_unix_time_from_system(),
		"symbol_id": symbol_id,
		"boundary_name": boundary_name,
		"panel_x": -1.0,
		"panel_y": -1.0,
	}
	_next_id += 1
	annotations.append(ann)
	return ann


func add_region(file: String, line_start: int, line_end: int, text: String, author: String = "human",
		symbol_id: String = "", boundary_name: String = "") -> Dictionary:
	var ann := {
		"id": "ann_%04d" % _next_id,
		"type": Type.REGION,
		"file": file,
		"line_start": line_start,
		"line_end": line_end,
		"text": text,
		"author": author,
		"created_at": Time.get_unix_time_from_system(),
		"symbol_id": symbol_id,
		"boundary_name": boundary_name,
		"panel_x": -1.0,
		"panel_y": -1.0,
	}
	_next_id += 1
	annotations.append(ann)
	return ann


func add_arrow(file: String, from_line: int, to_line: int, text: String, author: String = "human",
		symbol_id: String = "", boundary_name: String = "") -> Dictionary:
	var ann := {
		"id": "ann_%04d" % _next_id,
		"type": Type.ARROW,
		"file": file,
		"line_start": from_line,
		"line_end": to_line,
		"text": text,
		"author": author,
		"created_at": Time.get_unix_time_from_system(),
		"symbol_id": symbol_id,
		"boundary_name": boundary_name,
		"panel_x": -1.0,
		"panel_y": -1.0,
	}
	_next_id += 1
	annotations.append(ann)
	return ann


func remove(ann_id: String) -> void:
	annotations = annotations.filter(func(a: Dictionary) -> bool: return str(a.id) != ann_id)


func get_for_file(file: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for ann: Dictionary in annotations:
		if str(ann.file) == file:
			result.append(ann)
	return result


func get_for_line_range(file: String, start: int, end: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for ann: Dictionary in annotations:
		if str(ann.file) != file:
			continue
		if int(ann.line_start) <= end and int(ann.line_end) >= start:
			result.append(ann)
	return result


func save_to_file(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return false
	var data: Array = []
	for ann: Dictionary in annotations:
		data.append(ann.duplicate())
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


func load_from_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return false
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	if err != OK:
		return false
	annotations.clear()
	for ann in json.data:
		annotations.append(ann)
		var ann_num: int = str(ann.id).substr(4).to_int()
		if ann_num >= _next_id:
			_next_id = ann_num + 1
	return true

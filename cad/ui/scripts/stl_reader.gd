## stl_reader.gd — parsing an STL file into the {mesh, transform} rows the
## reference library works in.
##
## STL is the format every mesh tool can write and the one this plugin's own
## cad_export has always produced, so a stand-in exported from the DSL has to be
## mountable again. It is also the format that says the least: no units, no
## up-axis, no node names, no shared vertices. What follows from that:
##
##   UNITS      the file cannot say. The caller decides — the library defaults
##             an STL to millimetres and Z-up and warns when the source did not
##             pass units=, because a wrong guess is a silent 25.4x.
##   ONE PART   an STL is a single triangle soup. The part is named after the
##             ASCII header's solid name when it has one, else the file's stem,
##             so a measurement can still be reported against a name.
##   NO INDICES triangles are emitted as loose vertices, which is what the STL
##             holds. The feature-edge pass already welds by position, so the
##             outlines come out the same as an indexed mesh's.
##
## Both encodings are read. The binary/ASCII decision is made from the length:
## a binary STL is exactly 84 + 50 * triangle_count bytes, and that arithmetic
## is the only reliable test — plenty of binary STLs start with the bytes
## "solid" because the writer left the header blank.
extends RefCounted

## Bytes before the triangle records in a binary STL: an 80-byte free-form
## header plus the uint32 triangle count.
const BINARY_HEADER_BYTES: int = 84
## Bytes per binary triangle record: 4 vectors of 3 floats plus the attribute
## byte count.
const BINARY_TRIANGLE_BYTES: int = 50


## Read `absolute_path` and return [{mesh, transform, node, node_path}] in the
## file's own frame, or [] with `error`/`status` set on `loaded`.
##
## `loaded` and `library` are the reference library's own types, held untyped
## because typing them would mean preloading the library that preloads this.
static func read_parts(absolute_path: String, loaded: Variant, library: Variant) -> Array:
	var handle := FileAccess.open(absolute_path, FileAccess.READ)
	if handle == null:
		loaded.status = library.STATUS_UNREADABLE
		loaded.error = "could not open STL '%s' (error %d)" % [
			absolute_path, FileAccess.get_open_error(),
		]
		return []
	var bytes := handle.get_buffer(handle.get_length())
	handle.close()

	var triangles := PackedVector3Array()
	var solid_name := ""
	if _is_binary(bytes):
		triangles = _read_binary(bytes)
	else:
		var text := bytes.get_string_from_utf8()
		solid_name = _ascii_solid_name(text)
		triangles = _read_ascii(text)

	if triangles.is_empty():
		loaded.status = library.STATUS_EMPTY
		loaded.error = "STL '%s' holds no triangles" % absolute_path
		return []

	var node_name := solid_name if not solid_name.is_empty() \
			else absolute_path.get_file().get_basename()
	return [{
		"mesh": _mesh_from_triangles(triangles),
		"transform": Transform3D.IDENTITY,
		"node": node_name,
		"node_path": node_name,
	}]


## True when the length matches the binary layout exactly. Content sniffing
## ("does it start with 'solid'?") gets this wrong on binary files whose header
## was left as text; the length cannot be faked.
static func _is_binary(bytes: PackedByteArray) -> bool:
	if bytes.size() < BINARY_HEADER_BYTES:
		return false
	var count := bytes.decode_u32(80)
	return bytes.size() == BINARY_HEADER_BYTES + count * BINARY_TRIANGLE_BYTES


static func _read_binary(bytes: PackedByteArray) -> PackedVector3Array:
	var count := bytes.decode_u32(80)
	var out := PackedVector3Array()
	out.resize(count * 3)
	var write := 0
	for i in range(count):
		# The record is normal, v0, v1, v2 as 12 little-endian floats; the
		# normal is dropped and recomputed, because STL writers disagree about
		# its winding and a wrong one shades the part inside out.
		var base := BINARY_HEADER_BYTES + i * BINARY_TRIANGLE_BYTES
		var floats := bytes.slice(base, base + 48).to_float32_array()
		if floats.size() < 12:
			break
		for corner in range(3):
			var f := 3 + corner * 3
			out[write] = Vector3(floats[f], floats[f + 1], floats[f + 2])
			write += 1
	if write < out.size():
		out.resize(write)
	return out


static func _ascii_solid_name(text: String) -> String:
	var first := text.strip_edges().split("\n", false, 1)
	if first.is_empty():
		return ""
	var head: String = first[0].strip_edges()
	if not head.begins_with("solid"):
		return ""
	return head.substr(5).strip_edges()


static func _read_ascii(text: String) -> PackedVector3Array:
	var out := PackedVector3Array()
	for raw_line in text.split("\n", false):
		var line: String = (raw_line as String).strip_edges()
		if not line.begins_with("vertex"):
			continue
		var parts := line.split(" ", false)
		if parts.size() < 4:
			continue
		out.append(Vector3(
			float(parts[1]),
			float(parts[2]),
			float(parts[3])
		))
	# A trailing partial triangle is a truncated file; drop it rather than
	# emitting a degenerate face.
	var whole := (out.size() / 3) * 3
	if whole < out.size():
		out.resize(whole)
	return out


## Loose triangles into an ArrayMesh with flat per-face normals.
static func _mesh_from_triangles(triangles: PackedVector3Array) -> ArrayMesh:
	var normals := PackedVector3Array()
	normals.resize(triangles.size())
	for i in range(0, triangles.size(), 3):
		var normal := (triangles[i + 1] - triangles[i]).cross(
				triangles[i + 2] - triangles[i]).normalized()
		normals[i] = normal
		normals[i + 1] = normal
		normals[i + 2] = normal

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = triangles
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

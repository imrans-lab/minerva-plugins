class_name Sheets_ExcelHandler
extends RefCounted
## Handles Excel .xlsx file import/export.
## Excel files are ZIP archives containing XML files.

const Atomic := preload("res://Scripts/Services/Plugins/AtomicFile.gd")
const SpreadsheetDataScript := preload("SpreadsheetData.gd")
const SpreadsheetCellScript := preload("SpreadsheetCell.gd")


## Import Excel .xlsx file into SpreadsheetData
static func import_xlsx(path: String, data: SpreadsheetDataScript) -> Error:
	var zip := ZIPReader.new()
	var err := zip.open(path)
	if err != OK:
		return err

	# Parse shared strings (string table used by cells)
	var shared_strings: PackedStringArray = []
	if zip.file_exists("xl/sharedStrings.xml"):
		var strings_xml := zip.read_file("xl/sharedStrings.xml").get_string_from_utf8()
		shared_strings = _parse_shared_strings(strings_xml)

	# Parse the first worksheet
	var sheet_path := "xl/worksheets/sheet1.xml"
	if not zip.file_exists(sheet_path):
		zip.close()
		return ERR_FILE_NOT_FOUND

	var sheet_xml := zip.read_file(sheet_path).get_string_from_utf8()
	zip.close()

	_parse_sheet(sheet_xml, shared_strings, data)
	return OK


## Export SpreadsheetData to Excel .xlsx file
static func export_xlsx(path: String, data: SpreadsheetDataScript) -> Error:
	var zip := ZIPPacker.new()
	var temporary := path + ".zip.tmp"
	var err := zip.open(temporary)
	if err != OK:
		return err

	# Generate shared strings from all cell values
	var shared_strings: PackedStringArray = []
	var string_indices: Dictionary = {}  # value -> index

	for row in range(data.row_count):
		for col in range(data.column_count):
			var cell := data.get_cell_if_exists(row, col)
			if cell and cell.type == SpreadsheetCellScript.CellType.TEXT:
				var val := str(cell.value)
				if not val in string_indices:
					string_indices[val] = shared_strings.size()
					shared_strings.append(val)

	var parts: Dictionary[String, String] = {
		"[Content_Types].xml": _generate_content_types(),
		"_rels/.rels": _generate_rels(),
		"xl/workbook.xml": _generate_workbook(),
		"xl/_rels/workbook.xml.rels": _generate_workbook_rels(),
	}
	if shared_strings.size() > 0:
		parts["xl/sharedStrings.xml"] = _generate_shared_strings(shared_strings)
	parts["xl/styles.xml"] = _generate_styles()
	parts["xl/worksheets/sheet1.xml"] = _generate_sheet(data, string_indices)
	for name: String in parts:
		err = zip.start_file(name)
		if err == OK:
			var text: String = parts[name]
			err = zip.write_file(text.to_utf8_buffer())
		if err != OK:
			break
	var closed: Error = zip.close()
	if err == OK:
		err = closed
	if err == OK:
		err = _publish_archive(path, temporary, parts)
	DirAccess.remove_absolute(temporary)
	return err


## Godot's ZIP callbacks can report success after a failed write. Verify the
## exact staged archive we will publish, including ZIPReader's CRC checks.
static func _publish_archive(path: String, temporary: String, parts: Dictionary[String, String]) -> Error:
	var input := FileAccess.open(temporary, FileAccess.READ)
	if input == null:
		return FileAccess.get_open_error()
	var bytes := input.get_buffer(input.get_length())
	var err := input.get_error()
	input.close()
	if err == OK and not Atomic.prepare_bytes(path, bytes):
		err = ERR_CANT_CREATE
	if err == OK:
		var reader := ZIPReader.new()
		if reader.open(path + ".tmp") != OK:
			err = ERR_FILE_CORRUPT
		else:
			if reader.get_files().size() != parts.size():
				err = ERR_FILE_CORRUPT
			for name: String in parts:
				if not reader.file_exists(name) or reader.read_file(name) != parts[name].to_utf8_buffer():
					err = ERR_FILE_CORRUPT
					break
			var closed: Error = reader.close()
			if err == OK:
				err = closed
	if err == OK and not Atomic.replace(path + ".tmp", path):
		err = ERR_CANT_CREATE
	if err != OK and FileAccess.file_exists(path + ".tmp"):
		DirAccess.remove_absolute(path + ".tmp")
	return err


## Parse shared strings XML
static func _parse_shared_strings(xml: String) -> PackedStringArray:
	var strings: PackedStringArray = []
	var parser := XMLParser.new()
	parser.open_buffer(xml.to_utf8_buffer())

	var in_si := false
	var in_t := false
	var current_string := ""

	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var name := parser.get_node_name()
				if name == "si":
					in_si = true
					current_string = ""
				elif name == "t" and in_si:
					in_t = true
			XMLParser.NODE_TEXT:
				if in_t:
					current_string += parser.get_node_data()
			XMLParser.NODE_ELEMENT_END:
				var name := parser.get_node_name()
				if name == "t":
					in_t = false
				elif name == "si":
					strings.append(current_string)
					in_si = false

	return strings


## Parse worksheet XML
static func _parse_sheet(xml: String, shared_strings: PackedStringArray, data: SpreadsheetDataScript) -> void:
	data.clear()

	var parser := XMLParser.new()
	parser.open_buffer(xml.to_utf8_buffer())

	var current_row := -1
	var current_col := -1
	var cell_type := ""
	var cell_ref := ""
	var in_value := false
	var in_formula := false
	var value_text := ""
	var formula_text := ""

	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var name := parser.get_node_name()
				if name == "row":
					current_row = parser.get_named_attribute_value_safe("r").to_int() - 1
				elif name == "c":
					cell_ref = parser.get_named_attribute_value_safe("r")
					cell_type = parser.get_named_attribute_value_safe("t")
					current_col = _cell_ref_to_col(cell_ref)
					value_text = ""
					formula_text = ""
				elif name == "v":
					in_value = true
				elif name == "f":
					in_formula = true
			XMLParser.NODE_TEXT:
				if in_value:
					value_text += parser.get_node_data()
				elif in_formula:
					formula_text += parser.get_node_data()
			XMLParser.NODE_ELEMENT_END:
				var name := parser.get_node_name()
				if name == "v":
					in_value = false
				elif name == "f":
					in_formula = false
				elif name == "c":
					# Process the cell
					if current_row >= 0 and current_col >= 0:
						_set_cell_from_excel(data, current_row, current_col, cell_type, value_text, formula_text, shared_strings)
					current_col = -1
					cell_type = ""


## Convert cell reference (e.g., "A1", "BC42") to column index
static func _cell_ref_to_col(ref: String) -> int:
	var col := 0
	for i in range(ref.length()):
		var c := ref[i]
		if c >= 'A' and c <= 'Z':
			col = col * 26 + (c.unicode_at(0) - 'A'.unicode_at(0) + 1)
		elif c >= 'a' and c <= 'z':
			col = col * 26 + (c.unicode_at(0) - 'a'.unicode_at(0) + 1)
		else:
			break
	return col - 1


## Set cell value from Excel data
static func _set_cell_from_excel(data: SpreadsheetDataScript, row: int, col: int, cell_type: String, value: String, formula: String, shared_strings: PackedStringArray) -> void:
	if not formula.is_empty():
		data.set_cell_value(row, col, "=" + formula)
	elif cell_type == "s":
		# Shared string
		var idx := value.to_int()
		if idx >= 0 and idx < shared_strings.size():
			data.set_cell_value(row, col, shared_strings[idx])
	elif cell_type == "b":
		# Boolean
		data.set_cell_value(row, col, value == "1")
	elif cell_type == "e":
		# Error
		data.set_cell_value(row, col, "#ERROR!")
	else:
		# Number or inline string
		if value.is_valid_float():
			data.set_cell_value(row, col, value.to_float())
		elif value.is_valid_int():
			data.set_cell_value(row, col, value.to_int())
		else:
			data.set_cell_value(row, col, value)


## Generate [Content_Types].xml
static func _generate_content_types() -> String:
	return """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>"""


## Generate _rels/.rels
static func _generate_rels() -> String:
	return """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>"""


## Generate xl/workbook.xml
static func _generate_workbook() -> String:
	return """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>
<sheet name="Sheet1" sheetId="1" r:id="rId1"/>
</sheets>
</workbook>"""


## Generate xl/_rels/workbook.xml.rels
static func _generate_workbook_rels() -> String:
	return """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>"""


## Generate xl/sharedStrings.xml
static func _generate_shared_strings(strings: PackedStringArray) -> String:
	var fragments := PackedStringArray(["""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="%d" uniqueCount="%d">
""" % [strings.size(), strings.size()]])

	for s in strings:
		fragments.append("<si><t>%s</t></si>\n" % _escape_xml(s))

	fragments.append("</sst>")
	return "".join(fragments)


## Generate xl/styles.xml (minimal)
static func _generate_styles() -> String:
	return """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="1">
<font><sz val="11"/><name val="Calibri"/></font>
</fonts>
<fills count="2">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
</fills>
<borders count="1">
<border><left/><right/><top/><bottom/><diagonal/></border>
</borders>
<cellStyleXfs count="1">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
</cellStyleXfs>
<cellXfs count="1">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
</cellXfs>
</styleSheet>"""


## Generate xl/worksheets/sheet1.xml
static func _generate_sheet(data: SpreadsheetDataScript, string_indices: Dictionary) -> String:
	var fragments := PackedStringArray(["""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData>
"""])

	# Find actual data bounds
	var max_row := 0
	var max_col := 0
	for key in data.cells.keys():
		var cell: RefCounted = data.cells[key]
		if cell.type != SpreadsheetCellScript.CellType.EMPTY:
			var parts: PackedStringArray = key.split(",")
			max_row = maxi(max_row, parts[0].to_int() + 1)
			max_col = maxi(max_col, parts[1].to_int() + 1)

	for row in range(max_row):
		fragments.append("<row r=\"%d\">\n" % (row + 1))

		for col in range(max_col):
			var cell := data.get_cell_if_exists(row, col)
			if cell and cell.type != SpreadsheetCellScript.CellType.EMPTY:
				var ref := SpreadsheetDataScript.get_column_label(col) + str(row + 1)
				fragments.append(_generate_cell_xml(ref, cell, string_indices))

		fragments.append("</row>\n")

	fragments.append("""</sheetData>
</worksheet>""")
	return "".join(fragments)


## Generate XML for a single cell
static func _generate_cell_xml(ref: String, cell: RefCounted, string_indices: Dictionary) -> String:
	var xml := "<c r=\"%s\"" % ref

	if cell.type == SpreadsheetCellScript.CellType.FORMULA:
		xml += ">"
		var formula_text: String = cell.formula.substr(1) if cell.formula.begins_with("=") else cell.formula
		xml += "<f>%s</f>" % _escape_xml(formula_text)
		if cell.value != null:
			xml += "<v>%s</v>" % str(cell.value)
		xml += "</c>\n"
	elif cell.type == SpreadsheetCellScript.CellType.TEXT:
		var val := str(cell.value)
		if val in string_indices:
			xml += " t=\"s\"><v>%d</v></c>\n" % string_indices[val]
		else:
			xml += " t=\"inlineStr\"><is><t>%s</t></is></c>\n" % _escape_xml(val)
	elif cell.type == SpreadsheetCellScript.CellType.NUMBER:
		xml += "><v>%s</v></c>\n" % str(cell.value)
	elif cell.type == SpreadsheetCellScript.CellType.DATE:
		# Excel stores dates as numbers (days since 1900-01-01)
		xml += "><v>%s</v></c>\n" % str(cell.value)
	else:
		xml += "/>\n"

	return xml


## Escape special XML characters
static func _escape_xml(text: String) -> String:
	text = text.replace("&", "&amp;")
	text = text.replace("<", "&lt;")
	text = text.replace(">", "&gt;")
	text = text.replace("\"", "&quot;")
	text = text.replace("'", "&apos;")
	return text

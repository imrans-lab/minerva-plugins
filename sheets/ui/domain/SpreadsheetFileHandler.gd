class_name Sheets_SpreadsheetFileHandler
extends RefCounted
## Handles file import/export for spreadsheets (CSV, TSV, native format).

const SpreadsheetDataScript := preload("SpreadsheetData.gd")
const ExcelHandlerScript := preload("ExcelHandler.gd")
const Atomic := preload("res://Scripts/Services/Plugins/AtomicFile.gd")


## Import CSV file into SpreadsheetData
static func import_csv(path: String, data: SpreadsheetDataScript) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return FileAccess.get_open_error()

	var content := file.get_as_text()
	file.close()

	data.from_csv(content, ",")
	return OK


## Export SpreadsheetData to CSV file
static func export_csv(path: String, data: SpreadsheetDataScript) -> Error:
	return OK if Atomic.write(path, data.to_csv(",")) else ERR_CANT_CREATE


## Import TSV file into SpreadsheetData
static func import_tsv(path: String, data: SpreadsheetDataScript) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return FileAccess.get_open_error()

	var content := file.get_as_text()
	file.close()

	data.from_csv(content, "\t")
	return OK


## Export SpreadsheetData to TSV file
static func export_tsv(path: String, data: SpreadsheetDataScript) -> Error:
	return OK if Atomic.write(path, data.to_csv("\t")) else ERR_CANT_CREATE


## Import native JSON format (.minsheet)
static func import_minsheet(path: String, data: SpreadsheetDataScript) -> Error:
	var document: Dictionary = {}
	var result: Error = read_minsheet(path, document)
	if result == OK:
		data.load_from_dict(document)
	return result


## Read once for both data-only callers and the editor's full document restore.
static func read_minsheet(path: String, document: Dictionary) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return FileAccess.get_open_error()

	var content := file.get_as_text()
	file.close()

	var json := JSON.new()
	var parse_result := json.parse(content)
	if parse_result != OK:
		return parse_result

	var dict: Variant = json.data
	if not dict is Dictionary:
		return ERR_INVALID_DATA

	document.merge(dict, true)
	return OK


## Export SpreadsheetData to native JSON format (.minsheet)
static func export_minsheet(path: String, data: SpreadsheetDataScript) -> Error:
	return OK if Atomic.write(path, JSON.stringify(data.to_dict(), "\t")) else ERR_CANT_CREATE


## Detect file type from extension and import
static func import_file(path: String, data: SpreadsheetDataScript) -> Error:
	var ext := path.get_extension().to_lower()

	match ext:
		"csv":
			return import_csv(path, data)
		"tsv":
			return import_tsv(path, data)
		"minsheet":
			return import_minsheet(path, data)
		"xlsx":
			return ExcelHandlerScript.import_xlsx(path, data)
		_:
			# Try CSV as default
			return import_csv(path, data)


## Detect file type from extension and export
static func export_file(path: String, data: SpreadsheetDataScript) -> Error:
	var ext := path.get_extension().to_lower()

	match ext:
		"csv":
			return export_csv(path, data)
		"tsv":
			return export_tsv(path, data)
		"minsheet":
			return export_minsheet(path, data)
		"xlsx":
			return ExcelHandlerScript.export_xlsx(path, data)
		_:
			# Default to CSV
			return export_csv(path, data)


## Get supported import file filters for FileDialog
static func get_import_filters() -> PackedStringArray:
	return PackedStringArray([
		"*.csv ; CSV Files",
		"*.tsv ; TSV Files",
		"*.xlsx ; Excel Files",
		"*.minsheet ; Minerva Spreadsheet",
	])


## Get supported export file filters for FileDialog
static func get_export_filters() -> PackedStringArray:
	return PackedStringArray([
		"*.csv ; CSV Files",
		"*.tsv ; TSV Files",
		"*.xlsx ; Excel Files",
		"*.minsheet ; Minerva Spreadsheet",
	])


## Confirm the information discarded by the copied interchange serializers.
static func export_loss_notice(extension: String) -> String:
	if extension == "minsheet":
		return ""
	if extension == "xlsx":
		return "XLSX keeps cell values and formulas. Formatting, charts and filters are dropped. Export a copy?"
	# export_file's existing unknown-extension fallback is CSV too.
	var format_name := "TSV" if extension == "tsv" else "CSV"
	return format_name + " keeps cell values only. Formulas, formatting, charts and filters are dropped. Export a copy?"

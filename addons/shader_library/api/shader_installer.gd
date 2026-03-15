@tool
extends Node
class_name ShaderInstaller

## Downloads and installs shaders from godotshaders.com

const Translations = preload("res://addons/shader_library/api/translations.gd")

signal installation_started(shader_name: String)
signal installation_progress(shader_name: String, progress: float, status: String)
signal installation_completed(shader_path: String)
signal installation_failed(error: String)

const SETTING_SHADERS_PATH = "shader_library/general/shaders_folder"
const DEFAULT_SHADERS_PATH = "res://shaders/shaderlib/"

func _get_shaders_dir() -> String:
	return ProjectSettings.get_setting(SETTING_SHADERS_PATH, DEFAULT_SHADERS_PATH)

var http_request: HTTPRequest
var current_shader: Dictionary = {}

func _ready() -> void:
	http_request = HTTPRequest.new()
	http_request.timeout = 30
	add_child(http_request)
	http_request.request_completed.connect(_on_download_completed)
	
	_ensure_shaders_directory()

func _ensure_shaders_directory() -> void:
	var shaders_path = _get_shaders_dir()
	# Remove res:// prefix for directory operations
	var relative_path = shaders_path.replace("res://", "")
	if relative_path.ends_with("/"):
		relative_path = relative_path.substr(0, relative_path.length() - 1)
	
	var dir = DirAccess.open("res://")
	if dir:
		# Create each directory in the path
		var parts = relative_path.split("/")
		var current_path = ""
		for part in parts:
			if current_path == "":
				current_path = part
			else:
				current_path += "/" + part
			if not dir.dir_exists(current_path):
				dir.make_dir(current_path)

## Install a shader - downloads from its URL
func install_shader(shader: Dictionary) -> void:
	current_shader = shader
	var url = shader.get("url", "")
	var shader_name = shader.get("title", "Shader")
	
	if url.is_empty():
		installation_failed.emit("No URL provided")
		return
	
	installation_started.emit(shader_name)
	installation_progress.emit(shader_name, 0.1, Translations.t("connecting"))
	
	var error = http_request.request(url)
	if error != OK:
		installation_failed.emit("HTTP request failed: " + str(error))

func _on_download_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	var shader_name = current_shader.get("title", "Shader")
	
	if result != HTTPRequest.RESULT_SUCCESS:
		installation_failed.emit("Download failed (result: " + str(result) + ")")
		return
	
	if response_code != 200:
		installation_failed.emit("HTTP error: " + str(response_code))
		return
	
	installation_progress.emit(shader_name, 0.4, "Parsowanie strony...")
	
	var html = body.get_string_from_utf8()
	var shader_code = _extract_shader_code(html)
	
	if shader_code.is_empty():
		installation_failed.emit("Could not find shader code on page")
		return
	
	installation_progress.emit(shader_name, 0.6, "Wykrywanie licencji...")
	
	# Extract license from page
	var license = _extract_license(html)
	current_shader["license"] = license
	
	installation_progress.emit(shader_name, 0.8, "Zapisywanie pliku...")
	
	# Save shader to file
	var saved_path = _save_shader(shader_code)
	if saved_path.is_empty():
		installation_failed.emit("Failed to save shader file")
		return
	
	installation_progress.emit(shader_name, 1.0, "Gotowe!")
	installation_completed.emit(saved_path)

## Extract shader code from HTML page - improved with multiple methods
func _extract_shader_code(html: String) -> String:
	var code = ""
	
	# Method 1: Look for <code> block containing shader_type
	code = _extract_code_block(html)
	if not code.is_empty():
		return code
	
	# Method 2: Look for <pre> block containing shader_type
	code = _extract_pre_block(html)
	if not code.is_empty():
		return code
	
	# Method 3: Look for code between ``` markers (markdown style)
	code = _extract_between_markers(html, "```", "```")
	if not code.is_empty() and "shader_type" in code:
		return _clean_code(code)
	
	# Method 4: Fallback - find shader_type directly
	code = _extract_shader_type_block(html)
	if not code.is_empty():
		return code
	
	return ""

## Extract shader from <code> tags
func _extract_code_block(html: String) -> String:
	var regex = RegEx.new()
	# Match <code> blocks that contain shader_type
	regex.compile("(?s)<code[^>]*>(.*?)</code>")
	var matches = regex.search_all(html)
	
	for m in matches:
		var content = m.get_string(1)
		if "shader_type" in content:
			return _clean_code(content)
	
	return ""

## Extract shader from <pre> tags
func _extract_pre_block(html: String) -> String:
	var regex = RegEx.new()
	# Match <pre> blocks that contain shader_type
	regex.compile("(?s)<pre[^>]*>(.*?)</pre>")
	var matches = regex.search_all(html)
	
	for m in matches:
		var content = m.get_string(1)
		if "shader_type" in content:
			# Also remove nested code tags
			content = content.replace("<code>", "").replace("</code>", "")
			return _clean_code(content)
	
	return ""

## Extract starting from shader_type keyword
func _extract_shader_type_block(html: String) -> String:
	var start = html.find("shader_type")
	if start == -1:
		return ""
	
	# Find the end - look for common end markers
	var search_end = html.substr(start, 15000)
	var end_markers = [
		"</code>", "</pre>", "```", 
		"<button", "Copy", "##### Live", 
		"<div class=\"wp-", "<footer"
	]
	var end = search_end.length()
	
	for marker in end_markers:
		var pos = search_end.find(marker)
		if pos != -1 and pos < end:
			end = pos
	
	var code_block = search_end.substr(0, end)
	return _clean_code(code_block)

func _extract_between_markers(text: String, start_marker: String, end_marker: String) -> String:
	var start = text.find(start_marker)
	if start == -1:
		return ""
	
	start += start_marker.length()
	
	# Skip newline after opening marker
	if text.length() > start and text[start] == '\n':
		start += 1
	
	var end = text.find(end_marker, start)
	if end == -1:
		return ""
	
	return text.substr(start, end - start)

func _extract_license(html: String) -> String:
	if "CC0" in html or "public domain" in html.to_lower():
		return "CC0"
	elif "MIT" in html:
		return "MIT"
	elif "GPL" in html:
		return "GPL v3"
	return "CC0"

func _clean_code(code: String) -> String:
	# Remove HTML entities
	code = code.replace("&lt;", "<")
	code = code.replace("&gt;", ">")
	code = code.replace("&amp;", "&")
	code = code.replace("&quot;", "\"")
	code = code.replace("&#39;", "'")
	code = code.replace("&nbsp;", " ")
	
	# Remove HTML line breaks
	code = code.replace("<br>", "\n")
	code = code.replace("<br/>", "\n")
	code = code.replace("<br />", "\n")
	
	# Remove remaining HTML tags
	var regex = RegEx.new()
	regex.compile("<[^>]+>")
	code = regex.sub(code, "", true)
	
	# Trim trailing whitespace per line and overall
	var lines = code.split("\n")
	var cleaned_lines = []
	for line in lines:
		cleaned_lines.append(line.rstrip(" \t\r"))
	
	code = "\n".join(cleaned_lines)
	return code.strip_edges()

func _save_shader(code: String) -> String:
	_ensure_shaders_directory()
	
	var filename = _sanitize_filename(current_shader.get("title", "shader"))
	var filepath = _get_shaders_dir() + filename + ".gdshader"
	
	# Create header with attribution
	var header = "// ============================================\n"
	header += "// Shader from godotshaders.com\n"
	header += "// ============================================\n"
	header += "// Title: " + current_shader.get("title", "Unknown") + "\n"
	header += "// Author: " + current_shader.get("author", "Unknown") + "\n"
	header += "// License: " + current_shader.get("license", "CC0") + "\n"
	header += "// URL: " + current_shader.get("url", "") + "\n"
	header += "// ============================================\n\n"
	
	var final_code = header + code
	
	var file = FileAccess.open(filepath, FileAccess.WRITE)
	if file == null:
		return ""
	
	file.store_string(final_code)
	file.close()
	
	# Refresh filesystem
	if Engine.is_editor_hint():
		var editor = Engine.get_singleton("EditorInterface")
		if editor:
			editor.get_resource_filesystem().scan()
	
	return filepath

func _sanitize_filename(name: String) -> String:
	var result = name.to_lower()
	result = result.replace(" ", "_")
	result = result.replace("-", "_")
	
	# Remove invalid characters
	var valid = ""
	for c in result:
		if c in "abcdefghijklmnopqrstuvwxyz0123456789_":
			valid += c
	
	# Remove multiple underscores
	while "__" in valid:
		valid = valid.replace("__", "_")
	
	# Remove leading/trailing underscores
	while valid.begins_with("_"):
		valid = valid.substr(1)
	while valid.ends_with("_"):
		valid = valid.substr(0, valid.length() - 1)
	
	if valid.is_empty():
		valid = "shader_" + str(randi() % 10000)
	
	return valid

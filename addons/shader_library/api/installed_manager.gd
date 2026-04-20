@tool
extends Node

## Manages installed shaders in the project
## Internal class - not exposed to users

signal shaders_scanned(shaders: Array)

const SETTING_SHADERS_PATH = "shader_library/general/shaders_folder"
const DEFAULT_SHADERS_PATH = "res://shaders/shaderlib/"

var installed_shaders: Array = []

func _get_shaders_dir() -> String:
	var path = ProjectSettings.get_setting(SETTING_SHADERS_PATH, DEFAULT_SHADERS_PATH)
	if not path.ends_with("/"):
		path += "/"
	return path

func _ready() -> void:
	scan_installed_shaders()

func scan_installed_shaders() -> void:
	installed_shaders.clear()
	
	var shaders_dir = _get_shaders_dir()
	var dir = DirAccess.open(shaders_dir)
	if dir == null:
		shaders_scanned.emit([])
		return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".gdshader"):
			var shader_info = _parse_shader_file(shaders_dir + file_name)
			if not shader_info.is_empty():
				installed_shaders.append(shader_info)
		file_name = dir.get_next()
	
	dir.list_dir_end()
	shaders_scanned.emit(installed_shaders)

func _parse_shader_file(path: String) -> Dictionary:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	
	var content = file.get_as_text()
	file.close()
	
	var info = {
		"path": path,
		"filename": path.get_file(),
		"title": path.get_file().get_basename().replace("_", " ").capitalize(),
		"author": "Unknown",
		"license": "Unknown",
		"url": "",
		"installed": true
	}
	
	# Parse header comments for metadata
	var lines = content.split("\n")
	for line in lines:
		if not line.begins_with("//"):
			break
		
		if "Title:" in line:
			info["title"] = line.split("Title:")[1].strip_edges()
		elif "Author:" in line:
			info["author"] = line.split("Author:")[1].strip_edges()
		elif "License:" in line:
			info["license"] = line.split("License:")[1].strip_edges()
		elif "URL:" in line:
			info["url"] = line.split("URL:")[1].strip_edges()
	
	# Detect shader type
	if "shader_type canvas_item" in content:
		info["category"] = "Canvas Item"
	elif "shader_type spatial" in content:
		info["category"] = "Spatial"
	elif "shader_type particles" in content:
		info["category"] = "Particles"
	elif "shader_type sky" in content:
		info["category"] = "Sky"
	elif "shader_type fog" in content:
		info["category"] = "Fog"
	else:
		info["category"] = "Unknown"
	
	return info

func get_installed_shaders() -> Array:
	return installed_shaders

func get_installed_count() -> int:
	return installed_shaders.size()

func is_shader_installed(title: String) -> bool:
	for shader in installed_shaders:
		if shader.get("title", "").to_lower() == title.to_lower():
			return true
	return false

func delete_shader(shader: Dictionary) -> bool:
	var path = shader.get("path", "")
	if path.is_empty():
		return false
	
	var err = DirAccess.remove_absolute(path)
	if err != OK:
		return false
	
	# Refresh filesystem
	if Engine.is_editor_hint():
		var editor = Engine.get_singleton("EditorInterface")
		if editor:
			editor.get_resource_filesystem().scan()
	
	# Rescan
	scan_installed_shaders()
	return true

func open_shader_in_editor(shader: Dictionary) -> void:
	var path = shader.get("path", "")
	if path.is_empty():
		return
	
	if Engine.is_editor_hint():
		var editor = Engine.get_singleton("EditorInterface")
		if editor:
			var res = load(path)
			if res:
				editor.edit_resource(res)

@tool
extends EditorPlugin

const SETTING_SHADERS_PATH = "shader_library/general/shaders_folder"
const SETTING_PREVIOUS_PATH = "shader_library/internal/previous_shaders_folder"
const DEFAULT_SHADERS_PATH = "res://shaders/shaderlib/"

var shader_browser: Control

func _enter_tree() -> void:
	_register_project_settings()
	
	# Check if shaders need to be migrated
	_check_and_migrate_shaders()
	
	# Create shader browser control
	var script = load("res://addons/shader_library/ui/shader_browser.gd")
	shader_browser = Control.new()
	shader_browser.set_script(script)
	shader_browser.name = "ShaderLibrary"
	shader_browser.set_anchors_preset(Control.PRESET_FULL_RECT)
	shader_browser.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shader_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Add to editor main screen (not bottom panel)
	get_editor_interface().get_editor_main_screen().add_child(shader_browser)
	_make_visible(false)

func _exit_tree() -> void:
	if shader_browser:
		shader_browser.queue_free()

func _has_main_screen() -> bool:
	return true

func _get_plugin_name() -> String:
	return "ShaderLib"

func _get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("CanvasItem", "EditorIcons")

func _make_visible(visible: bool) -> void:
	if shader_browser:
		shader_browser.visible = visible

func _register_project_settings() -> void:
	# Shaders folder path
	if not ProjectSettings.has_setting(SETTING_SHADERS_PATH):
		ProjectSettings.set_setting(SETTING_SHADERS_PATH, DEFAULT_SHADERS_PATH)
	
	ProjectSettings.set_initial_value(SETTING_SHADERS_PATH, DEFAULT_SHADERS_PATH)
	ProjectSettings.add_property_info({
		"name": SETTING_SHADERS_PATH,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_DIR,
		"hint_string": "Folder where downloaded shaders will be saved"
	})
	
	# Previous path (internal tracking)
	if not ProjectSettings.has_setting(SETTING_PREVIOUS_PATH):
		ProjectSettings.set_setting(SETTING_PREVIOUS_PATH, DEFAULT_SHADERS_PATH)

func _check_and_migrate_shaders() -> void:
	var current_path = ProjectSettings.get_setting(SETTING_SHADERS_PATH, DEFAULT_SHADERS_PATH)
	var previous_path = ProjectSettings.get_setting(SETTING_PREVIOUS_PATH, DEFAULT_SHADERS_PATH)
	
	# Normalize paths (ensure trailing slash)
	if not current_path.ends_with("/"):
		current_path += "/"
	if not previous_path.ends_with("/"):
		previous_path += "/"
	
	if current_path != previous_path:
		_migrate_shaders(previous_path, current_path)
		ProjectSettings.set_setting(SETTING_PREVIOUS_PATH, current_path)
		ProjectSettings.save()

func _migrate_shaders(from_path: String, to_path: String) -> void:
	var from_dir = DirAccess.open(from_path)
	if from_dir == null:
		return
	
	# Ensure target directory exists
	_ensure_directory(to_path)
	
	# Collect files to move
	from_dir.list_dir_begin()
	var file_name = from_dir.get_next()
	var moved_count = 0
	
	while file_name != "":
		if not from_dir.current_is_dir() and file_name.ends_with(".gdshader"):
			var from_file = from_path + file_name
			var to_file = to_path + file_name
			
			# Read file content
			var file = FileAccess.open(from_file, FileAccess.READ)
			if file:
				var content = file.get_as_text()
				file.close()
				
				# Write to new location
				var out_file = FileAccess.open(to_file, FileAccess.WRITE)
				if out_file:
					out_file.store_string(content)
					out_file.close()
					
					# Delete original
					from_dir.remove(file_name)
					moved_count += 1
		
		file_name = from_dir.get_next()
	
	from_dir.list_dir_end()
	
	# Also move .uid files
	from_dir = DirAccess.open(from_path)
	if from_dir:
		from_dir.list_dir_begin()
		file_name = from_dir.get_next()
		while file_name != "":
			if not from_dir.current_is_dir() and file_name.ends_with(".gdshader.uid"):
				var from_file = from_path + file_name
				var to_file = to_path + file_name
				
				var file = FileAccess.open(from_file, FileAccess.READ)
				if file:
					var content = file.get_as_text()
					file.close()
					
					var out_file = FileAccess.open(to_file, FileAccess.WRITE)
					if out_file:
						out_file.store_string(content)
						out_file.close()
						from_dir.remove(file_name)
			
			file_name = from_dir.get_next()
		from_dir.list_dir_end()
	
	# Refresh the editor filesystem
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()

func _ensure_directory(path: String) -> void:
	var relative_path = path.replace("res://", "")
	if relative_path.ends_with("/"):
		relative_path = relative_path.substr(0, relative_path.length() - 1)
	
	var dir = DirAccess.open("res://")
	if dir:
		var parts = relative_path.split("/")
		var current_path = ""
		for part in parts:
			if current_path == "":
				current_path = part
			else:
				current_path += "/" + part
			if not dir.dir_exists(current_path):
				dir.make_dir(current_path)

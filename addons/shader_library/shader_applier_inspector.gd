@tool
extends EditorInspectorPlugin

## Custom inspector for ShaderApplier node - adds Shader Library option to picker

const ShaderSelectorDialog = preload("res://addons/shader_library/ui/shader_selector_dialog.gd")

var shader_selector_dialog: Window = null
var current_applier: Node = null

func _can_handle(object: Object) -> bool:
	if not object:
		return false
	var script = object.get_script()
	if not script:
		return false
	return "shader_applier.gd" in script.resource_path

func _parse_property(object: Object, type: int, name: String, hint_type: int, hint_string: String, usage_flags: int, wide: bool) -> bool:
	if name == "Shader":
		# Create custom shader property with library option
		var property = ShaderPropertyWithLibrary.new()
		property.setup(object, self)
		add_property_editor("Shader", property)
		return true  # We handled this property
	return false

func open_shader_library(applier: Node) -> void:
	current_applier = applier
	if shader_selector_dialog == null:
		_create_shader_selector_dialog()
	
	shader_selector_dialog.set_meta("applier", applier)
	shader_selector_dialog.popup_centered_ratio(0.7)

func _create_shader_selector_dialog() -> void:
	shader_selector_dialog = Window.new()
	shader_selector_dialog.title = "Select Shader from Library"
	shader_selector_dialog.size = Vector2i(900, 700)
	shader_selector_dialog.wrap_controls = true
	
	var dialog_script = load("res://addons/shader_library/ui/shader_selector_dialog.gd")
	shader_selector_dialog.set_script(dialog_script)
	
	EditorInterface.get_base_control().add_child(shader_selector_dialog)
	shader_selector_dialog.shader_selected.connect(_on_shader_selected)

func _on_shader_selected(shader_path: String) -> void:
	if shader_selector_dialog == null:
		return
	
	var applier = shader_selector_dialog.get_meta("applier") as Node
	
	if applier:
		var shader = load(shader_path)
		if shader:
			applier.set("Shader", shader)
			applier.notify_property_list_changed()
	
	shader_selector_dialog.hide()


## Custom EditorProperty for Shader with Library option in dropdown
class ShaderPropertyWithLibrary extends EditorProperty:
	var picker_button: Button
	var popup_menu: PopupMenu
	var current_shader: Shader = null
	var applier_node: Node = null
	var inspector_plugin = null
	var file_dialog: EditorFileDialog = null
	var save_dialog: EditorFileDialog = null
	var shader_type_dialog: ConfirmationDialog = null
	var pending_shader: Shader = null  # Shader waiting to be saved
	var pending_visual: bool = false  # Whether pending shader is visual
	
	const MENU_NEW_SHADER = 0
	const MENU_NEW_VISUAL_SHADER = 1
	const MENU_QUICK_LOAD = 2
	const MENU_LOAD = 3
	const MENU_CLEAR = 4
	const MENU_SHADER_LIBRARY = 100
	
	func setup(applier: Node, plugin) -> void:
		applier_node = applier
		inspector_plugin = plugin
		
		var hbox = HBoxContainer.new()
		add_child(hbox)
		
		# Main picker button
		picker_button = Button.new()
		picker_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		picker_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		picker_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_update_button_text()
		picker_button.pressed.connect(_on_picker_pressed)
		hbox.add_child(picker_button)
		
		# Dropdown arrow button
		var dropdown_btn = Button.new()
		dropdown_btn.icon = EditorInterface.get_base_control().get_theme_icon("select_arrow", "Tree")
		dropdown_btn.pressed.connect(_show_menu)
		hbox.add_child(dropdown_btn)
		
		# Create popup menu
		popup_menu = PopupMenu.new()
		popup_menu.add_item("New Shader", MENU_NEW_SHADER)
		popup_menu.add_item("VisualShader", MENU_NEW_VISUAL_SHADER)
		popup_menu.add_separator()
		popup_menu.add_item("Quick Load...", MENU_QUICK_LOAD)
		popup_menu.add_item("Load...", MENU_LOAD)
		popup_menu.add_separator()
		popup_menu.add_icon_item(
			EditorInterface.get_base_control().get_theme_icon("Shader", "EditorIcons"),
			"📚 Shader Library",
			MENU_SHADER_LIBRARY
		)
		popup_menu.add_separator()
		popup_menu.add_item("Clear", MENU_CLEAR)
		popup_menu.id_pressed.connect(_on_menu_selected)
		add_child(popup_menu)
	
	func _update_property() -> void:
		var value = get_edited_object().get(get_edited_property())
		current_shader = value as Shader
		_update_button_text()
	
	func _update_button_text() -> void:
		if current_shader:
			var path = current_shader.resource_path
			if path.is_empty():
				picker_button.text = "[Shader]"
			else:
				picker_button.text = path.get_file()
			picker_button.icon = EditorInterface.get_base_control().get_theme_icon("Shader", "EditorIcons")
		else:
			picker_button.text = "<empty>"
			picker_button.icon = null
	
	func _on_picker_pressed() -> void:
		if current_shader:
			# Open shader in editor
			EditorInterface.edit_resource(current_shader)
		else:
			_show_menu()
	
	func _show_menu() -> void:
		var pos = picker_button.global_position
		pos.y += picker_button.size.y
		popup_menu.position = Vector2i(pos)
		popup_menu.popup()
	
	func _on_menu_selected(id: int) -> void:
		match id:
			MENU_NEW_SHADER:
				_create_new_shader(false)
			MENU_NEW_VISUAL_SHADER:
				_create_new_shader(true)
			MENU_QUICK_LOAD:
				_quick_load()
			MENU_LOAD:
				_open_file_dialog()
			MENU_CLEAR:
				_clear_shader()
			MENU_SHADER_LIBRARY:
				_open_shader_library()
	
	func _create_new_shader(visual: bool) -> void:
		pending_visual = visual
		
		if visual:
			# Visual shaders - create directly
			var shader = VisualShader.new()
			pending_shader = shader
			_open_save_dialog(true)
		else:
			# Text shaders - show type selection dialog
			_show_shader_type_dialog()
	
	func _show_shader_type_dialog() -> void:
		if shader_type_dialog == null:
			shader_type_dialog = ConfirmationDialog.new()
			shader_type_dialog.title = "Select Shader Type"
			shader_type_dialog.dialog_text = "Choose shader type:"
			shader_type_dialog.ok_button_text = "Create"
			
			var vbox = VBoxContainer.new()
			shader_type_dialog.add_child(vbox)
			
			var option_button = OptionButton.new()
			option_button.name = "ShaderTypeOption"
			option_button.add_item("Spatial (3D)", 0)
			option_button.add_item("CanvasItem (2D)", 1)
			option_button.add_item("Particles", 2)
			option_button.add_item("Sky", 3)
			option_button.add_item("Fog", 4)
			option_button.selected = 1  # Default to CanvasItem
			vbox.add_child(option_button)
			
			shader_type_dialog.confirmed.connect(_on_shader_type_confirmed)
			EditorInterface.get_base_control().add_child(shader_type_dialog)
		
		shader_type_dialog.popup_centered()
	
	func _on_shader_type_confirmed() -> void:
		var option_button = shader_type_dialog.find_child("ShaderTypeOption", true, false) as OptionButton
		if option_button == null:
			return
		
		var shader_types = ["spatial", "canvas_item", "particles", "sky", "fog"]
		var selected_type = shader_types[option_button.selected]
		
		var shader = Shader.new()
		shader.code = "shader_type " + selected_type + ";\n"
		pending_shader = shader
		_open_save_dialog(false)
	
	func _open_save_dialog(visual: bool) -> void:
		if save_dialog == null:
			save_dialog = EditorFileDialog.new()
			save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
			save_dialog.access = EditorFileDialog.ACCESS_RESOURCES
			save_dialog.file_selected.connect(_on_shader_saved)
			EditorInterface.get_base_control().add_child(save_dialog)
		
		save_dialog.clear_filters()
		if visual:
			save_dialog.add_filter("*.tres", "Visual Shader Resource")
			save_dialog.current_file = "new_visual_shader.tres"
		else:
			save_dialog.add_filter("*.gdshader", "Godot Shader")
			save_dialog.current_file = "new_shader.gdshader"
		
		save_dialog.popup_centered_ratio(0.6)
	
	func _on_shader_saved(path: String) -> void:
		if pending_shader == null:
			return
		
		var error = ResourceSaver.save(pending_shader, path)
		if error == OK:
			# Reload the saved shader and apply it
			var saved_shader = load(path) as Shader
			if saved_shader:
				emit_changed(get_edited_property(), saved_shader)
				current_shader = saved_shader
				_update_button_text()
				# Open the shader in editor for editing
				EditorInterface.edit_resource(saved_shader)
		else:
			push_error("Failed to save shader: " + str(error))
		
		pending_shader = null
	
	func _open_file_dialog() -> void:
		if file_dialog == null:
			file_dialog = EditorFileDialog.new()
			file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
			file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
			file_dialog.add_filter("*.gdshader", "Godot Shader")
			file_dialog.add_filter("*.tres", "Resource")
			file_dialog.file_selected.connect(_on_file_selected)
			EditorInterface.get_base_control().add_child(file_dialog)
		
		file_dialog.popup_centered_ratio(0.6)
	
	func _on_file_selected(path: String) -> void:
		var shader = load(path) as Shader
		if shader:
			emit_changed(get_edited_property(), shader)
			_update_button_text()
	
	func _quick_load() -> void:
		# Use Godot's quick load dialog
		var quick_open = EditorInterface.get_editor_main_screen().get_parent().find_child("EditorQuickOpen", true, false)
		if quick_open == null:
			# Fallback to file dialog
			_open_file_dialog()
			return
		
		# For now, just open file dialog as quick open is internal
		_open_file_dialog()
	
	func _clear_shader() -> void:
		emit_changed(get_edited_property(), null)
		current_shader = null
		_update_button_text()
	
	func _open_shader_library() -> void:
		if inspector_plugin:
			inspector_plugin.open_shader_library(applier_node)

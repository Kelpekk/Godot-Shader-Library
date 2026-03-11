@tool
extends EditorPlugin

var shader_browser: Control

func _enter_tree() -> void:
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
	
	print("Shader Library plugin enabled!")

func _exit_tree() -> void:
	if shader_browser:
		shader_browser.queue_free()
	print("Shader Library plugin disabled!")

func _has_main_screen() -> bool:
	return true

func _get_plugin_name() -> String:
	return "ShaderLib"

func _get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("CanvasItem", "EditorIcons")

func _make_visible(visible: bool) -> void:
	if shader_browser:
		shader_browser.visible = visible

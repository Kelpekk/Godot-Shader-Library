@tool
extends Window

## Dialog for selecting shaders - embeds full Shader Library browser

signal shader_selected(shader_path: String)

var browser: Control
var select_mode_active: bool = true

func _ready() -> void:
	close_requested.connect(_on_close)
	_build_ui()

func _build_ui() -> void:
	# Create full shader browser embedded in this window
	var script = load("res://addons/shader_library/ui/shader_browser.gd")
	browser = Control.new()
	browser.set_script(script)
	browser.set_anchors_preset(Control.PRESET_FULL_RECT)
	browser.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Set selection mode flag
	browser.set_meta("select_mode", true)
	browser.set_meta("selector_dialog", self)
	
	add_child(browser)

func _on_close() -> void:
	hide()

## Called from shader browser when shader is selected
func select_shader(shader_path: String) -> void:
	shader_selected.emit(shader_path)
	hide()

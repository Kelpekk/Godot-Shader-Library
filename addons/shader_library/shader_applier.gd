@tool
extends Node
class_name ShaderApplier

## A helper node that allows applying shaders from Shader Library to its parent node

var shader_path: String = ""
var _previous_parent: Node = null  # Track previous parent to clear shader on reparent
var _is_valid: bool = true  # Flag to track if this ShaderApplier passed validation
var _initialized: bool = false  # Flag to track if _ready() has run

## Get the parent node (for inspector display)
func get_parent_node() -> Node:
	return get_parent()

## Custom property list for inspector
func _get_property_list() -> Array:
	var properties = []
	
	# Parent info (read-only display)
	var parent = get_parent()
	var parent_text = "None"
	if parent:
		parent_text = parent.name + " (" + parent.get_class() + ")"
	
	properties.append({
		"name": "Parent",
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY,
		"hint": PROPERTY_HINT_NONE,
	})
	
	# Shader selector
	properties.append({
		"name": "Shader",
		"type": TYPE_OBJECT,
		"usage": PROPERTY_USAGE_EDITOR,
		"hint": PROPERTY_HINT_RESOURCE_TYPE,
		"hint_string": "Shader"
	})
	
	return properties

func _get(property: StringName) -> Variant:
	if property == "Parent":
		var parent = get_parent()
		if parent:
			return parent.name + " (" + parent.get_class() + ")"
		return "(No parent)"
	
	elif property == "Shader":
		if shader_path.is_empty():
			return null
		return load(shader_path)
	
	return null

func _set(property: StringName, value: Variant) -> bool:
	if property == "Shader":
		if value == null:
			shader_path = ""
			if Engine.is_editor_hint():
				_clear_shader_from_parent(get_parent())
		elif value is Shader:
			shader_path = value.resource_path
			if Engine.is_editor_hint():
				_apply_shader_to_parent()
		return true
	
	return false

## Apply shader to parent node
func _apply_shader_to_parent() -> void:
	if not Engine.is_editor_hint():
		return
	
	var parent = get_parent()
	if parent == null:
		return
	
	# Load shader if path is valid
	if shader_path.is_empty():
		_clear_shader_from_parent(parent)
		return
	
	var shader = load(shader_path)
	if shader == null:
		push_error("ShaderApplier: Failed to load shader from path: " + shader_path)
		return
	
	_apply_shader(parent, shader)

## Apply shader to different node types
func _apply_shader(node: Node, shader: Shader) -> void:
	# Create ShaderMaterial
	var shader_material = ShaderMaterial.new()
	shader_material.shader = shader
	
	# 3D nodes - use material_override
	if node is MeshInstance3D or node is Sprite3D or node is AnimatedSprite3D:
		node.material_override = shader_material
	elif node is CSGShape3D:
		node.material = shader_material
	elif node is GPUParticles3D:
		node.process_material = shader_material
	# 2D CanvasItem nodes - use material
	elif node is Sprite2D or node is AnimatedSprite2D:
		node.material = shader_material
	elif node is ColorRect or node is TextureRect or node is Panel:
		node.material = shader_material
	elif node is GPUParticles2D:
		node.process_material = shader_material
	elif node is CanvasItem:
		# Generic CanvasItem (Node2D, Control, etc.)
		node.material = shader_material
	else:
		push_warning("ShaderApplier: Parent node type '" + node.get_class() + "' may not support shader materials")

## Clear shader from parent
func _clear_shader_from_parent(node: Node) -> void:
	# 3D nodes
	if node is MeshInstance3D or node is Sprite3D or node is AnimatedSprite3D:
		node.material_override = null
	elif node is CSGShape3D:
		node.material = null
	elif node is GPUParticles3D:
		node.process_material = null
	# 2D CanvasItem nodes
	elif node is Sprite2D or node is AnimatedSprite2D:
		node.material = null
	elif node is ColorRect or node is TextureRect or node is Panel:
		node.material = null
	elif node is GPUParticles2D:
		node.process_material = null
	elif node is CanvasItem:
		node.material = null

## Get current shader from parent (if any)
func get_current_shader() -> Shader:
	var parent = get_parent()
	if parent == null:
		return null
	
	var material: Material = null
	# 3D nodes
	if parent is MeshInstance3D or parent is Sprite3D or parent is AnimatedSprite3D:
		material = parent.material_override
	elif parent is CSGShape3D:
		material = parent.material
	elif parent is GPUParticles3D:
		material = parent.process_material
	# 2D CanvasItem nodes
	elif parent is Sprite2D or parent is AnimatedSprite2D:
		material = parent.material
	elif parent is ColorRect or parent is TextureRect or parent is Panel:
		material = parent.material
	elif parent is GPUParticles2D:
		material = parent.process_material
	elif parent is CanvasItem:
		material = parent.material
	
	if material is ShaderMaterial:
		return material.shader
	
	return null

func _ready() -> void:
	if Engine.is_editor_hint():
		# Mark as initialized
		_initialized = true
		# Track current parent
		_previous_parent = get_parent()
		# Check if parent already has another ShaderApplier
		if _has_existing_shader_applier(get_parent()):
			_is_valid = false
			_show_shader_applier_warning()
			call_deferred("queue_free")  # Remove this invalid ShaderApplier
		# Check if parent already has material
		elif _has_existing_material(get_parent()):
			_is_valid = false
			_show_material_warning()
			call_deferred("queue_free")  # Remove this invalid ShaderApplier
		else:
			# Apply shader on ready in editor
			_apply_shader_to_parent()

func _exit_tree() -> void:
	if not Engine.is_editor_hint():
		return
	
	# Clean up shader from parent when ShaderApplier is removed
	var parent = get_parent()
	if parent != null and _is_valid:
		_clear_shader_from_parent(parent)

func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	
	# Don't process if we're being removed due to validation failure
	if not _is_valid:
		return
	
	# Don't process NOTIFICATION_PARENTED before _ready() - _ready() will handle initial validation
	if not _initialized:
		return
	
	if what == NOTIFICATION_PARENTED:
		var new_parent = get_parent()
		
		# Check if new parent already has another ShaderApplier
		if _has_existing_shader_applier(new_parent):
			_show_shader_applier_warning()
			# Move back to previous parent if possible
			if _previous_parent != null and is_instance_valid(_previous_parent):
				call_deferred("reparent", _previous_parent)
				return
			else:
				_is_valid = false
				call_deferred("queue_free")
				return
		
		# Check if new parent already has a material (not from us)
		if _has_existing_material(new_parent):
			_show_material_warning()
			# Move back to previous parent if possible
			if _previous_parent != null and is_instance_valid(_previous_parent):
				call_deferred("reparent", _previous_parent)
				return
			else:
				_is_valid = false
				call_deferred("queue_free")
				return
		
		# Clear shader from old parent (if it still exists and is different)
		if _previous_parent != null and is_instance_valid(_previous_parent) and _previous_parent != new_parent:
			_clear_shader_from_parent(_previous_parent)
		
		# Apply shader to new parent
		_previous_parent = new_parent
		_apply_shader_to_parent()
		
		# Update inspector
		notify_property_list_changed()

## Check if node already has another ShaderApplier child
func _has_existing_shader_applier(node: Node) -> bool:
	if node == null:
		return false
	
	for child in node.get_children():
		if child is ShaderApplier and child != self:
			return true
	return false

## Check if node already has a material assigned (not by ShaderApplier)
func _has_existing_material(node: Node) -> bool:
	if node == null:
		return false
	
	var material: Material = null
	
	# 3D nodes
	if node is MeshInstance3D or node is Sprite3D or node is AnimatedSprite3D:
		material = node.material_override
	elif node is CSGShape3D:
		material = node.material
	elif node is GPUParticles3D:
		material = node.process_material
	# 2D CanvasItem nodes
	elif node is Sprite2D or node is AnimatedSprite2D:
		material = node.material
	elif node is ColorRect or node is TextureRect or node is Panel:
		material = node.material
	elif node is GPUParticles2D:
		material = node.process_material
	elif node is CanvasItem:
		material = node.material
	
	# Check if material exists and is not empty
	if material != null:
		# If it's a ShaderMaterial with our shader, it's ours - allow
		if material is ShaderMaterial and not shader_path.is_empty():
			var our_shader = load(shader_path)
			if our_shader and material.shader == our_shader:
				return false  # It's our material
		return true  # Has foreign material
	
	return false

## Show warning dialog when parent already has material
func _show_material_warning() -> void:
	var dialog = AcceptDialog.new()
	dialog.title = "ShaderApplier Warning"
	dialog.dialog_text = "This node already has a material assigned.\nShaderApplier cannot override existing materials.\n\nRemove the existing material first, or use a different parent node."
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()

## Show warning dialog when parent already has a ShaderApplier
func _show_shader_applier_warning() -> void:
	var dialog = AcceptDialog.new()
	dialog.title = "ShaderApplier Warning"
	dialog.dialog_text = "This node already has a ShaderApplier attached.\nOnly one ShaderApplier per node is allowed.\n\nRemove the existing ShaderApplier first, or use a different parent node."
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()

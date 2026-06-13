@tool
extends PanelContainer

## Animated GIF player — looping, pure GDScript.
## Call start_frames(frames) with the decoder's output to start.
## Call stop() to free memory and halt.
##
## We extend PanelContainer (not MarginContainer) so the black background is
## drawn via the theme stylebox — that's guaranteed to render under the texture
## even if the Container's sort_children hasn't sized a sibling ColorRect yet.

const GIFDecoder = preload("res://addons/shader_library/api/gif_decoder.gd")

var _frames: Array = []
var _idx: int = 0
var _rect: TextureRect
var _timer: Timer
var _tex: ImageTexture  # reused every frame to avoid per-frame GPU allocation


func _ready() -> void:
	# Start with a TRANSPARENT panel so the card's tinted ImgBg (and any
	# placeholder above us) shows through while the decoder is still working.
	# _show() swaps in a solid-black panel once frames arrive — that handles
	# disposal-cleared / transparent GIF pixels without leaking the ImgBg tint.
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0, 0, 0, 0)
	add_theme_stylebox_override("panel", bg_style)

	_tex = ImageTexture.new()
	_rect = TextureRect.new()
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_rect.mouse_filter = MOUSE_FILTER_IGNORE
	_rect.texture = _tex
	add_child(_rect)

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_advance)
	add_child(_timer)


func play_gif(data: PackedByteArray) -> void:
	stop()
	_frames = GIFDecoder.new().decode(data)
	if _frames.is_empty():
		return
	_idx = 0
	_show()


func start_frames(frames: Array) -> void:
	stop()
	_frames = frames
	if _frames.is_empty():
		return
	_idx = 0
	_show()


func stop() -> void:
	if is_instance_valid(_timer): _timer.stop()
	_frames = []
	if is_instance_valid(_rect): _rect.texture = null


func _show() -> void:
	# Static first-frame preview only — see GIFDecoder.decode() for the rationale.
	# We don't start the timer or advance frames; the ▶ badge on the card and the
	# "Watch Video" button in preview tell the user how to see the animation.
	if _frames.is_empty(): return
	var f: Dictionary = _frames[0]
	if not is_instance_valid(_tex): _tex = ImageTexture.new()
	_tex.set_image(f.image)
	if _rect.texture != _tex: _rect.texture = _tex
	# Frame is now drawn — switch to opaque black so transparent GIF pixels
	# don't leak the card's tinted ImgBg through.
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color.BLACK
	add_theme_stylebox_override("panel", bg_style)


func _advance() -> void:
	# Kept connected for backwards compatibility but never fires — _show() no
	# longer starts the timer.
	pass

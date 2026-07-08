@tool
extends PanelContainer

## GIF display with optional playback.
##
## - start_frames(frames): show a single static frame (the cheap card thumbnail).
## - play_animation(frames): cycle every frame on a timer using per-frame delays.
## - stop_animation(): halt, reset to the first frame, and free the extra frames.
##
## We extend PanelContainer so the background is drawn via the theme stylebox —
## it renders under the texture even before the container has sized a child.

const GIFDecoder = preload("res://addons/shader_library/api/gif_decoder.gd")

var _frames: Array = []
var _idx: int = 0
var _rect: TextureRect
var _timer: Timer
var _tex: ImageTexture  # reused every frame to avoid per-frame GPU allocation
var _animating: bool = false


func _ready() -> void:
	# Start with a TRANSPARENT panel so the card's tinted ImgBg (and any
	# placeholder above us) shows through while the decoder is still working.
	# _apply_first_frame swaps in a solid-black panel once a frame is shown.
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


# Static single-frame thumbnail (used on cards until the user hovers).
func start_frames(frames: Array) -> void:
	_stop_timer()
	_animating = false
	_frames = frames
	_idx = 0
	if _frames.is_empty():
		return
	_apply_frame(0)


# Play the full animation. Frames should come from GIFDecoder.decode_all().
func play_animation(frames: Array) -> void:
	if frames.is_empty():
		return
	_frames = frames
	_idx = 0
	_apply_frame(0)
	if _frames.size() <= 1:
		_animating = false
		return  # nothing to animate
	_animating = true
	_start_frame_timer()


# Stop playback, drop back to the first frame, and free the rest to reclaim
# memory (a page can have many GIFs; only the hovered one should hold N frames).
func stop_animation() -> void:
	_stop_timer()
	if not _animating:
		return
	_animating = false
	if _frames.size() > 1:
		var first = _frames[0]
		_frames = [first]
	_idx = 0
	if not _frames.is_empty():
		_apply_frame(0)


func is_animating() -> bool:
	return _animating


func stop() -> void:
	_stop_timer()
	_animating = false
	_frames = []
	if is_instance_valid(_rect): _rect.texture = null


# ── internals ─────────────────────────────────────────────────────────────────

func _advance() -> void:
	if not _animating or _frames.size() <= 1:
		return
	_idx = (_idx + 1) % _frames.size()
	_apply_frame(_idx)
	_start_frame_timer()


func _start_frame_timer() -> void:
	var d: int = int(_frames[_idx].get("delay_ms", 80))
	_timer.start(maxf(0.02, d / 1000.0))  # clamp so pathological 0-delay GIFs don't spin


func _stop_timer() -> void:
	if is_instance_valid(_timer):
		_timer.stop()


func _apply_frame(i: int) -> void:
	if i < 0 or i >= _frames.size():
		return
	var f: Dictionary = _frames[i]
	if not is_instance_valid(_tex):
		_tex = ImageTexture.new()
	_tex.set_image(f.image)
	if _rect.texture != _tex:
		_rect.texture = _tex
	# Frame is drawn — switch to opaque black so transparent GIF pixels don't
	# leak the card's tinted ImgBg through.
	var sb: StyleBox = get_theme_stylebox("panel")
	if not (sb is StyleBoxFlat) or (sb as StyleBoxFlat).bg_color != Color.BLACK:
		var bg_style := StyleBoxFlat.new()
		bg_style.bg_color = Color.BLACK
		add_theme_stylebox_override("panel", bg_style)

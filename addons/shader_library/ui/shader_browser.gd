@tool
extends Control

## Shader Library UI - with image loading and localization

const Translations = preload("res://addons/shader_library/api/translations.gd")
const UpdateChecker = preload("res://addons/shader_library/api/update_checker.gd")
const GIFDecoder   = preload("res://addons/shader_library/api/gif_decoder.gd")
const GifPlayer    = preload("res://addons/shader_library/ui/gif_player.gd")

# Helper function for translations
func tr_key(key: String) -> String:
	return Translations.t(key)

# Helper function for sorting - normalize Unicode quotes to ASCII for proper sorting
func _normalize_title(title: String) -> String:
	# Replace fancy quotes with regular ones so they sort before letters
	# U+201C = left double quote, U+201D = right double quote
	var t = title.to_lower()
	t = t.replace(String.chr(0x201C), "\"").replace(String.chr(0x201D), "\"")
	t = t.replace(String.chr(0x2018), "'").replace(String.chr(0x2019), "'")
	return t

# Compiled regexes and entity tables — built once on first use. RegEx.compile()
# is the slow part of decode; previously this happened on every call.
static var _named_entities: Dictionary = {
	"&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
	"&quot;": "\"", "&apos;": "'", "&ndash;": "-", "&mdash;": "-",
	"&lsquo;": "'", "&rsquo;": "'", "&ldquo;": "\"", "&rdquo;": "\"",
	"&hellip;": "...", "&copy;": "©", "&reg;": "®", "&trade;": "™",
	"&euro;": "€", "&pound;": "£", "&yen;": "¥", "&cent;": "¢",
	"&deg;": "°", "&plusmn;": "±", "&times;": "×", "&divide;": "÷",
	"&frac12;": "½", "&frac14;": "¼", "&frac34;": "¾",
}
# Unicode → ASCII fallback table for fancy quotes / dashes / ellipsis / nbsp.
static var _unicode_fallback: Dictionary = {
	String.chr(0x201C): "\"", String.chr(0x201D): "\"",
	String.chr(0x2018): "'",  String.chr(0x2019): "'",
	String.chr(0x2013): "-",  String.chr(0x2014): "-",
	String.chr(0x2026): "...", String.chr(0x00A0): " ",
}
static var _decimal_regex: RegEx
static var _hex_regex: RegEx

static func _get_decimal_regex() -> RegEx:
	if _decimal_regex == null:
		_decimal_regex = RegEx.new()
		_decimal_regex.compile("&#(\\d+);")
	return _decimal_regex

static func _get_hex_regex() -> RegEx:
	if _hex_regex == null:
		_hex_regex = RegEx.new()
		_hex_regex.compile("&#[xX]([0-9a-fA-F]+);")
	return _hex_regex

# Decode HTML entities to proper characters
func _decode_html_entities(text: String) -> String:
	if text.is_empty():
		return ""

	var result = text

	for entity in _named_entities:
		result = result.replace(entity, _named_entities[entity])

	# Numeric entities (decimal): &#8220; &#8221; etc.
	var decimal_matches = _get_decimal_regex().search_all(result)
	# Process in reverse to avoid position shifts
	for i in range(decimal_matches.size() - 1, -1, -1):
		var match_result = decimal_matches[i]
		var code = int(match_result.get_string(1))
		if code > 0 and code < 0x110000:  # Valid Unicode range
			var char_str = String.chr(code)
			result = result.substr(0, match_result.get_start()) + char_str + result.substr(match_result.get_end())

	# Hex entities: &#x201C; &#x201D; etc.
	var hex_matches = _get_hex_regex().search_all(result)
	for i in range(hex_matches.size() - 1, -1, -1):
		var match_result = hex_matches[i]
		var hex_str = match_result.get_string(1)
		var code = ("0x" + hex_str).hex_to_int()
		if code > 0 and code < 0x110000:
			var char_str = String.chr(code)
			result = result.substr(0, match_result.get_start()) + char_str + result.substr(match_result.get_end())

	# Normalize fancy quotes / dashes / ellipsis / nbsp to ASCII.
	for src in _unicode_fallback:
		result = result.replace(src, _unicode_fallback[src])

	return result

# UI Elements
var search_input: LineEdit
const SHADER_TYPES: Array[String] = ["Canvas Item", "Spatial", "Particles", "Sky", "Fog"]
const LICENSES: Array[String] = ["MIT", "CC0", "Shadertoy port", "GNU GPL v.3"]

var type_menu: MenuButton
# Lowercased category name → true. Empty = "all types".
var active_type_filters: Dictionary = {}

var license_menu: MenuButton
# License name (verbatim) → true. Empty = "all licenses".
var active_license_filters: Dictionary = {}
var sort_option: OptionButton
var shader_grid: HFlowContainer
var status_label: Label
var progress_bar: ProgressBar
var prev_button: Button
var next_button: Button
var page_label: Label
var scroll_container: ScrollContainer
var update_button: Button

# Components
var cache_manager: Node
var shader_installer: Node
var installed_manager: Node
var update_checker: UpdateChecker

# Update state
var pending_update_url: String = ""
var pending_update_version: String = ""
var pending_changelog: String = ""

# Tab state
var current_tab: int = 0  # 0 = Browse, 1 = Installed

# Data
var all_shaders: Array = []
var filtered_shaders: Array = []
var current_page: int = 1
var shaders_per_page: int = 36

# Layout — page size adapts to grid width × editor DPI. See _recompute_layout.
const CARD_BASE_WIDTH: int = 200
const CARD_BASE_HEIGHT: int = 280
const CARD_IMG_BASE_HEIGHT: int = 130
const CARD_H_SEP: int = 12
const ROWS_PER_PAGE: int = 6
const MIN_CARDS_PER_PAGE: int = 12

var _editor_scale: float = 1.0
var _scaled_card_size: Vector2 = Vector2(CARD_BASE_WIDTH, CARD_BASE_HEIGHT)
var _scaled_img_height: int = CARD_IMG_BASE_HEIGHT
var _last_cards_per_row: int = -1
var _layout_debounce: Timer

# Category colors — matched to godotshaders.com badge colors.
var category_colors: Dictionary = {
	"spatial": Color(1.0, 0.32, 0.32),      # red    #FF5252
	"canvas item": Color(0.30, 0.69, 0.31), # green  #4CAF50
	"sky": Color(0.13, 0.59, 0.95),         # blue   #2196F3
	"particles": Color(1.0, 0.60, 0.0),     # orange #FF9800
	"fog": Color(0.58, 0.64, 0.72)          # gray   #94A3B8
}

# Active GIF players in current card grid (freed on page change)
var active_gif_players: Array = []

# Hover-to-animate state. GIF cards show a static first frame; hovering one
# decodes all frames (off-thread, from the disk cache) and plays them. Only the
# hovered card animates, so at most one GIF holds its full frame set at a time.
# _hover_gen invalidates an in-flight decode when the pointer leaves / moves.
var _hovered_card: Control = null
var _hover_anim_timer: Timer
var _hover_gen: int = 0
const HOVER_ANIM_DELAY: float = 0.18  # debounce so fly-overs don't trigger decodes
# LRU cache of fully-decoded GIF frame sets (url -> Array of {image, delay_ms}).
# Decoding all frames in GDScript takes a few seconds for big GIFs, so we pay
# that once per GIF per session; re-hovering a cached GIF plays instantly.
const GIF_FRAMES_CACHE_MAX: int = 3
var _gif_frames_cache: Dictionary = {}
var _gif_frames_keys: Array = []
# Animation frames are downscaled smaller than stills (cards display ~200px):
# 280px keeps them crisp while bounding memory — a capped 60-frame GIF is
# ~14 MB instead of ~80 MB.
const ANIM_FRAME_MAX_WIDTH: int = 280
# Progressive-stream state for the currently-decoding hovered GIF. Frames are
# appended as the worker produces them; the player references this same array
# so playback grows as frames arrive. _stream_gen ties a decode to one hover.
var _stream_gen: int = -1
var _stream_frames: Array = []
var _stream_player: WeakRef = null
var _stream_url: String = ""

# Card pool — persistent 1:1-with-page-size array of cards. Reused across every
# filter change / page flip instead of queue_free + recreate, which was the main
# cause of the page-flip stutter.
var _card_pool: Array = []

# In-memory texture cache (url → Texture2D), FIFO-evicted. Revisiting a page
# becomes near-free: no disk read, no image decode, no GPU re-upload. GIF first
# frames land here too (pre-composited onto black), so each GIF is decoded at
# most once per editor session. Entries are downscaled to card resolution
# (~85-350 KB each), so the cap stays well under ~50 MB of VRAM.
const TEX_CACHE_MAX: int = 160
const CARD_TEX_MAX_WIDTH: int = 480
var _tex_cache: Dictionary = {}
var _tex_cache_keys: Array = []

# Pre-sorted views over all_shaders, built once after precompute completes.
# _apply_filters iterates one of these instead of sorting its output.
var _shaders_by_likes: Array = []
var _shaders_by_title: Array = []

# Incremental-search state. When the user only appends characters to the query
# (and type/license/sort are unchanged), the new result set must be a subset of
# the previous one — so we re-filter the ~tens of previous results instead of
# rescanning all ~2100 shaders on every keystroke.
var _last_query: String = ""
var _last_filter_sig: String = ""
# Installed-tab cards live alongside pool cards in shader_grid; tracked here so
# we can free them when switching back to Browse without touching the pool.
var _installed_cards: Array = []

# Image loading - parallel (4 concurrent downloads)
const PARALLEL_DOWNLOADS: int = 4
var image_queue: Array = []
var image_https: Array = []  # Array of HTTPRequest
var current_image_cards: Array = []  # Array of Control
var current_image_urls: Array = []  # Array of String
var active_downloads: int = 0

# Off-thread image decode. PNG/JPG/WebP decode + downscale are pure-CPU Image
# work (no RenderingServer/scene access), so they run on WorkerThreadPool; only
# the final ImageTexture upload stays on the main thread. Bounded so we never
# flood the pool or land a burst of GPU uploads in one frame.
const MAX_DECODE_TASKS: int = 4
var _decode_tasks_active: int = 0

# Shader preview dialog
var preview_dialog: Window
var preview_code_edit: CodeEdit
var preview_shader: Dictionary = {}
var preview_http: HTTPRequest

# Colors - matching Godot's dark theme
const SETTING_THEME = "shader_library/appearance/theme"

const BADGE_STYLE_BLOCK_TOP = "block_top"  # Classic: colored block above image
const BADGE_STYLE_TEXT_BOTTOM = "text_bottom"  # godotshaders.com: colored text in info row

# Theme palettes. Index matches the enum order in plugin.gd's THEME_NAMES.
const THEMES: Array = [
	{  # 0: Classic — colored block badge at the top of the card.
		"bg_color": Color(0.15, 0.15, 0.15),
		"card_bg": Color(0.2, 0.2, 0.22),
		"accent": Color(0.3, 0.5, 0.9),
		"text_dim": Color(0.6, 0.6, 0.65),
		"badge_style": BADGE_STYLE_BLOCK_TOP,
	},
	{  # 1: godotshaders.com — colored bold text badge in the footer row.
		"bg_color": Color(0.07, 0.07, 0.09),
		"card_bg": Color(0.12, 0.12, 0.15),
		"accent": Color(0.95, 0.38, 0.38),
		"text_dim": Color(0.55, 0.58, 0.62),
		"badge_style": BADGE_STYLE_TEXT_BOTTOM,
	},
]

# Currently active badge style — set by _apply_theme(). Branched on in _create_card
# and the two _get_badge_style helpers below.
var _badge_style_mode: String = BADGE_STYLE_BLOCK_TOP

# Theme index that was loaded when the UI was built. Compared against the live
# ProjectSettings value to surface a restart-required warning when it drifts.
var _theme_idx_at_build: int = 0
var _theme_warning_label: Label

var bg_color := Color(0.15, 0.15, 0.15)  # Godot editor background
var card_bg := Color(0.2, 0.2, 0.22)
var accent := Color(0.3, 0.5, 0.9)
var text_dim := Color(0.6, 0.6, 0.65)

# Shared stylebox cache — _create_card used to allocate 4 fresh StyleBoxFlats per
# card (default + hover panel, category badge, video badge). At 40 cards/page
# that's ~160 allocations per page-flip. These are immutable so a single shared
# instance per logical style is fine; the category badges are cached by category
# string in _badge_styles below.
var _card_default_style: StyleBoxFlat
var _card_hover_style: StyleBoxFlat
var _video_badge_style: StyleBoxFlat
var _badge_styles: Dictionary = {}  # category string → StyleBoxFlat (normal)
var _badge_hover_styles: Dictionary = {}  # category string → StyleBoxFlat (hover, lightened)
var _badge_font: SystemFont  # Bold system font shared by all category badges
# Cached fully-built Theme resources for the category badges. Assigning a Theme
# is ONE operation; setting 12+ individual overrides per Button was the hot spot
# during page flips (40 cards × 12 overrides per badge = ~480 theme-update calls).
var _badge_themes: Dictionary = {}  # category string → Theme
# Pill-styled themes for the godotshaders.com look. Shared across all filter
# buttons + every Preview/Install button on every card.
var _pill_button_theme: Theme
var _pill_lineedit_theme: Theme

# Search debounce — without this, every keystroke runs _apply_filters across all
# ~2100 shaders and rebuilds 40 cards. 200 ms after the last keystroke is enough
# to feel snappy without choking the editor.
var _search_debounce_timer: Timer

## Detect image format from binary data
func _detect_image_format(data: PackedByteArray) -> String:
	if data.size() < 12:
		return "unknown"
	# PNG: 89 50 4E 47
	if data[0] == 0x89 and data[1] == 0x50 and data[2] == 0x4E and data[3] == 0x47:
		return "png"
	# JPEG: FF D8 FF
	if data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF:
		return "jpg"
	# WebP: RIFF....WEBP
	if data[0] == 0x52 and data[1] == 0x49 and data[2] == 0x46 and data[3] == 0x46:
		if data.size() >= 12 and data[8] == 0x57 and data[9] == 0x45 and data[10] == 0x42 and data[11] == 0x50:
			# Check WebP subtype - skip animated/unsupported
			if data.size() >= 16:
				# VP8 (lossy), VP8L (lossless) are OK
				# VP8X may have animation - check flags
				var fourcc = ""
				for i in range(12, 16):
					if i < data.size():
						fourcc += char(data[i])
				if fourcc == "VP8X" and data.size() > 20:
					# Check animation flag (bit 1 of flags byte at offset 20)
					var flags = data[20]
					if flags & 0x02:  # Animation flag
						return "unknown"  # Skip animated WebP
			return "webp"
	# GIF: GIF8
	if data[0] == 0x47 and data[1] == 0x49 and data[2] == 0x46 and data[3] == 0x38:
		return "gif"
	return "unknown"

## Load image from buffer using correct decoder. Falls back to trying every
## decoder when magic-byte detection is inconclusive — some godotshaders.com
## previews have unusual headers (WebP wrapped oddly, JPEG with extra metadata)
## that bypass the format check but decode fine.
func _load_image_from_buffer(data: PackedByteArray) -> Image:
	var img = Image.new()
	var format = _detect_image_format(data)
	var err = ERR_FILE_CORRUPT

	match format:
		"png":
			err = img.load_png_from_buffer(data)
		"jpg":
			err = img.load_jpg_from_buffer(data)
		"webp":
			err = img.load_webp_from_buffer(data)

	if err == OK:
		return img

	# Detection said "unknown" or the typed decoder failed — try the others.
	if format != "png":
		if img.load_png_from_buffer(data) == OK:
			return img
	if format != "jpg":
		if img.load_jpg_from_buffer(data) == OK:
			return img
	if format != "webp":
		if img.load_webp_from_buffer(data) == OK:
			return img
	return null

func _init() -> void:
	custom_minimum_size = Vector2(800, 600)

# True once lazy_init() has run. plugin.gd calls lazy_init on the first
# _make_visible(true), so the editor isn't blocked by JSON load, UI build, or
# component setup for users who never open the ShaderLib tab.
var _initialized: bool = false
var _loading_placeholder: Label

func _ready() -> void:
	# Minimum work — defer the rest until the user actually opens the tab.
	_build_loading_placeholder()

func _build_loading_placeholder() -> void:
	_loading_placeholder = Label.new()
	_loading_placeholder.text = "Loading Shader Library…"
	_loading_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_loading_placeholder.set_anchors_preset(PRESET_FULL_RECT)
	add_child(_loading_placeholder)

func lazy_init() -> void:
	if _initialized:
		return
	_initialized = true
	if is_instance_valid(_loading_placeholder):
		_loading_placeholder.queue_free()
		_loading_placeholder = null
	_init_editor_scale()
	_apply_theme()
	_build_ui()
	_init_components()
	if not ProjectSettings.settings_changed.is_connected(_on_project_settings_changed):
		ProjectSettings.settings_changed.connect(_on_project_settings_changed)
	call_deferred("_start_loading")

func _init_editor_scale() -> void:
	# EditorInterface.get_editor_scale() returns 1.0 / 1.25 / 1.5 / 2.0 etc.
	# depending on the user's OS DPI setting and the editor's display/scale
	# preference. Multiply pixel-sized constants by this so cards stay legible
	# at 4K / hi-DPI without depending on the user re-laying out the grid.
	if Engine.is_editor_hint() and ClassDB.class_exists("EditorInterface"):
		_editor_scale = EditorInterface.get_editor_scale()
	else:
		_editor_scale = 1.0
	_scaled_card_size = Vector2(
		int(CARD_BASE_WIDTH * _editor_scale),
		int(CARD_BASE_HEIGHT * _editor_scale)
	)
	_scaled_img_height = int(CARD_IMG_BASE_HEIGHT * _editor_scale)

func _recompute_layout() -> void:
	# Pick a page size that fills exactly N rows on the current grid width so
	# the last row never has empty trailing slots. Skip if the grid hasn't been
	# laid out yet (size = 0 during initial _ready).
	if shader_grid == null or shader_grid.size.x <= 0:
		return
	var card_w: float = _scaled_card_size.x
	var sep: float = CARD_H_SEP * _editor_scale
	var available: float = shader_grid.size.x
	var cards_per_row: int = maxi(1, int((available + sep) / (card_w + sep)))
	if cards_per_row == _last_cards_per_row:
		return
	var old_size: int = shaders_per_page
	var new_size: int = maxi(MIN_CARDS_PER_PAGE, cards_per_row * ROWS_PER_PAGE)
	_last_cards_per_row = cards_per_row
	if new_size == old_size:
		return
	# Keep roughly the same scroll position: shader-index-based mapping.
	var first_idx: int = (current_page - 1) * old_size
	shaders_per_page = new_size
	current_page = maxi(1, (first_idx / new_size) + 1)
	if not all_shaders.is_empty():
		_display_page()

func _on_grid_resized() -> void:
	if is_instance_valid(_layout_debounce):
		_layout_debounce.start()

func _apply_theme() -> void:
	var theme_idx: int = int(ProjectSettings.get_setting(SETTING_THEME, 0))
	if theme_idx < 0 or theme_idx >= THEMES.size():
		theme_idx = 0
	var palette: Dictionary = THEMES[theme_idx]
	bg_color = palette["bg_color"]
	card_bg = palette["card_bg"]
	accent = palette["accent"]
	text_dim = palette["text_dim"]
	_badge_style_mode = palette["badge_style"]
	_theme_idx_at_build = theme_idx

func _on_project_settings_changed() -> void:
	# Fires for ANY project setting change. Check whether *our* theme drifted
	# from the value that was active when the UI was built; if so, prompt the
	# user to restart Godot. We don't auto-rebuild the UI because too many
	# styles, caches, and child controls would have to be re-derived safely.
	if _theme_warning_label == null:
		return
	var current_idx: int = int(ProjectSettings.get_setting(SETTING_THEME, 0))
	_theme_warning_label.visible = current_idx != _theme_idx_at_build

func _build_ui() -> void:
	# Background
	var bg = ColorRect.new()
	bg.color = bg_color
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)
	
	# Main margin
	var margin = MarginContainer.new()
	margin.set_anchors_preset(PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	vbox.size_flags_vertical = SIZE_EXPAND_FILL
	vbox.size_flags_horizontal = SIZE_EXPAND_FILL
	margin.add_child(vbox)

	# Restart-required warning. Hidden until the theme setting changes at runtime.
	_theme_warning_label = Label.new()
	_theme_warning_label.text = "⚠ Theme changed — restart Godot to apply the new theme."
	_theme_warning_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_theme_warning_label.add_theme_font_size_override("font_size", 13)
	_theme_warning_label.visible = false
	vbox.add_child(_theme_warning_label)

	# Header
	_build_header(vbox)
	
	# Filters
	_build_filters(vbox)

	# Status + Progress
	var status_box = HBoxContainer.new()
	vbox.add_child(status_box)
	
	status_label = Label.new()
	status_label.text = tr_key("loading")
	status_label.add_theme_color_override("font_color", text_dim)
	status_box.add_child(status_label)
	
	var spacer = Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	status_box.add_child(spacer)
	
	progress_bar = ProgressBar.new()
	progress_bar.custom_minimum_size.x = 150
	progress_bar.show_percentage = false
	progress_bar.visible = false
	status_box.add_child(progress_bar)
	
	# Scroll + Grid
	scroll_container = ScrollContainer.new()
	scroll_container.size_flags_vertical = SIZE_EXPAND_FILL
	scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll_container)
	
	shader_grid = HFlowContainer.new()
	var grid_sep: int = int(CARD_H_SEP * _editor_scale)
	shader_grid.add_theme_constant_override("h_separation", grid_sep)
	shader_grid.add_theme_constant_override("v_separation", grid_sep)
	shader_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	shader_grid.resized.connect(_on_grid_resized)
	scroll_container.add_child(shader_grid)

	# Debounce grid resize so we don't re-render on every pixel of drag.
	_layout_debounce = Timer.new()
	_layout_debounce.one_shot = true
	_layout_debounce.wait_time = 0.15
	_layout_debounce.timeout.connect(_recompute_layout)
	add_child(_layout_debounce)

	# Debounce GIF hover so quick pointer fly-overs don't kick off full decodes.
	_hover_anim_timer = Timer.new()
	_hover_anim_timer.one_shot = true
	_hover_anim_timer.wait_time = HOVER_ANIM_DELAY
	_hover_anim_timer.timeout.connect(_on_hover_anim_timeout)
	add_child(_hover_anim_timer)

	# Pagination
	_build_pagination(vbox)

func _build_header(parent: Control) -> void:
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	parent.add_child(header)
	
	var title = Label.new()
	title.text = "Godot Shaders"
	title.add_theme_font_size_override("font_size", 22)
	header.add_child(title)

	# Small "!" info chip — hovering it explains how GIF previews load. Fixed
	# square size + shrink-center so it stays a neat circle instead of
	# stretching to the tall title's height.
	var chip: float = 20.0 * _editor_scale
	var gif_info = Label.new()
	gif_info.text = "!"
	gif_info.add_theme_font_size_override("font_size", int(13 * _editor_scale))
	gif_info.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	gif_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gif_info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	gif_info.custom_minimum_size = Vector2(chip, chip)
	gif_info.size_flags_vertical = SIZE_SHRINK_CENTER
	var info_sb := StyleBoxFlat.new()
	info_sb.bg_color = Color(1.0, 0.85, 0.2, 0.14)
	info_sb.border_color = Color(1.0, 0.85, 0.2, 0.5)
	info_sb.set_border_width_all(1)
	info_sb.set_corner_radius_all(int(chip / 2.0))
	gif_info.add_theme_stylebox_override("normal", info_sb)
	gif_info.mouse_filter = Control.MOUSE_FILTER_STOP
	gif_info.mouse_default_cursor_shape = Control.CURSOR_HELP
	gif_info.tooltip_text = tr_key("gif_hint")
	header.add_child(gif_info)

	# Tab buttons
	var tab_box = HBoxContainer.new()
	tab_box.add_theme_constant_override("separation", 4)
	header.add_child(tab_box)
	
	var browse_btn = Button.new()
	browse_btn.name = "BrowseTab"
	browse_btn.text = tr_key("browse")
	browse_btn.toggle_mode = true
	browse_btn.button_pressed = true
	browse_btn.toggled.connect(_on_tab_browse)
	tab_box.add_child(browse_btn)
	
	var installed_btn = Button.new()
	installed_btn.name = "InstalledTab"
	installed_btn.text = tr_key("installed") + " (0)"
	installed_btn.toggle_mode = true
	installed_btn.toggled.connect(_on_tab_installed)
	tab_box.add_child(installed_btn)
	
	var spacer = Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(spacer)
	
	search_input = LineEdit.new()
	search_input.placeholder_text = tr_key("search")
	search_input.custom_minimum_size.x = 250
	search_input.text_changed.connect(_on_search_text_changed)
	_apply_pill_to_lineedit(search_input)
	header.add_child(search_input)

	# Debounce timer — child of search_input so it dies with the UI
	_search_debounce_timer = Timer.new()
	_search_debounce_timer.one_shot = true
	_search_debounce_timer.wait_time = 0.2
	_search_debounce_timer.timeout.connect(_apply_filters)
	search_input.add_child(_search_debounce_timer)
	
	var refresh_btn = Button.new()
	refresh_btn.text = tr_key("refresh")
	refresh_btn.pressed.connect(_on_refresh)
	header.add_child(refresh_btn)
	
	# Update button (hidden by default, shown when update is available)
	update_button = Button.new()
	update_button.text = "Update Available"
	update_button.modulate = Color(0.4, 1.0, 0.4)  # Green tint
	update_button.visible = false
	update_button.pressed.connect(_on_update_clicked)
	header.add_child(update_button)

func _build_filters(parent: Control) -> void:
	var filters = HBoxContainer.new()
	filters.add_theme_constant_override("separation", 16)
	parent.add_child(filters)
	
	# Type
	var type_lbl = Label.new()
	type_lbl.text = tr_key("type")
	type_lbl.add_theme_color_override("font_color", text_dim)
	filters.add_child(type_lbl)
	
	type_menu = MenuButton.new()
	type_menu.text = tr_key("all_types")
	type_menu.flat = false
	var type_popup := type_menu.get_popup()
	# Stay open so users can toggle multiple categories without re-opening.
	type_popup.hide_on_checkable_item_selection = false
	for i in SHADER_TYPES.size():
		type_popup.add_check_item(SHADER_TYPES[i], i)
	type_popup.id_pressed.connect(_on_type_menu_toggled)
	_apply_pill_to_button(type_menu)
	filters.add_child(type_menu)
	
	# License
	var license_lbl = Label.new()
	license_lbl.text = tr_key("license")
	license_lbl.add_theme_color_override("font_color", text_dim)
	filters.add_child(license_lbl)
	
	license_menu = MenuButton.new()
	license_menu.text = tr_key("all_licenses")
	license_menu.flat = false
	var license_popup := license_menu.get_popup()
	license_popup.hide_on_checkable_item_selection = false
	for i in LICENSES.size():
		license_popup.add_check_item(LICENSES[i], i)
	license_popup.id_pressed.connect(_on_license_menu_toggled)
	_apply_pill_to_button(license_menu)
	filters.add_child(license_menu)
	
	var spacer = Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	filters.add_child(spacer)
	
	# Sort
	var sort_lbl = Label.new()
	sort_lbl.text = tr_key("sort")
	sort_lbl.add_theme_color_override("font_color", text_dim)
	filters.add_child(sort_lbl)
	
	sort_option = OptionButton.new()
	sort_option.add_item(tr_key("most_relevant"))
	sort_option.add_item(tr_key("newest"))
	sort_option.add_item(tr_key("most_liked"))
	sort_option.add_item(tr_key("alphabetical"))
	sort_option.item_selected.connect(_on_filter_changed)
	_apply_pill_to_button(sort_option)
	filters.add_child(sort_option)

func _build_pagination(parent: Control) -> void:
	# Main row container with pagination in center and credits on right
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	parent.add_child(row)
	
	# Left spacer (for centering)
	var left_spacer = Control.new()
	left_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left_spacer)
	
	# Center: pagination buttons
	var paging = HBoxContainer.new()
	paging.add_theme_constant_override("separation", 16)
	row.add_child(paging)
	
	prev_button = Button.new()
	prev_button.text = tr_key("prev")
	prev_button.pressed.connect(_on_prev)
	paging.add_child(prev_button)
	
	page_label = Label.new()
	page_label.text = "1 / 1"
	paging.add_child(page_label)
	
	next_button = Button.new()
	next_button.text = tr_key("next")
	next_button.pressed.connect(_on_next)
	paging.add_child(next_button)
	
	# Right spacer with credits
	var right_spacer = HBoxContainer.new()
	right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_spacer.alignment = BoxContainer.ALIGNMENT_END
	right_spacer.add_theme_constant_override("separation", 4)
	row.add_child(right_spacer)
	
	var heart_label = Label.new()
	heart_label.text = "♥"
	heart_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.4))
	heart_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	right_spacer.add_child(heart_label)
	
	var link_button = LinkButton.new()
	link_button.text = "godotshaders.com"
	link_button.uri = "https://godotshaders.com"
	link_button.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	link_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	right_spacer.add_child(link_button)

func _init_components() -> void:
	# Cache - this is the main data source (downloads from GitHub)
	cache_manager = Node.new()
	cache_manager.set_script(load("res://addons/shader_library/api/cache_manager.gd"))
	add_child(cache_manager)
	
	# Installer
	shader_installer = Node.new()
	shader_installer.set_script(load("res://addons/shader_library/api/shader_installer.gd"))
	add_child(shader_installer)
	shader_installer.installation_started.connect(_on_install_started)
	shader_installer.installation_progress.connect(_on_install_progress)
	shader_installer.installation_completed.connect(_on_installed)
	shader_installer.installation_failed.connect(_on_install_error)
	
	# Image loaders - parallel downloads
	image_https.clear()
	current_image_cards.clear()
	current_image_urls.clear()
	for i in PARALLEL_DOWNLOADS:
		var http = HTTPRequest.new()
		http.timeout = 15
		add_child(http)
		http.request_completed.connect(_on_image_loaded.bind(i))
		image_https.append(http)
		current_image_cards.append(null)
		current_image_urls.append("")
	
	# Preview HTTP
	preview_http = HTTPRequest.new()
	preview_http.timeout = 30
	add_child(preview_http)
	preview_http.request_completed.connect(_on_preview_code_loaded)
	
	# Installed shaders manager
	installed_manager = Node.new()
	installed_manager.set_script(load("res://addons/shader_library/api/installed_manager.gd"))
	add_child(installed_manager)
	installed_manager.shaders_scanned.connect(_on_installed_scanned)
	
	# Update checker — non-critical for startup. Defer instantiation so editor
	# loading isn't blocked by it; the actual check then waits another 2s.
	call_deferred("_init_update_checker")

func _init_update_checker() -> void:
	update_checker = UpdateChecker.new()
	add_child(update_checker)
	update_checker.update_available.connect(_on_update_available)
	update_checker.update_check_completed.connect(_on_update_check_completed)
	update_checker.update_error.connect(_on_update_error)
	get_tree().create_timer(2.0).timeout.connect(func(): update_checker.check_for_updates())
	
	# Connect to cache manager signals (for GitHub download)
	cache_manager.database_loaded.connect(_on_shaders_loaded)
	cache_manager.database_error.connect(_on_database_error)
	# Preview dialog is heavy (~250 nodes) but only needed once the user clicks
	# Preview on a card. Build it lazily in _show_preview to keep editor startup
	# snappy.

func _start_loading() -> void:
	# Cache is parsed on a worker thread; wait for it before deciding whether
	# to use the cache or fetch from GitHub. Without this, the first call lands
	# while is_cache_loaded == false and we'd always re-download.
	if not cache_manager.is_cache_loaded:
		cache_manager.cache_load_finished.connect(_start_loading, CONNECT_ONE_SHOT)
		status_label.text = tr_key("loading_shaders")
		return

	# Check local cache first
	if cache_manager.is_cache_valid():
		var cached = cache_manager.get_cached_shaders()
		if not cached.is_empty():
			status_label.text = tr_key("loaded_shaders") % cached.size()
			_on_shaders_loaded(cached)
			return

	# Download from GitHub (1 request instead of 52 pages!)
	status_label.text = tr_key("loading_shaders")
	progress_bar.visible = true
	progress_bar.value = 50
	progress_bar.max_value = 100
	cache_manager.fetch_from_github()

func _on_database_error(error: String) -> void:
	progress_bar.visible = false
	
	# Use existing cache - don't lose data on refresh failure
	var cached = cache_manager.get_cached_shaders()
	if not cached.is_empty():
		status_label.text = tr_key("found_shaders") % cached.size() + " (offline)"
		_on_shaders_loaded(cached)
	else:
		status_label.text = "Error: " + error + " (no cache available)"

func _on_page_loaded(page: int, total: int) -> void:
	progress_bar.max_value = total
	progress_bar.value = page
	status_label.text = tr_key("loading_page") % [page, total]

const PRECOMPUTE_CHUNK_SIZE: int = 300

func _on_shaders_loaded(shaders: Array) -> void:
	all_shaders = shaders
	# Precompute fields the filter loop and card populate read on every call.
	# Chunk across frames so 2k+ shaders don't freeze the editor for ~150ms on
	# the first open.
	_precompute_chunk(0)

func _precompute_chunk(start: int) -> void:
	var default_color := Color(0.3, 0.35, 0.4)
	var end: int = mini(start + PRECOMPUTE_CHUNK_SIZE, all_shaders.size())
	for i in range(start, end):
		var s: Dictionary = all_shaders[i]
		var raw_cat: String = s.get("category", "")
		var image_url: String = s.get("image_url", "")
		var lc_cat: String = raw_cat.to_lower().replace("_", " ")
		var cat_color: Color = category_colors.get(lc_cat, default_color)
		s["_lc_title"] = s.get("title", "").to_lower()
		s["_lc_author"] = s.get("author", "").to_lower()
		s["_lc_cat"] = lc_cat
		s["_disp_cat"] = raw_cat.to_upper().replace("_", " ").substr(0, 12)
		s["_emoji"] = _category_emoji(lc_cat.to_upper())
		s["_likes_str"] = "♡ " + str(int(s.get("likes", 0)))
		s["_has_video"] = (not s.get("video_url", "").is_empty()) \
			or image_url.to_lower().ends_with(".gif")
		# Sort keys — paying the int()/normalize cost once here means the sorted
		# views below compare plain ints/strings instead of recomputing per
		# comparison (~24k comparisons for 2100 entries).
		s["_likes_int"] = int(s.get("likes", 0))
		s["_sort_title"] = _normalize_title(s.get("title", ""))
		# Precompute the colors that _populate_card would otherwise recompute on
		# every page flip × 40 cards. Color.darkened/lightened allocate.
		s["_cat_color"] = cat_color
		s["_img_bg_color"] = cat_color.darkened(0.5)
		s["_emoji_color"] = cat_color.lightened(0.3)
		s["_badge_theme"] = _get_badge_theme(lc_cat, cat_color)
	if end < all_shaders.size():
		call_deferred("_precompute_chunk", end)
	else:
		_build_sorted_views()
		progress_bar.visible = false
		_apply_filters()

func _build_sorted_views() -> void:
	# Sorted copies of all_shaders, built once per data load. _apply_filters
	# picks one as its iteration source, so changing filters never sorts again —
	# filtering a pre-sorted array preserves its order.
	_shaders_by_likes = all_shaders.duplicate()
	_shaders_by_likes.sort_custom(func(a, b): return a.get("_likes_int", 0) > b.get("_likes_int", 0))
	_shaders_by_title = all_shaders.duplicate()
	_shaders_by_title.sort_custom(func(a, b): return a.get("_sort_title", "") < b.get("_sort_title", ""))

func _filter_sig() -> String:
	# Order-independent signature of the type+license selections and sort mode.
	# Used to decide whether the previous result set is still a valid base for
	# incremental query narrowing.
	var t: Array = active_type_filters.keys()
	t.sort()
	var l: Array = active_license_filters.keys()
	l.sort()
	return "%s|%s|%d" % [",".join(t), ",".join(l), sort_option.selected]

func _apply_filters(_arg = null) -> void:
	# Single pass applying every active filter. Two fast paths:
	#  - incremental: if the query only grew and type/license/sort are unchanged,
	#    the new results are a subset of the previous ones, so we scan those
	#    (tens of entries) instead of all ~2100.
	#  - pre-sorted source: otherwise we iterate the sorted view for the active
	#    sort mode, so filtering preserves order and never re-sorts.
	var query: String = search_input.text.strip_edges().to_lower()

	var has_type: bool = not active_type_filters.is_empty()
	var has_license: bool = not active_license_filters.is_empty()
	var has_query: bool = not query.is_empty()

	var cur_sig: String = _filter_sig()
	var can_narrow: bool = has_query and not _last_query.is_empty() \
		and query.begins_with(_last_query) and cur_sig == _last_filter_sig \
		and not filtered_shaders.is_empty()

	var src: Array
	if can_narrow:
		# Previous result already satisfies type+license and is already ordered;
		# only the (now longer) query predicate can drop entries.
		src = filtered_shaders
		has_type = false
		has_license = false
	else:
		# Iterate the pre-sorted view matching the active sort mode.
		src = all_shaders
		match sort_option.selected:
			2:
				if not _shaders_by_likes.is_empty():
					src = _shaders_by_likes
			3:
				if not _shaders_by_title.is_empty():
					src = _shaders_by_title

	var out: Array = []
	if has_type or has_license or has_query:
		out.resize(src.size())  # upper bound, trimmed below
		var n: int = 0
		for s in src:
			if has_type:
				if not active_type_filters.has(s.get("_lc_cat", "")):
					continue
			if has_license:
				if not active_license_filters.has(s.get("license", "")):
					continue
			if has_query:
				if not (query in s.get("_lc_title", "") or query in s.get("_lc_author", "")):
					continue
			out[n] = s
			n += 1
		out.resize(n)
	else:
		out = src.duplicate()

	filtered_shaders = out
	_last_query = query
	_last_filter_sig = cur_sig

	# Sort comes free from the pre-sorted source views (and from narrowing, which
	# preserves order). The only time we sort here is the brief window before
	# _build_sorted_views has run (user changes sort while precompute is still
	# in flight).
	if not can_narrow:
		match sort_option.selected:
			2:
				if _shaders_by_likes.is_empty():
					filtered_shaders.sort_custom(func(a, b): return int(a.get("likes", 0)) > int(b.get("likes", 0)))
			3:
				if _shaders_by_title.is_empty():
					filtered_shaders.sort_custom(func(a, b):
						return _normalize_title(a.get("title", "")) < _normalize_title(b.get("title", ""))
					)

	current_page = 1
	_display_page()

func _on_filter_changed(_arg = null) -> void:
	_apply_filters()

func _on_badge_pressed(category: String) -> void:
	# Toggle the matching category in the multi-select filter and re-apply.
	# Categories in shader data come as "canvas_item"; menu items are
	# "Canvas Item" — normalize both sides before comparing.
	var target := category.to_lower().replace("_", " ")
	for i in SHADER_TYPES.size():
		if SHADER_TYPES[i].to_lower() == target:
			_toggle_type_filter(i)
			return

func _on_type_menu_toggled(id: int) -> void:
	_toggle_type_filter(id)

func _toggle_type_filter(idx: int) -> void:
	if idx < 0 or idx >= SHADER_TYPES.size():
		return
	var key := SHADER_TYPES[idx].to_lower()
	var popup := type_menu.get_popup()
	if active_type_filters.has(key):
		active_type_filters.erase(key)
		popup.set_item_checked(idx, false)
	else:
		active_type_filters[key] = true
		popup.set_item_checked(idx, true)
	_update_type_menu_text()
	_apply_filters()

func _update_type_menu_text() -> void:
	if active_type_filters.is_empty():
		type_menu.text = tr_key("all_types")
	else:
		type_menu.text = "%s (%d)" % [tr_key("all_types"), active_type_filters.size()]

func _on_license_menu_toggled(id: int) -> void:
	_toggle_license_filter(id)

func _toggle_license_filter(idx: int) -> void:
	if idx < 0 or idx >= LICENSES.size():
		return
	var key := LICENSES[idx]
	var popup := license_menu.get_popup()
	if active_license_filters.has(key):
		active_license_filters.erase(key)
		popup.set_item_checked(idx, false)
	else:
		active_license_filters[key] = true
		popup.set_item_checked(idx, true)
	_update_license_menu_text()
	_apply_filters()

func _update_license_menu_text() -> void:
	if active_license_filters.is_empty():
		license_menu.text = tr_key("all_licenses")
	else:
		license_menu.text = "%s (%d)" % [tr_key("all_licenses"), active_license_filters.size()]

func _on_search_text_changed(_text: String) -> void:
	# Restart the debounce timer on every keystroke; _apply_filters fires once
	# the user pauses for 200 ms.
	if is_instance_valid(_search_debounce_timer):
		_search_debounce_timer.start()

const CARD_UPDATE_CHUNK_SYNC: int = 8   # cards updated in the first frame (visible above the fold)
const CARD_UPDATE_CHUNK_DEFER: int = 6  # cards updated in each subsequent deferred chunk

# Bumped on every _display_page so deferred card-update chunks from a prior
# filter change can detect they're stale and bail out.
var _display_gen: int = 0

func _display_page() -> void:
	_display_gen += 1

	# Cancel any pending image requests
	for http in image_https:
		if http and http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
			http.cancel_request()
	active_downloads = 0

	# NOTE: do NOT stop()/blank GIF players here. Players are static (first
	# frame only, no timer), so there's nothing running to stop — and blanking
	# them turns every card whose shader survives the repopulate (the
	# _populate_card early-out path) into a permanent black tile. Stale players
	# are freed by _populate_card when a slot's shader changes, and
	# _apply_gif_to_card/_apply_image_to_card clear leftovers defensively.

	# Coming back from the Installed tab: drop those cards so they don't sit
	# next to the pool in shader_grid.
	if not _installed_cards.is_empty():
		for c in _installed_cards:
			if is_instance_valid(c):
				c.queue_free()
		_installed_cards.clear()

	image_queue.clear()

	# Restore prev/next buttons in case the Installed tab hid them.
	prev_button.visible = true
	next_button.visible = true

	var total_pages = maxi(1, ceili(float(filtered_shaders.size()) / shaders_per_page))
	var start = (current_page - 1) * shaders_per_page
	var end = mini(start + shaders_per_page, filtered_shaders.size())
	var visible_count: int = end - start

	status_label.text = tr_key("found_shaders") % filtered_shaders.size()
	page_label.text = "%d / %d" % [current_page, total_pages]
	prev_button.disabled = current_page <= 1
	next_button.disabled = current_page >= total_pages

	# Drop stale pool entries that were queue_free'd elsewhere (defensive).
	for i in range(_card_pool.size() - 1, -1, -1):
		if not is_instance_valid(_card_pool[i]):
			_card_pool.remove_at(i)

	# Hide pool slots beyond what this page shows. Cheap; only triggers a redraw
	# for slots that were visible.
	for i in range(visible_count, _card_pool.size()):
		if _card_pool[i].visible:
			_card_pool[i].visible = false

	# Process the first batch of cards inline so the visible-above-the-fold ones
	# update immediately. The rest is deferred over multiple frames so the
	# editor stays responsive on heavy filter / page-flip changes.
	var first_n: int = mini(CARD_UPDATE_CHUNK_SYNC, visible_count)
	_apply_card_slots(0, first_n, start)
	if first_n < visible_count:
		call_deferred("_update_card_chunk", first_n, start, _display_gen)

	_load_next_image()

func _apply_card_slots(slot_start: int, slot_end: int, page_start: int) -> void:
	# Updates pool slot [slot_start, slot_end). Populates if a card already
	# exists in that slot, otherwise creates one.
	for i in range(slot_start, slot_end):
		var shader: Dictionary = filtered_shaders[page_start + i]
		var card: Control
		if i < _card_pool.size():
			card = _card_pool[i]
			_populate_card(card, shader)
		else:
			card = _create_card(shader)
			shader_grid.add_child(card)
			_card_pool.append(card)
		if not card.visible:
			card.visible = true
		var img_url: String = shader.get("image_url", "")
		if not img_url.is_empty():
			image_queue.append({"card": card, "url": img_url, "shader": shader})

func _update_card_chunk(slot: int, page_start: int, gen: int) -> void:
	if gen != _display_gen:
		return  # A newer _display_page already started; drop this chunk.
	var visible_count: int = mini(page_start + shaders_per_page, filtered_shaders.size()) - page_start
	var chunk_end: int = mini(slot + CARD_UPDATE_CHUNK_DEFER, visible_count)
	_apply_card_slots(slot, chunk_end, page_start)
	if chunk_end < visible_count:
		call_deferred("_update_card_chunk", chunk_end, page_start, gen)
	_load_next_image()

func _card_wants_url(card: Control, url: String) -> bool:
	# An async decode may finish after the card was repopulated with a different
	# shader. Only apply the result if the card's current shader still wants this
	# exact image.
	if not is_instance_valid(card) or not card.has_meta("shader"):
		return false
	var s: Dictionary = card.get_meta("shader")
	return s.get("image_url", "") == url

# Worker-thread decoders. They only touch a local PackedByteArray / Image (no
# scene tree, no RenderingServer), so they're safe off the main thread.
func _decode_path_to_card_image(path: String) -> Image:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var img := _load_image_from_buffer(bytes)
	if img != null:
		_downscale_for_card(img)
	return img

func _decode_bytes_to_card_image(bytes: PackedByteArray) -> Image:
	var img := _load_image_from_buffer(bytes)
	if img != null:
		_downscale_for_card(img)
	return img

func _on_async_image_decoded(card_ref: WeakRef, url: String, img: Image) -> void:
	# Runs on the main thread (call_deferred). Does the GPU upload, caches the
	# texture, and applies it to the card if the card still wants it.
	_decode_tasks_active = maxi(0, _decode_tasks_active - 1)
	if img != null:
		var tex := ImageTexture.create_from_image(img)
		_tex_cache_put(url, tex)
		var card = card_ref.get_ref()
		if is_instance_valid(card) and _card_wants_url(card, url):
			_apply_image_to_card(card, tex, url)
	call_deferred("_load_next_image")

func _tex_cache_put(url: String, tex: Texture2D) -> void:
	if url.is_empty() or _tex_cache.has(url):
		return
	_tex_cache[url] = tex
	_tex_cache_keys.append(url)
	if _tex_cache_keys.size() > TEX_CACHE_MAX:
		var evict: String = _tex_cache_keys.pop_front()
		_tex_cache.erase(evict)

## Downscale an image to at most max_w wide (keeps aspect). Cards render small,
## so shrinking before the GPU upload saves upload time and cache memory.
func _downscale_image(img: Image, max_w: int) -> void:
	var w := img.get_width()
	if w > max_w:
		var h: int = maxi(1, int(img.get_height() * float(max_w) / w))
		img.resize(max_w, h, Image.INTERPOLATE_BILINEAR)

## Still previews: 480px is crisp on hi-DPI. The full-res original stays on disk.
func _downscale_for_card(img: Image) -> void:
	_downscale_image(img, CARD_TEX_MAX_WIDTH)

func _load_next_image() -> void:
	# Drive the image queue. Memory-cache hits apply instantly; disk hits are
	# decoded off the main thread (bounded by MAX_DECODE_TASKS); misses are
	# downloaded (bounded by PARALLEL_DOWNLOADS). The loop yields whenever it
	# would exceed either bound and is re-driven by the relevant completion.
	while not image_queue.is_empty():
		var item = image_queue[0]
		var card = item.card
		var url = item.url

		if not is_instance_valid(card):
			image_queue.pop_front()
			continue

		# Skip if this exact content is already on the card (e.g. resize
		# repopulated the same shader into the same slot). Saves a redundant
		# decode/GPU upload and avoids tearing down a player that's fine.
		if card.get_meta("loaded_url", "") == url:
			image_queue.pop_front()
			continue

		# In-memory texture hit — STILL IMAGES ONLY. GIFs must always go through
		# _apply_gif_to_card so a GifPlayer exists for hover-to-animate; caching
		# their first frame as a still texture here would strip that ability.
		var is_gif: bool = url.to_lower().ends_with(".gif")
		if not is_gif:
			var mem_tex: Texture2D = _tex_cache.get(url)
			if mem_tex != null:
				image_queue.pop_front()
				_apply_image_to_card(card, mem_tex, url)
				continue

		# Disk cache hit path.
		if cache_manager.has_cached_image(url):
			var cached_path = cache_manager.get_image_cache_path(url)  # index read, main thread
			if cached_path.ends_with(".gif"):
				image_queue.pop_front()
				var gif_file = FileAccess.open(cached_path, FileAccess.READ)
				if gif_file:
					var gif_data = gif_file.get_buffer(gif_file.get_length())
					gif_file.close()
					_apply_gif_to_card(card, gif_data, url)
				continue
			# Still image — decode + downscale off-thread, bounded.
			if _decode_tasks_active >= MAX_DECODE_TASKS:
				return  # re-driven by _on_async_image_decoded
			image_queue.pop_front()
			_decode_tasks_active += 1
			var card_ref := weakref(card)
			var path: String = cached_path
			WorkerThreadPool.add_task(func():
				var decoded := _decode_path_to_card_image(path)
				call_deferred("_on_async_image_decoded", card_ref, url, decoded)
			)
			continue

		# Download path — needs a free HTTP slot.
		if active_downloads >= PARALLEL_DOWNLOADS:
			return  # Wait for an HTTP completion to call back into us.
		var slot = -1
		for i in PARALLEL_DOWNLOADS:
			if image_https[i].get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
				slot = i
				break
		if slot == -1:
			return

		image_queue.pop_front()
		current_image_cards[slot] = card
		current_image_urls[slot] = url
		active_downloads += 1

		var err = image_https[slot].request(url)
		if err != OK:
			active_downloads -= 1
			current_image_cards[slot] = null
			current_image_urls[slot] = ""

func _on_image_loaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, slot: int) -> void:
	active_downloads = maxi(0, active_downloads - 1)
	
	var card = current_image_cards[slot]
	var url = current_image_urls[slot]
	current_image_cards[slot] = null
	current_image_urls[slot] = ""
	
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		call_deferred("_load_next_image")
		return
	
	if not is_instance_valid(card):
		call_deferred("_load_next_image")
		return
	
	# Check if we actually received image data (not HTML error page)
	if body.size() < 12:
		call_deferred("_load_next_image")
		return
	
	var format = _detect_image_format(body)
	if format == "gif":
		_apply_gif_to_card(card, body, url)
		cache_manager.cache_image(url, body)
		call_deferred("_load_next_image")
		return

	# Persist the full-res bytes to disk on the main thread (updates the cache
	# index), then decode + downscale off-thread; the GPU upload + apply happen
	# in _on_async_image_decoded.
	cache_manager.cache_image(url, body)
	_decode_tasks_active += 1
	var card_ref := weakref(card)
	var body_copy := body.duplicate()
	WorkerThreadPool.add_task(func():
		var decoded := _decode_bytes_to_card_image(body_copy)
		call_deferred("_on_async_image_decoded", card_ref, url, decoded)
	)

	call_deferred("_load_next_image")

func _apply_image_to_card(card: Control, tex: Texture2D, url: String = "") -> void:
	if not is_instance_valid(card):
		return
	# Reuse the persistent TextureRect built once when the card was created.
	if not card.has_meta("image_rect"):
		return
	# Drop any stale GIF player so it can't render above the still image.
	if card.has_meta("img_container"):
		for ch in (card.get_meta("img_container") as MarginContainer).get_children():
			if ch is GifPlayer:
				ch.queue_free()
	card.set_meta("loaded_url", url)
	var image_rect: TextureRect = card.get_meta("image_rect")
	image_rect.texture = tex
	image_rect.visible = true
	if card.has_meta("placeholder_center"):
		(card.get_meta("placeholder_center") as CenterContainer).visible = false

func _apply_gif_to_card(card: Control, data: PackedByteArray, url: String = "") -> void:
	if not is_instance_valid(card): return
	var img_container: MarginContainer = card.get_meta("img_container") if card.has_meta("img_container") else null
	if img_container == null: return
	# Never allow two players on one card: a stale (possibly textureless) player
	# at a later child index renders ON TOP of the new one and shows as a black
	# tile that no amount of redecoding fixes.
	for ch in img_container.get_children():
		if ch is GifPlayer:
			ch.queue_free()
	card.set_meta("loaded_url", url)
	# GifPlayer is HIDDEN until the worker delivers decoded frames. If the
	# previous shader on this slot was a regular image, image_rect keeps showing
	# it during decode — _on_gif_card_ready hides image_rect AND reveals the
	# player atomically once a frame is ready, so the user never sees a dark
	# "in-between" frame.

	var player = GifPlayer.new()
	player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	player.visible = false
	# Remember which card owns this player so _on_gif_card_ready can find the
	# card's placeholder without walking up the tree, and the url so the decoded
	# first frame can be cached for future visits.
	player.set_meta("card", card)
	player.set_meta("url", url)
	# Expose the player + url on the card so hover-to-animate can find them.
	card.set_meta("gif_player", player)
	card.set_meta("gif_url", url)
	img_container.add_child(player)
	img_container.move_child(player, 1)  # After ImgBg at index 0, under PlaceholderCenter
	# Prune freed entries so the tracking array doesn't grow unbounded now that
	# _display_page no longer clears it.
	active_gif_players = active_gif_players.filter(func(p): return is_instance_valid(p))
	active_gif_players.append(player)

	# Create the decoder on the main thread (instantiating @tool GDScript on a
	# worker thread can fail silently in the editor). Only the pure computation
	# runs on the worker.
	var player_ref = weakref(player)
	var decoder = GIFDecoder.new()
	var data_copy = data.duplicate()
	WorkerThreadPool.add_task(func():
		var frames = decoder.decode(data_copy)
		call_deferred("_on_gif_card_ready", player_ref, frames)
	)

func _get_card_default_style() -> StyleBoxFlat:
	if _card_default_style == null:
		var s := StyleBoxFlat.new()
		s.bg_color = card_bg
		s.set_corner_radius_all(8)
		s.set_border_width_all(2)
		s.border_color = Color(0.25, 0.25, 0.3)
		_card_default_style = s
	return _card_default_style

func _get_card_hover_style() -> StyleBoxFlat:
	if _card_hover_style == null:
		var s := StyleBoxFlat.new()
		s.bg_color = Color(0.22, 0.22, 0.28)
		s.set_corner_radius_all(8)
		s.set_border_width_all(2)
		s.border_color = accent
		_card_hover_style = s
	return _card_hover_style

func _get_video_badge_style() -> StyleBoxFlat:
	if _video_badge_style == null:
		var s := StyleBoxFlat.new()
		s.bg_color = Color(0.1, 0.1, 0.1, 0.75)
		s.set_corner_radius(CORNER_TOP_LEFT, 4)
		s.content_margin_left = 4
		s.content_margin_right = 4
		s.content_margin_top = 2
		s.content_margin_bottom = 2
		_video_badge_style = s
	return _video_badge_style

func _get_badge_font() -> SystemFont:
	if _badge_font == null:
		var f := SystemFont.new()
		# godotshaders.com uses Inter; fall back to system sans-serif on machines
		# that don't have it installed.
		f.font_names = PackedStringArray(["Inter", "Segoe UI", "Helvetica Neue", "Arial", "sans-serif"])
		f.font_weight = 700  # Bold
		_badge_font = f
	return _badge_font

func _get_badge_style(category: String, cat_color: Color) -> StyleBoxFlat:
	# Returns the badge background appropriate to the active theme.
	# Classic theme: solid colored block (uses cat_color as bg).
	# godotshaders.com theme: transparent — the category color goes on the text.
	if _badge_styles.has(category):
		return _badge_styles[category]
	var s := StyleBoxFlat.new()
	if _badge_style_mode == BADGE_STYLE_BLOCK_TOP:
		s.bg_color = cat_color
		s.set_corner_radius(CORNER_TOP_LEFT, 6)
		s.set_corner_radius(CORNER_TOP_RIGHT, 6)
		s.content_margin_left = 10
		s.content_margin_right = 10
		s.content_margin_top = 6
		s.content_margin_bottom = 6
	else:
		s.bg_color = Color(0, 0, 0, 0)
		s.set_corner_radius_all(4)
		s.content_margin_left = 4
		s.content_margin_right = 4
		s.content_margin_top = 2
		s.content_margin_bottom = 2
	_badge_styles[category] = s
	return s

func _get_badge_hover_style(category: String, cat_color: Color) -> StyleBoxFlat:
	if _badge_hover_styles.has(category):
		return _badge_hover_styles[category]
	var s := StyleBoxFlat.new()
	if _badge_style_mode == BADGE_STYLE_BLOCK_TOP:
		s.bg_color = cat_color.lightened(0.35)
		s.set_corner_radius(CORNER_TOP_LEFT, 6)
		s.set_corner_radius(CORNER_TOP_RIGHT, 6)
		s.content_margin_left = 10
		s.content_margin_right = 10
		s.content_margin_top = 6
		s.content_margin_bottom = 6
		s.border_width_left = 1
		s.border_width_right = 1
		s.border_width_top = 1
		s.border_width_bottom = 1
		s.border_color = Color(1, 1, 1, 0.6)
	else:
		s.bg_color = Color(cat_color.r, cat_color.g, cat_color.b, 0.18)
		s.set_corner_radius_all(4)
		s.content_margin_left = 4
		s.content_margin_right = 4
		s.content_margin_top = 2
		s.content_margin_bottom = 2
	_badge_hover_styles[category] = s
	return s

func _make_pill_stylebox(bg: Color, border: Color, radius: int = 18) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.border_color = border
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s

func _get_pill_button_theme() -> Theme:
	# Lazily build (once) and reuse for every pill-styled Button-derived control:
	# filter MenuButtons, sort OptionButton, and Preview/Install on every card.
	if _pill_button_theme == null:
		var t := Theme.new()
		var normal := _make_pill_stylebox(Color(1, 1, 1, 0.02), Color(1, 1, 1, 0.18))
		var hover := _make_pill_stylebox(Color(1, 1, 1, 0.06), Color(1, 1, 1, 0.35))
		var pressed := _make_pill_stylebox(Color(1, 1, 1, 0.10), Color(1, 1, 1, 0.5))
		var focus := _make_pill_stylebox(Color(1, 1, 1, 0.02), accent)
		t.set_stylebox("normal", "Button", normal)
		t.set_stylebox("hover", "Button", hover)
		t.set_stylebox("pressed", "Button", pressed)
		t.set_stylebox("focus", "Button", focus)
		t.set_stylebox("disabled", "Button", normal)
		# MenuButton and OptionButton inherit Button styles, but apply explicitly
		# anyway so popup arrows look consistent.
		t.set_stylebox("normal", "MenuButton", normal)
		t.set_stylebox("hover", "MenuButton", hover)
		t.set_stylebox("pressed", "MenuButton", pressed)
		t.set_stylebox("focus", "MenuButton", focus)
		t.set_stylebox("normal", "OptionButton", normal)
		t.set_stylebox("hover", "OptionButton", hover)
		t.set_stylebox("pressed", "OptionButton", pressed)
		t.set_stylebox("focus", "OptionButton", focus)
		_pill_button_theme = t
	return _pill_button_theme

func _get_pill_lineedit_theme() -> Theme:
	if _pill_lineedit_theme == null:
		var t := Theme.new()
		var normal := _make_pill_stylebox(Color(1, 1, 1, 0.02), Color(1, 1, 1, 0.18))
		var focus := _make_pill_stylebox(Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.45))
		t.set_stylebox("normal", "LineEdit", normal)
		t.set_stylebox("focus", "LineEdit", focus)
		t.set_stylebox("read_only", "LineEdit", normal)
		_pill_lineedit_theme = t
	return _pill_lineedit_theme

func _apply_pill_to_button(btn: Control) -> void:
	# Only the godotshaders.com theme uses pills. Classic keeps the editor look.
	if _badge_style_mode != BADGE_STYLE_TEXT_BOTTOM:
		return
	btn.theme = _get_pill_button_theme()

func _apply_pill_to_lineedit(le: LineEdit) -> void:
	if _badge_style_mode != BADGE_STYLE_TEXT_BOTTOM:
		return
	le.theme = _get_pill_lineedit_theme()

func _get_badge_theme(cat: String, cat_color: Color) -> Theme:
	# Build the badge theme once per category and reuse it for every card in
	# that category. Saves ~12 theme overrides × 40 cards = ~480 theme-update
	# calls per page flip, which was the biggest hot spot.
	if _badge_themes.has(cat):
		return _badge_themes[cat]
	var t := Theme.new()
	var font := _get_badge_font()
	t.set_font("font", "Button", font)
	t.set_constant("outline_size", "Button", 0)
	var fsize: int = 12 if _badge_style_mode == BADGE_STYLE_BLOCK_TOP else 11
	t.set_font_size("font_size", "Button", fsize)
	if _badge_style_mode == BADGE_STYLE_BLOCK_TOP:
		t.set_color("font_color", "Button", Color.WHITE)
		t.set_color("font_hover_color", "Button", Color.WHITE)
		t.set_color("font_pressed_color", "Button", Color.WHITE)
		t.set_color("font_focus_color", "Button", Color.WHITE)
	else:
		t.set_color("font_color", "Button", cat_color)
		t.set_color("font_hover_color", "Button", cat_color.lightened(0.25))
		t.set_color("font_pressed_color", "Button", cat_color.lightened(0.4))
		t.set_color("font_focus_color", "Button", cat_color)
	var normal_style := _get_badge_style(cat, cat_color)
	var hover_style := _get_badge_hover_style(cat, cat_color)
	t.set_stylebox("normal", "Button", normal_style)
	t.set_stylebox("hover", "Button", hover_style)
	t.set_stylebox("pressed", "Button", hover_style)
	t.set_stylebox("focus", "Button", normal_style)
	t.set_stylebox("disabled", "Button", normal_style)
	_badge_themes[cat] = t
	return t

func _create_category_badge(cat: String, cat_color: Color, raw_cat: String) -> Button:
	# Hot path — runs once per card. Theme assignment is one operation; the old
	# per-override approach cost ~12 theme-update calls per badge.
	var badge = Button.new()
	badge.text = raw_cat.to_upper().replace("_", " ").substr(0, 12)
	badge.theme = _get_badge_theme(cat, cat_color)
	badge.focus_mode = Control.FOCUS_NONE
	badge.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	badge.pressed.connect(_on_badge_pressed.bind(raw_cat))
	return badge

func _category_emoji(cat_upper: String) -> String:
	match cat_upper:
		"SPATIAL": return "🎲"
		"CANVAS ITEM": return "🎨"
		"SKY": return "☁️"
		"PARTICLES": return "✨"
		"FOG": return "🌫️"
		_: return "🔷"

func _create_card(shader: Dictionary) -> Control:
	# Builds the card skeleton with all child controls in place. Mutable parts
	# (title text, badge, colors, etc.) are populated by _populate_card, which
	# is also what runs on every subsequent filter change to reuse this card
	# instead of allocating a fresh node tree.
	var card = PanelContainer.new()
	card.custom_minimum_size = _scaled_card_size
	card.mouse_filter = Control.MOUSE_FILTER_STOP

	var style := _get_card_default_style()
	card.add_theme_stylebox_override("panel", style)
	card.set_meta("default_style", style)
	card.set_meta("hover_style", _get_card_hover_style())

	card.mouse_entered.connect(_on_card_hover.bind(card, true))
	card.mouse_exited.connect(_on_card_hover.bind(card, false))

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	card.add_child(vbox)

	# Classic theme: badge sits above the image. Built once here; only its text
	# + theme update on _populate_card.
	var top_badge: Button = null
	if _badge_style_mode == BADGE_STYLE_BLOCK_TOP:
		top_badge = _create_category_badge_pooled(card)
		vbox.add_child(top_badge)

	var img_container = MarginContainer.new()
	img_container.custom_minimum_size = Vector2(0, _scaled_img_height)
	img_container.name = "ImageContainer"
	img_container.clip_contents = true
	img_container.add_theme_constant_override("margin_left", 0)
	img_container.add_theme_constant_override("margin_right", 0)
	img_container.add_theme_constant_override("margin_top", 0)
	img_container.add_theme_constant_override("margin_bottom", 0)
	vbox.add_child(img_container)

	var img_bg = ColorRect.new()
	img_bg.name = "ImgBg"
	img_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	img_container.add_child(img_bg)

	# Persistent TextureRect — reused across every shader on this card slot
	# instead of allocating a new one on each image load. Hidden until an image
	# is actually applied.
	var image_rect := TextureRect.new()
	image_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	image_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	image_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image_rect.visible = false
	img_container.add_child(image_rect)

	var center = CenterContainer.new()
	center.name = "PlaceholderCenter"
	img_container.add_child(center)

	var icon_vbox = VBoxContainer.new()
	icon_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(icon_vbox)

	var icon = Label.new()
	icon.add_theme_font_size_override("font_size", 36)
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_vbox.add_child(icon)

	# Video badge overlay — always built, visibility toggles per shader.
	var video_overlay = VBoxContainer.new()
	video_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bspacer = Control.new()
	bspacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bspacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	video_overlay.add_child(bspacer)
	var badge_hbox = HBoxContainer.new()
	badge_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_hbox.add_theme_constant_override("separation", 0)
	var bhspacer = Control.new()
	bhspacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bhspacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_hbox.add_child(bhspacer)
	var video_badge = Label.new()
	video_badge.text = " ▶ "
	video_badge.add_theme_font_size_override("font_size", 9)
	video_badge.add_theme_color_override("font_color", Color.WHITE)
	video_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	video_badge.add_theme_stylebox_override("normal", _get_video_badge_style())
	badge_hbox.add_child(video_badge)
	video_overlay.add_child(badge_hbox)
	img_container.add_child(video_overlay)

	# Loading bar — a thin indeterminate strip pinned to the top of the image
	# area, shown while a hovered GIF decodes. img_container is a MarginContainer
	# (forces children to fill), so we use a filling VBox with the thin track as
	# its top row and an expanding spacer below — same trick as video_overlay.
	# Added last so it draws on top.
	var bar_h: float = maxf(3.0, 3.0 * _editor_scale)
	var load_overlay = VBoxContainer.new()
	load_overlay.name = "LoadOverlay"
	load_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	load_overlay.add_theme_constant_override("separation", 0)
	load_overlay.visible = false
	var load_bar_track = ColorRect.new()
	load_bar_track.color = Color(0, 0, 0, 0.35)
	load_bar_track.clip_contents = true
	load_bar_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	load_bar_track.custom_minimum_size = Vector2(0, bar_h)
	load_bar_track.size_flags_horizontal = SIZE_EXPAND_FILL
	load_overlay.add_child(load_bar_track)
	var load_bar_spacer = Control.new()
	load_bar_spacer.size_flags_vertical = SIZE_EXPAND_FILL
	load_bar_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	load_overlay.add_child(load_bar_spacer)
	var load_bar_fill = ColorRect.new()
	load_bar_fill.color = accent
	load_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	load_bar_fill.size = Vector2(0, bar_h)
	load_bar_track.add_child(load_bar_fill)
	img_container.add_child(load_overlay)
	card.set_meta("load_overlay", load_overlay)
	card.set_meta("load_bar_track", load_bar_track)
	card.set_meta("load_bar_fill", load_bar_fill)

	var content_margin = MarginContainer.new()
	content_margin.add_theme_constant_override("margin_left", 10)
	content_margin.add_theme_constant_override("margin_right", 10)
	content_margin.add_theme_constant_override("margin_bottom", 8)
	content_margin.size_flags_vertical = SIZE_EXPAND_FILL
	vbox.add_child(content_margin)

	var content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 3)
	content_margin.add_child(content)

	var title = Label.new()
	title.add_theme_font_size_override("font_size", 13)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	title.custom_minimum_size.y = 36
	content.add_child(title)

	var author = Label.new()
	author.add_theme_font_size_override("font_size", 11)
	author.add_theme_color_override("font_color", text_dim)
	content.add_child(author)

	var spacer = Control.new()
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(spacer)

	var info_row = HBoxContainer.new()
	info_row.add_theme_constant_override("separation", 8)
	content.add_child(info_row)

	var bottom_badge: Button = null
	if _badge_style_mode == BADGE_STYLE_TEXT_BOTTOM:
		bottom_badge = _create_category_badge_pooled(card)
		info_row.add_child(bottom_badge)

	var lic = Label.new()
	lic.add_theme_font_size_override("font_size", 10)
	lic.add_theme_color_override("font_color", text_dim)
	info_row.add_child(lic)

	var info_spacer = Control.new()
	info_spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	info_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_row.add_child(info_spacer)

	var likes = Label.new()
	likes.add_theme_font_size_override("font_size", 10)
	likes.add_theme_color_override("font_color", text_dim)
	info_row.add_child(likes)

	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	content.add_child(btn_row)

	var preview_btn = Button.new()
	preview_btn.text = tr_key("preview")
	preview_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	preview_btn.pressed.connect(_on_card_preview_pressed.bind(card))
	_apply_pill_to_button(preview_btn)
	btn_row.add_child(preview_btn)

	var install_btn = Button.new()
	install_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	if has_meta("select_mode") and get_meta("select_mode"):
		install_btn.text = "Select"
		install_btn.pressed.connect(_on_card_select_pressed.bind(card))
	else:
		install_btn.text = tr_key("install")
		install_btn.pressed.connect(_on_card_install_pressed.bind(card))
	_apply_pill_to_button(install_btn)
	btn_row.add_child(install_btn)

	# Store refs to mutable nodes so _populate_card can update them in O(1).
	card.set_meta("img_bg", img_bg)
	card.set_meta("image_rect", image_rect)
	card.set_meta("placeholder_center", center)
	card.set_meta("icon_label", icon)
	card.set_meta("video_overlay", video_overlay)
	card.set_meta("title_label", title)
	card.set_meta("author_label", author)
	card.set_meta("lic_label", lic)
	card.set_meta("likes_label", likes)
	if top_badge:
		card.set_meta("badge_button", top_badge)
	if bottom_badge:
		card.set_meta("badge_button", bottom_badge)
	card.set_meta("img_container", img_container)

	_populate_card(card, shader)
	return card

func _create_category_badge_pooled(card: Control) -> Button:
	# Same shape as _create_category_badge but uses a card-bound generic handler
	# so the same button can serve any shader the card is later populated with.
	var badge = Button.new()
	badge.focus_mode = Control.FOCUS_NONE
	badge.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	badge.pressed.connect(_on_card_badge_pressed.bind(card))
	return badge

func _populate_card(card: Control, shader: Dictionary) -> void:
	# Hot path on every filter change / page flip. Strategy:
	# - skip entirely if the same shader is already shown here
	# - read precomputed colors and themes from the shader dict (no per-call
	#   string ops or Color.darkened/lightened allocations)
	# - skip individual setters when the value is already applied, to avoid the
	#   theme-update propagation cost that comes with overrides and theme=
	if card.has_meta("shader") and card.get_meta("shader") == shader:
		return
	card.set_meta("shader", shader)

	var img_bg_color: Color = shader.get("_img_bg_color", Color(0.15, 0.18, 0.2))
	var emoji_color: Color = shader.get("_emoji_color", Color(0.6, 0.6, 0.6))
	var emoji: String = shader.get("_emoji", "🔷")

	# Background tint — skip if unchanged (same category in same slot across
	# pages is common after sort by likes/alpha).
	var img_bg: ColorRect = card.get_meta("img_bg")
	if img_bg.color != img_bg_color:
		img_bg.color = img_bg_color

	var icon_label: Label = card.get_meta("icon_label")
	if icon_label.text != emoji:
		icon_label.text = emoji
	if (not icon_label.has_theme_color_override("font_color")) \
			or icon_label.get_theme_color("font_color") != emoji_color:
		icon_label.add_theme_color_override("font_color", emoji_color)

	# Video indicator visibility.
	var has_video: bool = shader.get("_has_video", false)
	var video_overlay: VBoxContainer = card.get_meta("video_overlay")
	if video_overlay.visible != has_video:
		video_overlay.visible = has_video

	# Free any leftover GifPlayer from the previous shader on this slot.
	var img_container: MarginContainer = card.get_meta("img_container")
	var freed_gif: bool = false
	for ch in img_container.get_children():
		if ch is GifPlayer:
			ch.queue_free()
			freed_gif = true
	# Content on this card no longer matches the (new) shader.
	card.set_meta("loaded_url", "")
	# Drop the hover-to-animate references — the player above is being freed.
	# (Use remove_meta; get_meta with a null default raises an error on a missing
	# key, so we rely on has_meta guards everywhere gif_player is read.)
	if card.has_meta("gif_player"):
		card.remove_meta("gif_player")
	if card.has_meta("gif_url"):
		card.remove_meta("gif_url")
	# Cancel any loading bar/tween left over from the previous shader.
	_set_card_loading(card, false)
	if _hovered_card == card:
		_hovered_card = null
		_hover_gen += 1

	# Image-area handling: keep the previous shader's still image visible until
	# the new content swaps in (avoids a dark flash during the populate→apply
	# window). Exceptions where we fall back to the emoji placeholder now:
	# - no image_url → nothing will ever arrive
	# - previous content was a GIF player (just freed) → image_rect is empty
	var image_rect: TextureRect = card.get_meta("image_rect")
	var placeholder: CenterContainer = card.get_meta("placeholder_center")
	if shader.get("image_url", "").is_empty():
		image_rect.texture = null
		image_rect.visible = false
		placeholder.visible = true
	elif freed_gif or not image_rect.visible:
		placeholder.visible = true

	# Text labels — Godot already short-circuits Label.text setter when value
	# matches, so we can call unconditionally.
	(card.get_meta("title_label") as Label).text = shader.get("title", "Shader")
	(card.get_meta("author_label") as Label).text = shader.get("author", "Unknown")
	(card.get_meta("lic_label") as Label).text = shader.get("license", "CC0")
	(card.get_meta("likes_label") as Label).text = shader.get("_likes_str", "♡ 0")

	# Category badge — Theme assignment triggers NOTIFICATION_THEME_CHANGED on
	# the button and a full style/font recompute. Skip when nothing changed.
	if card.has_meta("badge_button"):
		var b: Button = card.get_meta("badge_button")
		var disp_cat: String = shader.get("_disp_cat", "")
		if b.text != disp_cat:
			b.text = disp_cat
		var bt: Theme = shader.get("_badge_theme")
		if bt != null and b.theme != bt:
			b.theme = bt

func _on_card_preview_pressed(card: Control) -> void:
	_show_preview(card.get_meta("shader", {}))

func _on_card_install_pressed(card: Control) -> void:
	_on_install(card.get_meta("shader", {}))

func _on_card_select_pressed(card: Control) -> void:
	_on_select_shader(card.get_meta("shader", {}))

func _on_card_badge_pressed(card: Control) -> void:
	var shader: Dictionary = card.get_meta("shader", {})
	_on_badge_pressed(shader.get("category", ""))

func _on_prev() -> void:
	if current_page > 1:
		current_page -= 1
		_display_page()
		scroll_container.scroll_vertical = 0

func _on_next() -> void:
	var total = ceili(float(filtered_shaders.size()) / shaders_per_page)
	if current_page < total:
		current_page += 1
		_display_page()
		scroll_container.scroll_vertical = 0

func _on_refresh() -> void:
	# Don't clear cache before refresh - only clear if GitHub succeeds
	status_label.text = tr_key("refreshing")
	progress_bar.visible = true
	progress_bar.value = 50
	progress_bar.max_value = 100
	cache_manager.fetch_from_github()

func _on_install(shader: Dictionary) -> void:
	shader_installer.install_shader(shader)

## Select shader in select mode - install first if needed, then select
func _on_select_shader(shader: Dictionary) -> void:
	# Check if shader is already installed
	if shader.has("path") and not shader.get("path", "").is_empty():
		# Already installed - select directly
		_select_shader_path(shader.get("path"))
	else:
		# Need to install first - store that we're in select mode for this install
		set_meta("pending_select", true)
		shader_installer.install_shader(shader)

func _select_shader_path(path: String) -> void:
	if has_meta("selector_dialog"):
		var dialog = get_meta("selector_dialog")
		if dialog and dialog.has_method("select_shader"):
			dialog.select_shader(path)

func _on_install_started(shader_name: String) -> void:
	status_label.text = tr_key("installing") % shader_name
	progress_bar.visible = true
	progress_bar.value = 0

func _on_install_progress(shader_name: String, progress: float, status_text: String) -> void:
	status_label.text = "⏳ " + shader_name + ": " + status_text
	progress_bar.value = progress * 100

func _on_installed(path: String) -> void:
	status_label.text = "✓ " + path
	progress_bar.visible = false
	# Refresh installed count
	if installed_manager:
		installed_manager.scan_installed_shaders()
	
	# If we were installing for select mode, select the shader now
	if has_meta("pending_select") and get_meta("pending_select"):
		set_meta("pending_select", false)
		_select_shader_path(path)

func _on_install_error(error: String) -> void:
	status_label.text = tr_key("error_icon") % error
	progress_bar.visible = false

func _on_error(msg: String) -> void:
	status_label.text = tr_key("error") % msg
	progress_bar.visible = false

func _build_preview_dialog() -> void:
	preview_dialog = Window.new()
	preview_dialog.title = tr_key("shader_preview")
	preview_dialog.size = Vector2i(900, 700)
	preview_dialog.transient = true
	preview_dialog.exclusive = true
	preview_dialog.visible = false
	preview_dialog.close_requested.connect(func():
		var ic = preview_dialog.find_child("ImageContainer", true, false)
		if ic:
			for ch in ic.get_children():
				if ch is GifPlayer: ch.queue_free()
		preview_dialog.hide()
	)
	add_child(preview_dialog)
	
	var panel = PanelContainer.new()
	panel.set_anchors_preset(PRESET_FULL_RECT)
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.11, 0.11, 0.14)
	panel.add_theme_stylebox_override("panel", panel_style)
	preview_dialog.add_child(panel)
	
	# Main scroll container
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	
	var margin = MarginContainer.new()
	margin.size_flags_horizontal = SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	scroll.add_child(margin)
	
	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 16)
	margin.add_child(vbox)
	
	# ===== IMAGE PREVIEW =====
	var img_container = PanelContainer.new()
	img_container.name = "ImageContainer"
	img_container.custom_minimum_size = Vector2(0, 250)
	var img_style = StyleBoxFlat.new()
	img_style.bg_color = Color(0.15, 0.15, 0.18)
	img_style.set_corner_radius_all(8)
	img_container.add_theme_stylebox_override("panel", img_style)
	vbox.add_child(img_container)
	
	# Placeholder center for image loading
	var img_center = CenterContainer.new()
	img_center.name = "ImageCenter"
	img_center.set_anchors_preset(PRESET_FULL_RECT)
	img_container.add_child(img_center)
	
	var img_loading = Label.new()
	img_loading.name = "ImageLoading"
	img_loading.text = tr_key("loading_image")
	img_loading.add_theme_color_override("font_color", text_dim)
	img_center.add_child(img_loading)
	
	# ===== TITLE ROW =====
	var title_row = HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 16)
	vbox.add_child(title_row)
	
	var title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.add_theme_font_size_override("font_size", 22)
	title_label.add_theme_color_override("font_color", Color.WHITE)
	title_label.size_flags_horizontal = SIZE_EXPAND_FILL
	title_row.add_child(title_label)
	
	# ===== AUTHOR & META ROW =====
	var meta_row = HBoxContainer.new()
	meta_row.add_theme_constant_override("separation", 16)
	vbox.add_child(meta_row)
	
	var author_label = Label.new()
	author_label.name = "AuthorLabel"
	author_label.add_theme_font_size_override("font_size", 14)
	author_label.add_theme_color_override("font_color", text_dim)
	meta_row.add_child(author_label)
	
	var sep1 = Label.new()
	sep1.text = "•"
	sep1.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	meta_row.add_child(sep1)
	
	var category_label = Label.new()
	category_label.name = "CategoryLabel"
	category_label.add_theme_font_size_override("font_size", 14)
	category_label.add_theme_color_override("font_color", accent)
	meta_row.add_child(category_label)
	
	var sep2 = Label.new()
	sep2.text = "•"
	sep2.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	meta_row.add_child(sep2)
	
	var license_label = Label.new()
	license_label.name = "LicenseLabel"
	license_label.add_theme_font_size_override("font_size", 14)
	license_label.add_theme_color_override("font_color", Color(0.5, 0.8, 0.5))
	meta_row.add_child(license_label)
	
	var sep3 = Label.new()
	sep3.text = "•"
	sep3.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	meta_row.add_child(sep3)
	
	var likes_label = Label.new()
	likes_label.name = "LikesLabel"
	likes_label.add_theme_font_size_override("font_size", 14)
	likes_label.add_theme_color_override("font_color", Color(0.9, 0.5, 0.5))
	meta_row.add_child(likes_label)
	
	var meta_spacer = Control.new()
	meta_spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	meta_row.add_child(meta_spacer)
	
	# ===== DATE =====
	var date_label = Label.new()
	date_label.name = "DateLabel"
	date_label.add_theme_font_size_override("font_size", 14)
	date_label.add_theme_color_override("font_color", text_dim)
	meta_row.add_child(date_label)
	
	# ===== DESCRIPTION =====
	var desc_panel = PanelContainer.new()
	desc_panel.name = "DescPanel"
	desc_panel.visible = false  # Hidden until loaded
	var desc_style = StyleBoxFlat.new()
	desc_style.bg_color = Color(0.13, 0.13, 0.16)
	desc_style.set_corner_radius_all(6)
	desc_style.content_margin_left = 16
	desc_style.content_margin_right = 16
	desc_style.content_margin_top = 12
	desc_style.content_margin_bottom = 12
	desc_panel.add_theme_stylebox_override("panel", desc_style)
	vbox.add_child(desc_panel)
	
	var desc_label = RichTextLabel.new()
	desc_label.name = "DescLabel"
	desc_label.bbcode_enabled = true
	desc_label.fit_content = true
	desc_label.scroll_active = false
	desc_label.meta_underlined = true  # Enable underline for clickable links
	desc_label.hint_underlined = true  # Show hint when hovering
	desc_label.add_theme_color_override("default_color", Color(0.85, 0.85, 0.85))
	desc_label.add_theme_font_size_override("normal_font_size", 14)
	desc_label.meta_clicked.connect(_on_link_clicked)
	desc_panel.add_child(desc_label)
	
	# ===== TAGS =====
	var tags_row = HBoxContainer.new()
	tags_row.name = "TagsRow"
	tags_row.visible = false  # Hidden until loaded
	tags_row.add_theme_constant_override("separation", 8)
	vbox.add_child(tags_row)
	
	var tags_icon = Label.new()
	tags_icon.text = "🏷️"
	tags_row.add_child(tags_icon)
	
	var tags_label = Label.new()
	tags_label.name = "TagsLabel"
	tags_label.add_theme_font_size_override("font_size", 12)
	tags_label.add_theme_color_override("font_color", accent)
	tags_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	tags_label.size_flags_horizontal = SIZE_EXPAND_FILL
	tags_row.add_child(tags_label)
	
	# ===== INFO HINT =====
	var hint_label = Label.new()
	hint_label.text = tr_key("hint_browser")
	hint_label.add_theme_font_size_override("font_size", 12)
	hint_label.add_theme_color_override("font_color", text_dim)
	vbox.add_child(hint_label)
	
	# ===== SHADER CODE SECTION =====
	var code_header = Label.new()
	code_header.text = "Shader Code"
	code_header.add_theme_font_size_override("font_size", 16)
	code_header.add_theme_color_override("font_color", Color.WHITE)
	vbox.add_child(code_header)
	
	# Code container with border
	var code_panel = PanelContainer.new()
	code_panel.custom_minimum_size = Vector2(0, 300)
	var code_style = StyleBoxFlat.new()
	code_style.bg_color = Color(0.08, 0.08, 0.10)
	code_style.set_corner_radius_all(6)
	code_style.set_border_width_all(1)
	code_style.border_color = Color(0.25, 0.25, 0.3)
	code_panel.add_theme_stylebox_override("panel", code_style)
	vbox.add_child(code_panel)
	
	preview_code_edit = CodeEdit.new()
	preview_code_edit.size_flags_vertical = SIZE_EXPAND_FILL
	preview_code_edit.size_flags_horizontal = SIZE_EXPAND_FILL
	preview_code_edit.editable = false
	preview_code_edit.gutters_draw_line_numbers = true
	preview_code_edit.syntax_highlighter = _create_shader_highlighter()
	preview_code_edit.add_theme_font_size_override("font_size", 13)
	preview_code_edit.custom_minimum_size = Vector2(0, 280)
	code_panel.add_child(preview_code_edit)
	
	# Loading label (overlay)
	var loading_label = Label.new()
	loading_label.name = "LoadingLabel"
	loading_label.text = tr_key("fetching_code")
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	loading_label.add_theme_color_override("font_color", text_dim)
	loading_label.set_anchors_preset(PRESET_CENTER)
	loading_label.visible = false
	code_panel.add_child(loading_label)
	
	# ===== BUTTONS =====
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)
	
	var view_btn = Button.new()
	view_btn.text = tr_key("open_browser")
	view_btn.pressed.connect(func(): OS.shell_open(preview_shader.get("url", "")))
	btn_row.add_child(view_btn)

	var video_btn = Button.new()
	video_btn.name = "VideoBtn"
	video_btn.text = tr_key("watch_video")
	video_btn.visible = false
	video_btn.pressed.connect(func():
		var vurl = preview_shader.get("video_url", "")
		if vurl.is_empty():
			var img = preview_shader.get("image_url", "")
			if img.to_lower().ends_with(".gif"):
				vurl = img
		OS.shell_open(vurl)
	)
	btn_row.add_child(video_btn)

	var copy_btn = Button.new()
	copy_btn.text = tr_key("copy_code")
	copy_btn.pressed.connect(func(): DisplayServer.clipboard_set(preview_code_edit.text))
	btn_row.add_child(copy_btn)
	
	var cancel_btn = Button.new()
	cancel_btn.text = "X"
	cancel_btn.pressed.connect(func(): preview_dialog.hide())
	btn_row.add_child(cancel_btn)
	
	var install_btn = Button.new()
	install_btn.name = "InstallBtn"
	install_btn.text = tr_key("install")
	install_btn.pressed.connect(_on_preview_install)
	btn_row.add_child(install_btn)

func _create_shader_highlighter() -> CodeHighlighter:
	var highlighter = CodeHighlighter.new()
	
	# Keywords
	var keywords = ["shader_type", "render_mode", "uniform", "varying", "const", 
		"void", "float", "int", "bool", "vec2", "vec3", "vec4", "mat2", "mat3", "mat4",
		"sampler2D", "sampler3D", "samplerCube", "if", "else", "for", "while", "return",
		"discard", "true", "false", "in", "out", "inout", "lowp", "mediump", "highp",
		"hint_color", "hint_range", "hint_albedo", "hint_normal", "source_color",
		"canvas_item", "spatial", "particles", "sky", "fog"]
	
	for keyword in keywords:
		highlighter.add_keyword_color(keyword, Color(0.8, 0.5, 0.3))
	
	# Built-in functions
	var functions = ["texture", "textureLod", "sin", "cos", "tan", "pow", "sqrt", "abs",
		"min", "max", "clamp", "mix", "step", "smoothstep", "length", "distance", "dot",
		"cross", "normalize", "reflect", "refract", "fract", "floor", "ceil", "mod",
		"sign", "radians", "degrees", "exp", "log", "exp2", "log2", "inversesqrt",
		"VERTEX", "FRAGCOORD", "UV", "COLOR", "TIME", "NORMAL", "TANGENT", "BINORMAL",
		"SCREEN_UV", "SCREEN_TEXTURE", "ALBEDO", "EMISSION", "ROUGHNESS", "METALLIC",
		"ALPHA", "LIGHT", "ATTENUATION", "SHADOW", "SPECULAR_SHININESS"]
	
	for func_name in functions:
		highlighter.add_keyword_color(func_name, Color(0.4, 0.7, 0.9))
	
	# Numbers
	highlighter.number_color = Color(0.6, 0.9, 0.6)
	
	# Comments
	highlighter.add_color_region("//", "", Color(0.5, 0.5, 0.5), true)
	highlighter.add_color_region("/*", "*/", Color(0.5, 0.5, 0.5))
	
	# Strings
	highlighter.add_color_region("\"", "\"", Color(0.8, 0.7, 0.5))
	
	return highlighter

func _show_preview(shader: Dictionary) -> void:
	# Lazy build on first use — keeps editor startup fast.
	if preview_dialog == null:
		_build_preview_dialog()
	preview_shader = shader

	# Update title
	var title_lbl = preview_dialog.find_child("TitleLabel", true, false)
	if title_lbl:
		title_lbl.text = shader.get("title", "Shader")
	
	# Update author
	var author_lbl = preview_dialog.find_child("AuthorLabel", true, false)
	if author_lbl:
		author_lbl.text = "👤 " + shader.get("author", "Unknown")
	
	# Update category
	var cat_lbl = preview_dialog.find_child("CategoryLabel", true, false)
	if cat_lbl:
		cat_lbl.text = shader.get("category", "Unknown")
	
	# Update license
	var license_lbl = preview_dialog.find_child("LicenseLabel", true, false)
	if license_lbl:
		license_lbl.text = "📜 " + shader.get("license", "CC0")
	
	# Update likes
	var likes_lbl = preview_dialog.find_child("LikesLabel", true, false)
	if likes_lbl:
		likes_lbl.text = "♥ " + str(shader.get("likes", 0))
	
	# Reset image container
	var img_container = preview_dialog.find_child("ImageContainer", true, false)
	var img_center = preview_dialog.find_child("ImageCenter", true, false)
	var img_loading = preview_dialog.find_child("ImageLoading", true, false)
	
	if img_container:
		# Remove old media (TextureRect and GifPlayer) before showing new shader
		for child in img_container.get_children():
			if child is TextureRect or child is GifPlayer:
				child.queue_free()
		if img_loading:
			img_loading.visible = true
	
	# Reset description and tags (will be shown after loading)
	var desc_panel = preview_dialog.find_child("DescPanel", true, false)
	if desc_panel:
		desc_panel.visible = false
	
	var tags_row = preview_dialog.find_child("TagsRow", true, false)
	if tags_row:
		tags_row.visible = false
	
	var date_lbl = preview_dialog.find_child("DateLabel", true, false)
	if date_lbl:
		date_lbl.text = ""
	
	# Clear code and show loading
	preview_code_edit.text = ""
	preview_code_edit.visible = false
	
	var loading_lbl = preview_dialog.find_child("LoadingLabel", true, false)
	if loading_lbl:
		loading_lbl.visible = true
	
	var install_btn = preview_dialog.find_child("InstallBtn", true, false)
	if install_btn:
		install_btn.disabled = true
	
	# Show/hide Watch Video button (video_url or GIF image_url)
	var video_btn = preview_dialog.find_child("VideoBtn", true, false)
	if video_btn:
		var video_url = shader.get("video_url", "")
		if video_url.is_empty():
			var img = shader.get("image_url", "")
			if img.to_lower().ends_with(".gif"):
				video_url = img
		video_btn.visible = not video_url.is_empty()

	# Show dialog
	preview_dialog.popup_centered()

	# Load preview image
	var img_url = shader.get("image_url", "")
	if not img_url.is_empty():
		_load_preview_image(img_url)
	
	# Fetch shader code
	var url = shader.get("url", "")
	if not url.is_empty():
		preview_http.request(url)

func _load_preview_image(url: String) -> void:
	if url.to_lower().ends_with(".gif"):
		# Check GIF cache first
		if cache_manager.has_cached_image(url):
			var cached_path = cache_manager.get_image_cache_path(url)
			var gif_file = FileAccess.open(cached_path, FileAccess.READ)
			if gif_file:
				var gif_data = gif_file.get_buffer(gif_file.get_length())
				gif_file.close()
				_apply_gif_to_preview(gif_data)
				return
		# Download and decode GIF
		var img_http = HTTPRequest.new()
		img_http.timeout = 20
		add_child(img_http)
		img_http.request_completed.connect(_on_preview_image_loaded.bind(img_http, url))
		img_http.request(url)
		return

	# Check cache first
	if cache_manager.has_cached_image(url):
		var img = cache_manager.load_cached_image(url)
		if img:
			var tex = ImageTexture.create_from_image(img)
			_apply_preview_image(tex)
			return
	
	# Create separate HTTPRequest for preview image
	var img_http = HTTPRequest.new()
	img_http.timeout = 15
	add_child(img_http)
	img_http.request_completed.connect(_on_preview_image_loaded.bind(img_http, url))
	img_http.request(url)

func _on_preview_image_loaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest, url: String) -> void:
	http.queue_free()
	
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		var img_loading = preview_dialog.find_child("ImageLoading", true, false)
		if img_loading:
			img_loading.text = tr_key("image_load_failed")
		return
	
	# Reject obviously non-image data; otherwise let _load_image_from_buffer try
	# every decoder (handles unusual but valid headers).
	if body.size() < 12:
		var img_loading = preview_dialog.find_child("ImageLoading", true, false)
		if img_loading:
			img_loading.text = tr_key("image_error")
		return

	var fmt = _detect_image_format(body)
	if fmt == "gif":
		cache_manager.cache_image(url, body)
		_apply_gif_to_preview(body)
		return

	var img = _load_image_from_buffer(body)

	if img:
		var tex = ImageTexture.create_from_image(img)
		_apply_preview_image(tex)
		cache_manager.cache_image(url, body)
	else:
		var img_loading = preview_dialog.find_child("ImageLoading", true, false)
		if img_loading:
			img_loading.text = tr_key("image_error")

func _apply_preview_image(tex: Texture2D) -> void:
	var img_container = preview_dialog.find_child("ImageContainer", true, false)
	var img_loading = preview_dialog.find_child("ImageLoading", true, false)
	
	if not img_container:
		return
	
	if img_loading:
		img_loading.visible = false
	
	var tex_rect = TextureRect.new()
	tex_rect.texture = tex
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tex_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	img_container.add_child(tex_rect)
	img_container.move_child(tex_rect, 0)

func _apply_gif_to_preview(data: PackedByteArray) -> void:
	var img_container = preview_dialog.find_child("ImageContainer", true, false)
	var img_loading   = preview_dialog.find_child("ImageLoading", true, false)
	if not img_container: return

	# Remove any previous GIF player in preview
	for child in img_container.get_children():
		if child is GifPlayer: child.queue_free()

	var player = GifPlayer.new()
	player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	img_container.add_child(player)
	img_container.move_child(player, 0)  # ImageCenter stays on top during decode

	var player_ref = weakref(player)
	var decoder = GIFDecoder.new()
	var data_copy = data.duplicate()
	WorkerThreadPool.add_task(func():
		var frames = decoder.decode(data_copy)
		call_deferred("_on_gif_preview_ready", player_ref, frames)
	)


func _on_gif_card_ready(player_ref: WeakRef, frames: Array) -> void:
	var player = player_ref.get_ref()
	if not is_instance_valid(player):
		return
	if frames.is_empty():
		# Decode failed — drop the player and let whatever was previously on the
		# card (image_rect with the prior shader's texture, or the placeholder)
		# keep showing. We never free the placeholder here.
		active_gif_players.erase(player)
		player.queue_free()
		return
	# Decode succeeded — atomically: hide image_rect (which may still be showing
	# the previous shader's poster), set up the first frame, then reveal the
	# player. Doing it in this order means there is no frame where image_rect
	# is hidden AND the player is hidden — no dark/black gap on the card.
	if player.has_meta("card"):
		var card: Control = player.get_meta("card")
		if is_instance_valid(card):
			if card.has_meta("image_rect"):
				var ir: TextureRect = card.get_meta("image_rect")
				ir.texture = null
				ir.visible = false
			if card.has_meta("placeholder_center"):
				(card.get_meta("placeholder_center") as CenterContainer).visible = false
	player.start_frames(frames)
	player.visible = true
	# NOTE: we deliberately do NOT cache the GIF's first frame in _tex_cache.
	# GIFs always route through this GifPlayer path (see _load_next_image) so
	# hover-to-animate has a player to drive; a cached still would bypass that.


func _on_gif_preview_ready(player_ref: WeakRef, frames: Array) -> void:
	var player = player_ref.get_ref()
	if not is_instance_valid(player):
		return
	if frames.is_empty():
		# Decode failed — drop the player so the loading label remains visible.
		player.queue_free()
		return
	var img_loading = preview_dialog.find_child("ImageLoading", true, false)
	if img_loading: img_loading.visible = false
	player.start_frames(frames)

func _on_preview_code_loaded(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var loading_lbl = preview_dialog.find_child("LoadingLabel", true, false)
	if loading_lbl:
		loading_lbl.visible = false
	
	preview_code_edit.visible = true
	
	var install_btn = preview_dialog.find_child("InstallBtn", true, false)
	
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		preview_code_edit.text = tr_key("code_fetch_error")
		if install_btn:
			install_btn.disabled = true
		return
	
	var html = body.get_string_from_utf8()
	
	# Extract additional info from HTML
	_parse_and_display_shader_info(html)
	
	var code = _extract_shader_code_from_html(html)
	
	if code.is_empty():
		preview_code_edit.text = tr_key("code_not_found")
		if install_btn:
			install_btn.disabled = true
	else:
		preview_code_edit.text = code
		if install_btn:
			install_btn.disabled = false

func _parse_and_display_shader_info(html: String) -> void:
	# Extract description (text before shader code)
	var description = _extract_description(html)
	
	if not description.is_empty():
		var desc_panel = preview_dialog.find_child("DescPanel", true, false)
		var desc_lbl = preview_dialog.find_child("DescLabel", true, false)
		if desc_panel and desc_lbl:
			desc_lbl.text = description  # Already contains BBCode
			desc_panel.visible = true
	else:
		# Hide description panel if no description found
		var desc_panel = preview_dialog.find_child("DescPanel", true, false)
		if desc_panel:
			desc_panel.visible = false
	
	# Extract tags
	var tags = _extract_tags(html)
	if not tags.is_empty():
		var tags_row = preview_dialog.find_child("TagsRow", true, false)
		var tags_lbl = preview_dialog.find_child("TagsLabel", true, false)
		if tags_row and tags_lbl:
			tags_lbl.text = _decode_html_entities(tags)
			tags_row.visible = true
	else:
		var tags_row = preview_dialog.find_child("TagsRow", true, false)
		if tags_row:
			tags_row.visible = false
	
	# Extract date
	var date = _extract_date(html)
	if not date.is_empty():
		var date_lbl = preview_dialog.find_child("DateLabel", true, false)
		if date_lbl:
			date_lbl.text = "📅 " + _decode_html_entities(date)
			date_lbl.visible = true
	else:
		var date_lbl = preview_dialog.find_child("DateLabel", true, false)
		if date_lbl:
			date_lbl.visible = false

# Find next real <p> or <p ...> tag position (skip <path>, <pre>, etc.)
func _find_next_p_tag(text: String, from: int) -> int:
	var pos = from
	while true:
		var p_pos = text.find("<p", pos)
		if p_pos == -1:
			return -1
		var next_pos = p_pos + 2
		if next_pos >= text.length():
			return -1
		var nc = text.substr(next_pos, 1)
		if nc == ">" or nc == " " or nc == "\t" or nc == "\n" or nc == "\r":
			return p_pos
		pos = p_pos + 1
	return -1

# Open clicked link in browser with focus
func _on_link_clicked(meta: Variant) -> void:
	var url = str(meta)
	
	# On Windows, use cmd start to open browser with automatic focus
	# Empty string "" after start is the window title (required for URLs)
	if OS.get_name() == "Windows":
		OS.execute("cmd.exe", ["/c", "start", "", url])
	else:
		OS.shell_open(url)

# Convert HTML formatting to BBCode and strip remaining tags
func _html_to_bbcode_and_clean(text: String) -> String:
	var result = text
	
	# Convert <a href="...">text</a> to [url=...]text[/url]
	var link_regex = RegEx.new()
	link_regex.compile("<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>([^<]*)</a>")
	var link_matches = link_regex.search_all(result)
	for i in range(link_matches.size() - 1, -1, -1):  # Reverse to preserve positions
		var m = link_matches[i]
		var full_match = m.get_string()
		var href = m.get_string(1)
		var link_text = m.get_string(2)
		if link_text.is_empty():
			link_text = href
		# Godot BBCode format: [url=href]text[/url]
		var bbcode = "[url=" + href + "][color=#6699ff][u]" + link_text + "[/u][/color][/url]"
		result = result.replace(full_match, bbcode)
	
	result = result.replace("<strong>", "[b]").replace("</strong>", "[/b]")
	result = result.replace("<b>", "[b]").replace("</b>", "[/b]")
	result = result.replace("<em>", "[i]").replace("</em>", "[/i]")
	result = result.replace("<i>", "[i]").replace("</i>", "[/i]")
	result = result.replace("<code>", "[code]").replace("</code>", "[/code]")
	result = result.replace("<br>", "\n").replace("<br/>", "\n").replace("<br />", "\n")
	var tag_regex = RegEx.new()
	tag_regex.compile("<[^>\\[]*>")
	result = tag_regex.sub(result, "", true)
	result = _decode_html_entities(result)
	return result.strip_edges()

# Find matching close tag handling nesting (e.g. nested <ul> inside <ul>)
func _find_closing_tag(text: String, open_tag: String, close_tag: String, from: int) -> int:
	var depth = 1
	var pos = from
	while pos < text.length():
		var next_open = text.find(open_tag, pos)
		var next_close = text.find(close_tag, pos)
		if next_close == -1:
			return -1
		if next_open != -1 and next_open < next_close:
			depth += 1
			pos = next_open + open_tag.length()
		else:
			depth -= 1
			if depth == 0:
				return next_close
			pos = next_close + close_tag.length()
	return -1

func _extract_description(html: String) -> String:
	# Find content area between entry-content div and Shader code section
	var entry_start = html.find("entry-content")
	if entry_start == -1:
		return ""
	var content_div_start = html.find(">", entry_start)
	if content_div_start == -1:
		return ""
	content_div_start += 1
	
	var shader_code_pos = html.find(">Shader code<", content_div_start)
	if shader_code_pos == -1:
		shader_code_pos = html.find("Shader code</h", content_div_start)
	if shader_code_pos == -1:
		shader_code_pos = html.find('class="language-', content_div_start)
	if shader_code_pos == -1:
		return ""
	
	var search_area = html.substr(content_div_start, shader_code_pos - content_div_start)
	var result_parts: Array = []
	var para_index = 0
	var pos = 0
	var prev_element_end = 0
	
	while pos < search_area.length():
		# Find next real <p> tag (not <path>, <pre>, etc.)
		var next_p = _find_next_p_tag(search_area, pos)
		var next_ul = search_area.find("<ul", pos)
		var next_ol = search_area.find("<ol", pos)
		
		# Pick the earliest element
		var min_pos = -1
		var elem_type = ""
		if next_p != -1:
			min_pos = next_p
			elem_type = "p"
		if next_ul != -1 and (min_pos == -1 or next_ul < min_pos):
			min_pos = next_ul
			elem_type = "ul"
		if next_ol != -1 and (min_pos == -1 or next_ol < min_pos):
			min_pos = next_ol
			elem_type = "ol"
		
		if elem_type.is_empty():
			break
		
		if elem_type == "p":
			# === Process paragraph ===
			var tag_end = search_area.find(">", next_p)
			if tag_end == -1:
				break
			var p_end = search_area.find("</p>", tag_end + 1)
			if p_end == -1:
				pos = next_p + 1
				continue
			
			para_index += 1
			pos = p_end + 4
			prev_element_end = pos
			
			# Skip P1 (always navigation menu junk)
			if para_index == 1:
				continue
			
			var raw_para = search_area.substr(tag_end + 1, p_end - tag_end - 1)
			
			# Handle inline lists within paragraphs
			raw_para = raw_para.replace("<ul>", "\n").replace("</ul>", "")
			raw_para = raw_para.replace("<ol>", "\n").replace("</ol>", "")
			var li_regex = RegEx.new()
			li_regex.compile("<li[^>]*>")
			raw_para = li_regex.sub(raw_para, "\n    [color=#88aaff]\u2022[/color] ", true)
			raw_para = raw_para.replace("</li>", "")
			
			var para = _html_to_bbcode_and_clean(raw_para)
			
			# Skip empty/whitespace paragraphs
			if para.replace(" ", "").replace("\t", "").length() < 3:
				continue
			
			# Detect section headers (short text ending with colon, like "Parameters:")
			var colon_pos = para.find(":")
			if colon_pos > 0 and colon_pos < 40:
				var before_colon = para.substr(0, colon_pos).replace("[b]", "").replace("[/b]", "").strip_edges()
				var after_colon = para.substr(colon_pos + 1).strip_edges()
				if before_colon.length() < 35 and not "\n" in before_colon:
					if para.length() < 25 and after_colon.length() < 5:
						# Section header (e.g. "Parameters:", "How to:")
						para = "[b]" + para + "[/b]"
					elif before_colon.length() < 25 and after_colon.length() > 2:
						# List item with label (e.g. "PARAMETER - blur_sharp - ...")
						para = "    [color=#88aaff]\u2022[/color] " + para
			
			result_parts.append(para)
		
		else:
			# === Process list (ul or ol) ===
			var tag_end = search_area.find(">", min_pos)
			if tag_end == -1:
				break
			
			var open_tag = "<ul" if elem_type == "ul" else "<ol"
			var close_tag = "</ul>" if elem_type == "ul" else "</ol>"
			var list_end = _find_closing_tag(search_area, open_tag, close_tag, tag_end + 1)
			if list_end == -1:
				pos = min_pos + 1
				continue
			
			var list_content = search_area.substr(tag_end + 1, list_end - tag_end - 1)
			pos = list_end + close_tag.length()
			
			# Check for standalone <li> header in gap before this list
			var standalone_header = ""
			if prev_element_end > 0 and min_pos > prev_element_end:
				var gap = search_area.substr(prev_element_end, min_pos - prev_element_end)
				var sli_start = gap.rfind("<li")
				if sli_start != -1:
					var sli_tag_end = gap.find(">", sli_start)
					var sli_end = gap.find("</li>", sli_tag_end)
					if sli_tag_end != -1 and sli_end != -1:
						standalone_header = gap.substr(sli_tag_end + 1, sli_end - sli_tag_end - 1)
						standalone_header = _html_to_bbcode_and_clean(standalone_header)
			
			prev_element_end = pos
			
			# Skip navigation list
			if list_content.contains("Upload shader") or list_content.contains("Snippets"):
				continue
			# Skip CSS/junk lists
			if list_content.contains("border-color") or list_content.contains("background-color"):
				continue
			
			# Extract list items
			var items: Array = []
			
			# Add standalone header if found
			if not standalone_header.is_empty() and standalone_header.length() > 1:
				items.append("    [color=#88aaff]\u2022[/color] [b]" + standalone_header + "[/b]")
			
			var li_pos = 0
			var item_idx = 0
			while true:
				var li_start = list_content.find("<li", li_pos)
				if li_start == -1:
					break
				var li_tag_end = list_content.find(">", li_start)
				if li_tag_end == -1:
					break
				var li_end = _find_closing_tag(list_content, "<li", "</li>", li_tag_end + 1)
				if li_end == -1:
					li_pos = li_start + 1
					continue
				
				var item_raw = list_content.substr(li_tag_end + 1, li_end - li_tag_end - 1)
				li_pos = li_end + 5
				
				# Check for nested <ul> inside this <li>
				var nested_ul_pos = item_raw.find("<ul")
				if nested_ul_pos != -1:
					# Extract header text before nested list
					var header_raw = item_raw.substr(0, nested_ul_pos)
					var header = _html_to_bbcode_and_clean(header_raw)
					if header.length() > 0:
						items.append("    [color=#88aaff]\u2022[/color] [b]" + header + "[/b]")
					
					# Extract nested items
					var nested_end = item_raw.find("</ul>", nested_ul_pos)
					if nested_end != -1:
						var nested_content = item_raw.substr(nested_ul_pos, nested_end - nested_ul_pos + 5)
						var npos = 0
						while true:
							var nli = nested_content.find("<li", npos)
							if nli == -1:
								break
							var nli_tag_end = nested_content.find(">", nli)
							if nli_tag_end == -1:
								break
							var nli_end = nested_content.find("</li>", nli_tag_end)
							if nli_end == -1:
								npos = nli + 1
								continue
							var nitem = nested_content.substr(nli_tag_end + 1, nli_end - nli_tag_end - 1)
							npos = nli_end + 5
							nitem = _html_to_bbcode_and_clean(nitem)
							if nitem.length() > 3:
								items.append("        [color=#6688dd]\u25E6[/color] " + nitem)
					continue
				
				# Normal list item
				var item = _html_to_bbcode_and_clean(item_raw)
				if item.length() > 3:
					item_idx += 1
					if elem_type == "ol":
						items.append("    " + str(item_idx) + ". " + item)
					else:
						if standalone_header.is_empty():
							items.append("    [color=#88aaff]\u2022[/color] " + item)
						else:
							items.append("        [color=#6688dd]\u25E6[/color] " + item)
			
			if items.size() > 0:
				result_parts.append("\n".join(items))
	
	if result_parts.is_empty():
		return ""
	
	var content = "\n\n".join(result_parts)
	while content.contains("\n\n\n"):
		content = content.replace("\n\n\n", "\n\n")
	if content.length() > 4000:
		content = content.substr(0, 4000) + "..."
	return content

func _extract_tags(html: String) -> String:
	# Try multiple methods to find tags
	var tags: Array = []
	
	# Method 1: Find Tags section header
	var start = html.find("Tags</h6>")
	if start == -1:
		start = html.find("Tags</h5>")
	if start == -1:
		start = html.find(">Tags<")
	
	if start != -1:
		# Find the tags container (usually ends with a div or before the next section)
		var search_end = html.find("Shader code", start)
		if search_end == -1:
			search_end = mini(start + 2000, html.length())
		
		var tags_section = html.substr(start, search_end - start)
		
		# Method 1a: Extract from href links with shader-tag
		var tag_regex = RegEx.new()
		tag_regex.compile('/shader-tag/([^/"]+)/')
		var results = tag_regex.search_all(tags_section)
		for result in results:
			var tag = result.get_string(1).replace("-", " ").capitalize()
			if tag not in tags and tag.length() > 0:
				tags.append(tag)
		
		# Method 1b: Try extracting text from tag links
		if tags.is_empty():
			var link_regex = RegEx.new()
			link_regex.compile('>([A-Za-z][A-Za-z0-9 _-]{1,30})</a>')
			results = link_regex.search_all(tags_section)
			for result in results:
				var tag = result.get_string(1).strip_edges()
				# Filter out navigation/non-tag links
				if tag not in tags and tag.length() > 1 and tag.length() < 32:
					if not tag.to_lower().contains("sign") and not tag.to_lower().contains("menu"):
						tags.append(tag)
	
	# Method 2: Look for tag links anywhere before "The shader code"
	if tags.is_empty():
		var license_pos = html.find("The shader code")
		if license_pos != -1:
			var before_license = html.substr(maxi(0, license_pos - 1500), 1500)
			var tag_regex = RegEx.new()
			tag_regex.compile('/shader-tag/([^/"]+)/')
			var results = tag_regex.search_all(before_license)
			for result in results:
				var tag = result.get_string(1).replace("-", " ").capitalize()
				if tag not in tags and tag.length() > 0:
					tags.append(tag)
	
	# Clean up HTML entities in tags
	var clean_tags: Array = []
	for tag in tags:
		tag = _decode_html_entities(tag)
		tag = tag.strip_edges()
		if tag.length() > 0:
			clean_tags.append(tag)
	
	return ", ".join(clean_tags)

func _extract_date(html: String) -> String:
	# Try multiple date extraction methods
	
	# Method 1: Standard datetime attribute
	var regex = RegEx.new()
	regex.compile('datetime="([^"]+)"[^>]*>([^<]+)</time>')
	var result = regex.search(html)
	if result:
		return result.get_string(2).strip_edges()
	
	# Method 2: Look for date pattern in text (Month Day, Year)
	regex = RegEx.new()
	regex.compile('(January|February|March|April|May|June|July|August|September|October|November|December)\\s+\\d{1,2},?\\s+\\d{4}')
	result = regex.search(html)
	if result:
		return result.get_string(0)
	
	# Method 3: ISO date format (YYYY-MM-DD)
	regex = RegEx.new()
	regex.compile('datetime="(\\d{4}-\\d{2}-\\d{2})')
	result = regex.search(html)
	if result:
		var iso_date = result.get_string(1)
		# Convert to readable format
		var parts = iso_date.split("-")
		if parts.size() == 3:
			var months = ["", "January", "February", "March", "April", "May", "June", 
						  "July", "August", "September", "October", "November", "December"]
			var month_num = int(parts[1])
			if month_num >= 1 and month_num <= 12:
				return "%s %s, %s" % [months[month_num], parts[2].lstrip("0"), parts[0]]
	
	return ""

func _extract_shader_code_from_html(html: String) -> String:
	var code_start = -1
	var code_start_marker = ""
	
	# Method 1: Find code block with language-glsl class
	code_start_marker = 'class="language-glsl">'
	code_start = html.find(code_start_marker)
	
	# Method 2: Try language-gdshader class
	if code_start == -1:
		code_start_marker = 'class="language-gdshader">'
		code_start = html.find(code_start_marker)
	
	# Method 3: Generic language class
	if code_start == -1:
		code_start_marker = 'class="language-'
		code_start = html.find(code_start_marker)
		if code_start != -1:
			# Find the closing > of this tag
			var tag_end = html.find(">", code_start)
			if tag_end != -1:
				code_start = tag_end
				code_start_marker = ""
	
	# Method 4: Find code block after "Shader code" header
	if code_start == -1:
		var shader_code_header = html.find("Shader code</h5>")
		if shader_code_header == -1:
			shader_code_header = html.find("Shader code</h4>")
		if shader_code_header == -1:
			shader_code_header = html.find("Shader Code</h5>")
		if shader_code_header != -1:
			code_start = html.find("<code", shader_code_header)
			if code_start != -1:
				var tag_end = html.find(">", code_start)
				if tag_end != -1:
					code_start = tag_end
					code_start_marker = ""
	
	# Method 5: Find shader_type keyword directly in a code/pre block
	if code_start == -1:
		var shader_type_pos = html.find("shader_type")
		if shader_type_pos != -1:
			# Look backwards for <code or <pre
			var search_start = maxi(0, shader_type_pos - 500)
			var before = html.substr(search_start, shader_type_pos - search_start)
			var code_tag = before.rfind("<code")
			var pre_tag = before.rfind("<pre")
			var start_tag = maxi(code_tag, pre_tag)
			if start_tag != -1:
				var tag_end = before.find(">", start_tag)
				if tag_end != -1:
					code_start = search_start + tag_end
					code_start_marker = ""
	
	if code_start == -1:
		return ""
	
	# Move past the marker if we have one
	if not code_start_marker.is_empty():
		code_start += code_start_marker.length()
	else:
		code_start += 1  # Move past the ">"
	
	# Find the closing tag
	var code_end = html.find("</code>", code_start)
	if code_end == -1:
		code_end = html.find("</pre>", code_start)
	if code_end == -1:
		# Last resort: find next major HTML section
		code_end = html.find("<h5>", code_start)
		if code_end == -1:
			code_end = html.find("<h4>", code_start)
	if code_end == -1:
		return ""
	
	var code_block = html.substr(code_start, code_end - code_start)
	
	# Validate it looks like shader code
	if not code_block.contains("shader_type") and not code_block.contains("void fragment") and not code_block.contains("void vertex"):
		# Might have grabbed wrong block, try to find shader_type within
		var st_pos = code_block.find("shader_type")
		if st_pos > 0:
			code_block = code_block.substr(st_pos)
	
	return _clean_shader_code(code_block)

func _clean_shader_code(code: String) -> String:
	# Remove HTML line breaks first (before entity decoding)
	code = code.replace("<br>", "\n")
	code = code.replace("<br/>", "\n")
	code = code.replace("<br />", "\n")
	
	# Remove remaining HTML tags
	var regex = RegEx.new()
	regex.compile("<[^>]+>")
	code = regex.sub(code, "", true)
	
	# Decode all HTML entities
	code = _decode_html_entities(code)
	
	# Trim trailing whitespace per line
	var lines = code.split("\n")
	var cleaned_lines = []
	for line in lines:
		cleaned_lines.append(line.rstrip(" \t\r"))
	
	return "\n".join(cleaned_lines).strip_edges()

func _on_preview_install() -> void:
	preview_dialog.hide()
	shader_installer.install_shader(preview_shader)

func _on_card_hover(card: Control, is_hover: bool) -> void:
	if is_hover:
		var hover_style = card.get_meta("hover_style")
		if hover_style:
			card.add_theme_stylebox_override("panel", hover_style)
		# If this card holds a GIF, arm the debounce to start playback.
		if card.has_meta("gif_player"):
			var gp = card.get_meta("gif_player")
			if is_instance_valid(gp):
				_hovered_card = card
				_hover_gen += 1  # invalidate any decode from a previous hover
				_hover_anim_timer.start()
	else:
		var default_style = card.get_meta("default_style")
		if default_style:
			card.add_theme_stylebox_override("panel", default_style)
		if _hovered_card == card:
			_hovered_card = null
			_hover_gen += 1
		# Cancel the loading bar if a decode was in progress for this card.
		_set_card_loading(card, false)
		# Stop playback and drop the extra frames.
		if card.has_meta("gif_player"):
			var gp_exit = card.get_meta("gif_player")
			if is_instance_valid(gp_exit) and gp_exit.is_animating():
				gp_exit.stop_animation()

func _on_hover_anim_timeout() -> void:
	# Debounce elapsed — the pointer settled on a GIF card.
	var card = _hovered_card
	if not is_instance_valid(card) or not card.has_meta("gif_player"):
		return
	var player = card.get_meta("gif_player")
	var url: String = card.get_meta("gif_url", "")
	if not is_instance_valid(player) or url.is_empty():
		return
	if player.is_animating():
		return
	# Instant path — this GIF was already decoded earlier this session.
	if _gif_frames_cache.has(url):
		var cached_frames: Array = _gif_frames_cache[url]
		if cached_frames.size() > 1:
			player.play_animation(cached_frames)
		return
	var path: String = cache_manager.get_image_cache_path(url)
	if not path.ends_with(".gif") or not FileAccess.file_exists(path):
		return
	# Cache miss — a real decode is coming; show the loading bar and stream.
	_set_card_loading(card, true)
	var gen: int = _hover_gen
	_stream_gen = gen
	_stream_frames = []
	_stream_player = weakref(player)
	_stream_url = url
	# Instantiate the decoder on the MAIN thread — creating an @tool GDScript
	# instance on a worker thread fails silently in the editor (same reason
	# _apply_gif_to_card pre-creates its decoder). Only the pure decode runs
	# on the worker; each frame is handed back to the main thread as it's
	# produced so playback can start after just a couple of frames.
	var decoder := GIFDecoder.new()
	WorkerThreadPool.add_task(func():
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			call_deferred("_on_stream_done", gen)
			return
		var bytes := f.get_buffer(f.get_length())
		f.close()
		decoder.decode_streaming(bytes, GIFDecoder.MAX_ANIM_FRAMES, func(frame):
			_downscale_image(frame["image"], ANIM_FRAME_MAX_WIDTH)
			call_deferred("_on_stream_frame", gen, frame)
		)
		call_deferred("_on_stream_done", gen)
	)

func _on_stream_frame(gen: int, frame: Dictionary) -> void:
	# A decoded frame arrived from the worker. Ignore if the hover moved on.
	if gen != _stream_gen or gen != _hover_gen:
		return
	_stream_frames.append(frame)
	var player = _stream_player.get_ref()
	if not is_instance_valid(player):
		return
	# Start animating as soon as we have two frames. play_animation is handed the
	# SAME array we keep appending to, so the loop naturally extends as more
	# frames arrive (progressive playback).
	if _stream_frames.size() == 2:
		player.play_animation(_stream_frames)
		if player.has_meta("card"):
			_set_card_loading(player.get_meta("card"), false)

func _on_stream_done(gen: int) -> void:
	if gen != _stream_gen:
		return  # a newer hover superseded this decode
	# Cache the full set so re-hovering is instant this session.
	if _stream_frames.size() > 1:
		_gif_frames_cache_put(_stream_url, _stream_frames)
	var player = _stream_player.get_ref()
	if is_instance_valid(player) and player.has_meta("card"):
		_set_card_loading(player.get_meta("card"), false)

func _gif_frames_cache_put(url: String, frames: Array) -> void:
	if url.is_empty() or _gif_frames_cache.has(url):
		return
	_gif_frames_cache[url] = frames
	_gif_frames_keys.append(url)
	if _gif_frames_keys.size() > GIF_FRAMES_CACHE_MAX:
		var evict: String = _gif_frames_keys.pop_front()
		_gif_frames_cache.erase(evict)

func _set_card_loading(card: Control, on: bool) -> void:
	# Show/hide the top-of-card indeterminate loading bar while a GIF decodes.
	if not is_instance_valid(card) or not card.has_meta("load_overlay"):
		return
	var overlay = card.get_meta("load_overlay")
	var track = card.get_meta("load_bar_track")
	var fill = card.get_meta("load_bar_fill")
	if not is_instance_valid(overlay) or not is_instance_valid(track) or not is_instance_valid(fill):
		return
	# Kill any running sweep tween.
	if card.has_meta("load_tween"):
		var old = card.get_meta("load_tween")
		if old is Tween and old.is_valid():
			old.kill()
		card.remove_meta("load_tween")
	overlay.visible = on
	if not on:
		return
	# Start an indeterminate left-to-right sweep that loops until hidden.
	var w: float = track.size.x
	if w <= 0.0:
		w = _scaled_card_size.x
	var fw: float = maxf(24.0, w * 0.35)
	fill.size.x = fw
	var tw := create_tween().set_loops()
	tw.tween_property(fill, "position:x", w, 0.7).from(-fw)
	card.set_meta("load_tween", tw)

# === TAB HANDLING ===

func _on_tab_browse(toggled: bool) -> void:
	if not toggled:
		return
	current_tab = 0
	_sync_tab_buttons()
	_apply_filters()

func _on_tab_installed(toggled: bool) -> void:
	if not toggled:
		return
	current_tab = 1
	_sync_tab_buttons()
	if installed_manager:
		installed_manager.scan_installed_shaders()

func _sync_tab_buttons() -> void:
	var browse_btn = find_child("BrowseTab", true, false)
	var installed_btn = find_child("InstalledTab", true, false)
	
	if browse_btn:
		browse_btn.set_pressed_no_signal(current_tab == 0)
	if installed_btn:
		installed_btn.set_pressed_no_signal(current_tab == 1)

func _on_installed_scanned(shaders: Array) -> void:
	_update_installed_count()
	
	if current_tab == 1:
		_display_installed_shaders(shaders)

func _update_installed_count() -> void:
	var installed_btn = find_child("InstalledTab", true, false)
	if installed_btn and installed_manager:
		var count = installed_manager.get_installed_count()
		installed_btn.text = tr_key("installed") + " (%d)" % count

func _display_installed_shaders(shaders: Array) -> void:
	# Hide every pool card — they belong to the Browse tab and must NOT be freed
	# (we reuse them on tab switch back).
	for c in _card_pool:
		if is_instance_valid(c):
			c.visible = false

	# Drop any installed cards from a previous scan.
	for c in _installed_cards:
		if is_instance_valid(c):
			c.queue_free()
	_installed_cards.clear()

	image_queue.clear()

	if shaders.is_empty():
		status_label.text = tr_key("no_installed")
		page_label.text = ""
		prev_button.visible = false
		next_button.visible = false
		return

	status_label.text = tr_key("installed_count") % shaders.size()
	prev_button.visible = false
	next_button.visible = false
	page_label.text = ""

	for shader in shaders:
		var card = _create_installed_card(shader)
		shader_grid.add_child(card)
		_installed_cards.append(card)

func _create_installed_card(shader: Dictionary) -> Control:
	var card = PanelContainer.new()
	card.custom_minimum_size = Vector2(200, 200)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	
	var style = StyleBoxFlat.new()
	style.bg_color = card_bg
	style.set_corner_radius_all(8)
	style.set_border_width_all(2)
	style.border_color = Color(0.2, 0.6, 0.3)  # Green border for installed
	card.add_theme_stylebox_override("panel", style)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)
	
	# Header with category badge
	var header = HBoxContainer.new()
	vbox.add_child(header)
	
	var badge = Label.new()
	badge.text = " " + shader.get("category", "Unknown").to_upper().replace("_", " ") + " "
	badge.add_theme_font_size_override("font_size", 9)
	var badge_style = StyleBoxFlat.new()
	badge_style.bg_color = Color(0.2, 0.5, 0.3)
	badge_style.set_corner_radius_all(3)
	badge_style.content_margin_left = 4
	badge_style.content_margin_right = 4
	badge_style.content_margin_top = 2
	badge_style.content_margin_bottom = 2
	badge.add_theme_stylebox_override("normal", badge_style)
	header.add_child(badge)
	
	# Content margin
	var content_margin = MarginContainer.new()
	content_margin.add_theme_constant_override("margin_left", 10)
	content_margin.add_theme_constant_override("margin_right", 10)
	content_margin.add_theme_constant_override("margin_bottom", 8)
	content_margin.size_flags_vertical = SIZE_EXPAND_FILL
	vbox.add_child(content_margin)
	
	var content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	content_margin.add_child(content)
	
	# Title
	var title = Label.new()
	title.text = shader.get("title", "Shader")
	title.add_theme_font_size_override("font_size", 13)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	content.add_child(title)
	
	# Author
	var author = Label.new()
	author.text = "by " + shader.get("author", "Unknown")
	author.add_theme_font_size_override("font_size", 11)
	author.add_theme_color_override("font_color", text_dim)
	content.add_child(author)
	
	# File path
	var path_label = Label.new()
	path_label.text = shader.get("filename", "")
	path_label.add_theme_font_size_override("font_size", 10)
	path_label.add_theme_color_override("font_color", text_dim)
	content.add_child(path_label)
	
	# Spacer
	var spacer = Control.new()
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	content.add_child(spacer)
	
	# Buttons
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	content.add_child(btn_row)
	
	# Check if we're in select mode
	if has_meta("select_mode") and get_meta("select_mode"):
		var select_btn = Button.new()
		select_btn.text = "Select"
		select_btn.size_flags_horizontal = SIZE_EXPAND_FILL
		select_btn.pressed.connect(_on_select_shader.bind(shader))
		btn_row.add_child(select_btn)
	else:
		var edit_btn = Button.new()
		edit_btn.text = "Edit"
		edit_btn.size_flags_horizontal = SIZE_EXPAND_FILL
		edit_btn.pressed.connect(_on_edit_shader.bind(shader))
		btn_row.add_child(edit_btn)
		
		var delete_btn = Button.new()
		delete_btn.text = tr_key("delete")
		delete_btn.size_flags_horizontal = SIZE_EXPAND_FILL
		delete_btn.pressed.connect(_on_delete_shader.bind(shader))
		btn_row.add_child(delete_btn)
	
	return card

func _on_edit_shader(shader: Dictionary) -> void:
	if installed_manager:
		installed_manager.open_shader_in_editor(shader)

func _on_delete_shader(shader: Dictionary) -> void:
	# Show confirmation dialog
	var confirm = ConfirmationDialog.new()
	confirm.title = "Confirm"
	confirm.dialog_text = tr_key("delete_confirm") % shader.get("title", "")
	confirm.confirmed.connect(func():
		if installed_manager:
			if installed_manager.delete_shader(shader):
				status_label.text = tr_key("deleted") % shader.get("title", "")
			else:
				status_label.text = tr_key("delete_error")
	)
	add_child(confirm)
	confirm.popup_centered()

## Update system callbacks

func _on_update_available(version: String, url: String, changelog: String) -> void:
	# Store update info
	pending_update_url = url
	pending_update_version = version
	pending_changelog = changelog
	
	# Show update button
	if update_button:
		update_button.text = "Update to v" + version
		update_button.visible = true
		var current = update_checker._get_current_version()
		update_button.tooltip_text = "New version available!\n\nCurrent: v" + current + "\nLatest: v" + version

func _on_update_check_completed(has_update: bool) -> void:
	if not has_update:
		# Silently complete - no update available
		pass

func _on_update_clicked() -> void:
	# Show update dialog with option to open GitHub releases
	var dialog = AcceptDialog.new()
	dialog.title = "Plugin Update Available"
	var current = update_checker._get_current_version()
	dialog.dialog_text = "A new version of Shader Library is available!\n\n"
	dialog.dialog_text += "Current version: v" + current + "\n"
	dialog.dialog_text += "New version: v" + pending_update_version + "\n\n"
	
	if not pending_changelog.is_empty():
		dialog.dialog_text += "Changelog:\n" + pending_changelog.substr(0, 300)
		if pending_changelog.length() > 300:
			dialog.dialog_text += "..."
	
	dialog.dialog_text += "\n\nTo update:\n"
	dialog.dialog_text += "1. Disable the plugin in Project Settings\n"
	dialog.dialog_text += "2. Delete the addons/shader_library folder\n"
	dialog.dialog_text += "3. Download the new version from GitHub\n"
	dialog.dialog_text += "4. Re-enable the plugin\n\n"
	dialog.dialog_text += "Click 'Open GitHub' to visit the releases page."
	
	dialog.get_ok_button().text = "Open GitHub"
	dialog.add_cancel_button("Later")
	
	dialog.confirmed.connect(func():
		if not pending_update_url.is_empty():
			OS.shell_open(pending_update_url)
	)
	
	add_child(dialog)
	dialog.popup_centered(Vector2(500, 400))

func _on_update_error(error_message: String) -> void:
	# Silently fail - don't bother user with update check errors
	pass


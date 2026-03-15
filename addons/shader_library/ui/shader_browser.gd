@tool
extends Control

## Shader Library UI - with image loading and localization

const Translations = preload("res://addons/shader_library/api/translations.gd")

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

# UI Elements
var search_input: LineEdit
var type_option: OptionButton

var sort_option: OptionButton
var shader_grid: HFlowContainer
var status_label: Label
var progress_bar: ProgressBar
var prev_button: Button
var next_button: Button
var page_label: Label
var scroll_container: ScrollContainer

# Components
var cache_manager: Node
var shader_installer: Node
var installed_manager: Node

# Tab state
var current_tab: int = 0  # 0 = Browse, 1 = Installed

# Data
var all_shaders: Array = []
var filtered_shaders: Array = []
var current_page: int = 1
var shaders_per_page: int = 40

# Category colors for placeholders
var category_colors: Dictionary = {
	"spatial": Color(0.2, 0.4, 0.8),
	"canvas item": Color(0.7, 0.3, 0.5),
	"sky": Color(0.3, 0.6, 0.9),
	"particles": Color(0.9, 0.5, 0.2),
	"fog": Color(0.5, 0.5, 0.6)
}

# Image loading - parallel (4 concurrent downloads)
const PARALLEL_DOWNLOADS: int = 4
var image_queue: Array = []
var image_https: Array = []  # Array of HTTPRequest
var current_image_cards: Array = []  # Array of Control
var current_image_urls: Array = []  # Array of String
var active_downloads: int = 0

# Shader preview dialog
var preview_dialog: Window
var preview_code_edit: CodeEdit
var preview_shader: Dictionary = {}
var preview_http: HTTPRequest

# Colors - matching Godot's dark theme
var bg_color := Color(0.15, 0.15, 0.15)  # Godot editor background
var card_bg := Color(0.2, 0.2, 0.22)
var accent := Color(0.3, 0.5, 0.9)
var text_dim := Color(0.6, 0.6, 0.65)

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

## Load image from buffer using correct decoder
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
		_:
			# Unknown format - skip silently
			return null
	
	if err == OK:
		return img
	return null

func _init() -> void:
	custom_minimum_size = Vector2(800, 600)

func _ready() -> void:
	_build_ui()
	_init_components()
	call_deferred("_start_loading")

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
	shader_grid.add_theme_constant_override("h_separation", 12)
	shader_grid.add_theme_constant_override("v_separation", 12)
	shader_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll_container.add_child(shader_grid)
	
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
	search_input.text_changed.connect(_on_filter_changed)
	header.add_child(search_input)
	
	var refresh_btn = Button.new()
	refresh_btn.text = tr_key("refresh")
	refresh_btn.pressed.connect(_on_refresh)
	header.add_child(refresh_btn)

func _build_filters(parent: Control) -> void:
	var filters = HBoxContainer.new()
	filters.add_theme_constant_override("separation", 16)
	parent.add_child(filters)
	
	# Type
	var type_lbl = Label.new()
	type_lbl.text = tr_key("type")
	type_lbl.add_theme_color_override("font_color", text_dim)
	filters.add_child(type_lbl)
	
	type_option = OptionButton.new()
	type_option.add_item(tr_key("all_types"))
	type_option.add_item("Canvas Item")
	type_option.add_item("Spatial")
	type_option.add_item("Particles")
	type_option.add_item("Sky")
	type_option.add_item("Fog")
	type_option.item_selected.connect(_on_filter_changed)
	filters.add_child(type_option)
	
	var spacer = Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	filters.add_child(spacer)
	
	# Sort
	var sort_lbl = Label.new()
	sort_lbl.text = tr_key("sort")
	sort_lbl.add_theme_color_override("font_color", text_dim)
	filters.add_child(sort_lbl)
	
	sort_option = OptionButton.new()
	sort_option.add_item(tr_key("newest"))
	sort_option.add_item(tr_key("popular"))
	sort_option.add_item(tr_key("name_az"))
	sort_option.item_selected.connect(_on_filter_changed)
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
	
	# Connect to cache manager signals (for GitHub download)
	cache_manager.database_loaded.connect(_on_shaders_loaded)
	cache_manager.database_error.connect(_on_database_error)
	
	# Build preview dialog
	_build_preview_dialog()

func _start_loading() -> void:
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

func _on_shaders_loaded(shaders: Array) -> void:
	all_shaders = shaders
	progress_bar.visible = false
	_apply_filters()

func _apply_filters(_arg = null) -> void:
	filtered_shaders = all_shaders.duplicate()
	
	# Type filter
	var type_idx = type_option.selected
	if type_idx > 0:
		var type_name = type_option.get_item_text(type_idx)
		filtered_shaders = filtered_shaders.filter(func(s):
			return type_name.to_lower() in s.get("category", "").to_lower()
		)
	
	# Search filter
	var query = search_input.text.strip_edges().to_lower()
	if not query.is_empty():
		filtered_shaders = filtered_shaders.filter(func(s):
			return query in s.get("title", "").to_lower() or query in s.get("author", "").to_lower()
		)
	
	# Sort
	match sort_option.selected:
		1:  # Popular - convert likes to int for proper sorting
			filtered_shaders.sort_custom(func(a, b): return int(a.get("likes", "0")) > int(b.get("likes", "0")))
		2:  # Name - strip non-alphanumeric from start for proper sorting
			filtered_shaders.sort_custom(func(a, b): 
				return _normalize_title(a.get("title", "")) < _normalize_title(b.get("title", ""))
			)
	
	current_page = 1
	_display_page()

func _on_filter_changed(_arg = null) -> void:
	_apply_filters()

func _display_page() -> void:
	# Cancel any pending image requests
	for http in image_https:
		if http and http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
			http.cancel_request()
	active_downloads = 0
	
	# Clear grid
	for child in shader_grid.get_children():
		child.queue_free()
	
	image_queue.clear()
	
	var total_pages = maxi(1, ceili(float(filtered_shaders.size()) / shaders_per_page))
	var start = (current_page - 1) * shaders_per_page
	var end = mini(start + shaders_per_page, filtered_shaders.size())
	
	status_label.text = tr_key("found_shaders") % filtered_shaders.size()
	page_label.text = "%d / %d" % [current_page, total_pages]
	prev_button.disabled = current_page <= 1
	next_button.disabled = current_page >= total_pages
	
	# Create cards and queue images
	for i in range(start, end):
		var shader = filtered_shaders[i]
		var card = _create_card(shader)
		shader_grid.add_child(card)
		
		# Queue image for loading if URL exists
		var img_url = shader.get("image_url", "")
		if img_url != "":
			image_queue.append({"card": card, "url": img_url, "shader": shader})
	
	# Start loading images
	_load_next_image()

func _load_next_image() -> void:
	# Fill all available download slots
	while active_downloads < PARALLEL_DOWNLOADS and not image_queue.is_empty():
		# Find free slot
		var slot = -1
		for i in PARALLEL_DOWNLOADS:
			if image_https[i].get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
				slot = i
				break
		
		if slot == -1:
			break  # No free slots
		
		var item = image_queue.pop_front()
		var card = item.card
		var url = item.url
		
		if not is_instance_valid(card):
			continue  # Skip invalid cards
		
		# Check cache first
		if cache_manager.has_cached_image(url):
			var img = cache_manager.load_cached_image(url)
			if img:
				var tex = ImageTexture.create_from_image(img)
				_apply_image_to_card(card, tex)
				continue  # Don't count as active download, check next
		
		# Start download
		current_image_cards[slot] = card
		current_image_urls[slot] = url
		active_downloads += 1
		
		var err = image_https[slot].request(url)
		if err != OK:
			active_downloads -= 1
			current_image_cards[slot] = null
			current_image_urls[slot] = ""

func _on_image_loaded(result: int, code: int, headers: PackedStringArray, body: PackedByteArray, slot: int) -> void:
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
	if format == "unknown":
		# Not a valid image format - skip silently
		call_deferred("_load_next_image")
		return
	
	var img = _load_image_from_buffer(body)
	
	if img:
		var tex = ImageTexture.create_from_image(img)
		_apply_image_to_card(card, tex)
		
		# Cache image
		cache_manager.cache_image(url, body)
	
	call_deferred("_load_next_image")

func _apply_image_to_card(card: Control, tex: Texture2D) -> void:
	if not is_instance_valid(card):
		return
	
	# Find image container
	var vbox = card.get_child(0)
	if not vbox:
		return
	
	var img_container = vbox.get_node_or_null("ImageContainer")
	if not img_container:
		return
	
	# Remove placeholder
	var center = img_container.get_node_or_null("PlaceholderCenter")
	if center:
		center.queue_free()
	
	# Add texture
	var tex_rect = TextureRect.new()
	tex_rect.texture = tex
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tex_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	img_container.add_child(tex_rect)
	img_container.move_child(tex_rect, 0)

func _create_card(shader: Dictionary) -> Control:
	var card = PanelContainer.new()
	card.custom_minimum_size = Vector2(200, 280)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	
	var style = StyleBoxFlat.new()
	style.bg_color = card_bg
	style.set_corner_radius_all(8)
	style.set_border_width_all(2)
	style.border_color = Color(0.25, 0.25, 0.3)
	card.add_theme_stylebox_override("panel", style)
	
	# Store reference for hover
	card.set_meta("default_style", style)
	card.set_meta("shader", shader)
	
	# Create hover style
	var hover_style = style.duplicate()
	hover_style.border_color = accent
	hover_style.bg_color = Color(0.22, 0.22, 0.28)
	card.set_meta("hover_style", hover_style)
	
	# Connect hover signals
	card.mouse_entered.connect(_on_card_hover.bind(card, true))
	card.mouse_exited.connect(_on_card_hover.bind(card, false))
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	card.add_child(vbox)
	
	# Get category color
	var cat = shader.get("category", "").to_lower()
	var cat_color = category_colors.get(cat, Color(0.3, 0.35, 0.4))
	
	# Category badge - ON TOP of card (above image)
	var badge = Label.new()
	badge.text = " " + shader.get("category", "2D").to_upper().substr(0, 12) + " "
	badge.add_theme_font_size_override("font_size", 9)
	badge.add_theme_color_override("font_color", Color.WHITE)
	var badge_style = StyleBoxFlat.new()
	badge_style.bg_color = cat_color
	badge_style.set_corner_radius(CORNER_TOP_LEFT, 6)
	badge_style.set_corner_radius(CORNER_TOP_RIGHT, 6)
	badge_style.set_corner_radius(CORNER_BOTTOM_LEFT, 0)
	badge_style.set_corner_radius(CORNER_BOTTOM_RIGHT, 0)
	badge_style.content_margin_left = 8
	badge_style.content_margin_right = 8
	badge_style.content_margin_top = 4
	badge_style.content_margin_bottom = 4
	badge.add_theme_stylebox_override("normal", badge_style)
	vbox.add_child(badge)
	
	# Image container with category-based gradient
	var img_container = PanelContainer.new()
	img_container.custom_minimum_size = Vector2(0, 130)
	img_container.name = "ImageContainer"
	
	var img_style = StyleBoxFlat.new()
	img_style.bg_color = cat_color.darkened(0.5)
	img_style.set_corner_radius_all(0)
	img_container.add_theme_stylebox_override("panel", img_style)
	vbox.add_child(img_container)
	
	# Placeholder icon centered
	var center = CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	center.name = "PlaceholderCenter"
	img_container.add_child(center)
	
	var icon_vbox = VBoxContainer.new()
	icon_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(icon_vbox)
	
	# Category emoji
	var icon = Label.new()
	var cat_upper = shader.get("category", "").to_upper()
	match cat_upper:
		"SPATIAL": icon.text = "🎲"
		"CANVAS ITEM": icon.text = "🎨"
		"SKY": icon.text = "☁️"
		"PARTICLES": icon.text = "✨"
		"FOG": icon.text = "🌫️"
		_: icon.text = "🔷"
	icon.add_theme_font_size_override("font_size", 36)
	icon.add_theme_color_override("font_color", cat_color.lightened(0.3))
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_vbox.add_child(icon)
	
	# Content margin
	var content_margin = MarginContainer.new()
	content_margin.add_theme_constant_override("margin_left", 10)
	content_margin.add_theme_constant_override("margin_right", 10)
	content_margin.add_theme_constant_override("margin_bottom", 8)
	content_margin.size_flags_vertical = SIZE_EXPAND_FILL
	vbox.add_child(content_margin)
	
	var content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 3)
	content_margin.add_child(content)
	
	# Title
	var title = Label.new()
	title.text = shader.get("title", "Shader")
	title.add_theme_font_size_override("font_size", 13)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	title.custom_minimum_size.y = 36
	content.add_child(title)
	
	# Author
	var author = Label.new()
	author.text = shader.get("author", "Unknown")
	author.add_theme_font_size_override("font_size", 11)
	author.add_theme_color_override("font_color", text_dim)
	content.add_child(author)
	
	# Spacer - ignore mouse to keep card hover active
	var spacer = Control.new()
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(spacer)
	
	# License + Likes
	var info_row = HBoxContainer.new()
	content.add_child(info_row)
	
	var lic = Label.new()
	lic.text = shader.get("license", "CC0")
	lic.add_theme_font_size_override("font_size", 10)
	lic.add_theme_color_override("font_color", text_dim)
	info_row.add_child(lic)
	
	var info_spacer = Control.new()
	info_spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	info_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_row.add_child(info_spacer)
	
	var likes = Label.new()
	likes.text = "♡ " + str(shader.get("likes", 0))
	likes.add_theme_font_size_override("font_size", 10)
	likes.add_theme_color_override("font_color", text_dim)
	info_row.add_child(likes)
	
	# Buttons
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	content.add_child(btn_row)
	
	var preview_btn = Button.new()
	preview_btn.text = tr_key("preview")
	preview_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	preview_btn.pressed.connect(_show_preview.bind(shader))
	btn_row.add_child(preview_btn)
	
	var install_btn = Button.new()
	install_btn.text = tr_key("install")
	install_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	install_btn.pressed.connect(_on_install.bind(shader))
	btn_row.add_child(install_btn)
	
	return card

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
	preview_dialog.close_requested.connect(func(): preview_dialog.hide())
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
	desc_label.add_theme_color_override("default_color", Color(0.85, 0.85, 0.85))
	desc_label.add_theme_font_size_override("normal_font_size", 14)
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
		# Remove old TextureRect if exists
		for child in img_container.get_children():
			if child is TextureRect:
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

func _on_preview_image_loaded(result: int, code: int, headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest, url: String) -> void:
	http.queue_free()
	
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		var img_loading = preview_dialog.find_child("ImageLoading", true, false)
		if img_loading:
			img_loading.text = tr_key("image_load_failed")
		return
	
	# Check if we actually received image data
	if body.size() < 12 or _detect_image_format(body) == "unknown":
		var img_loading = preview_dialog.find_child("ImageLoading", true, false)
		if img_loading:
			img_loading.text = tr_key("image_error")
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

func _on_preview_code_loaded(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
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
			desc_lbl.text = description
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
			tags_lbl.text = tags
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
			date_lbl.text = "📅 " + date
			date_lbl.visible = true
	else:
		var date_lbl = preview_dialog.find_child("DateLabel", true, false)
		if date_lbl:
			date_lbl.visible = false

func _extract_description(html: String) -> String:
	# Strategy: Find description content between header info and "Shader code" section
	
	# First, find where "Shader code" section starts - this is our end marker
	# Look for actual heading, not CSS references
	var shader_code_pos = html.find(">Shader code<")  # Heading tag content
	if shader_code_pos == -1:
		shader_code_pos = html.find("##### Shader code")  # Markdown style
	if shader_code_pos == -1:
		shader_code_pos = html.find("Shader code</h")  # Before closing h tag
	if shader_code_pos == -1:
		# Last resort - find shader_type keyword in actual code block
		var code_block = html.find("<code")
		if code_block != -1:
			var shader_type_in_code = html.find("shader_type", code_block)
			if shader_type_in_code != -1:
				shader_code_pos = code_block
	if shader_code_pos == -1:
		return ""
	
	# Look for description start markers (try multiple approaches)
	var start = -1
	
	# Approach 1: Find entry-content class and look for <p> within a reasonable range
	var entry_start = html.find("entry-content")
	if entry_start != -1 and entry_start < shader_code_pos:
		# Only search for <p> within 500 chars after entry-content, not across the whole doc
		var search_limit = mini(entry_start + 500, shader_code_pos)
		var p_pos = html.find("<p>", entry_start)
		if p_pos != -1 and p_pos < search_limit:
			start = p_pos
	
	# Approach 2: Find first <p> after the header section (author/date line)
	if start == -1 or start >= shader_code_pos:
		# Look for paragraph after author/date info which often contains "|"
		var header_end = html.rfind("|", shader_code_pos)
		if header_end != -1 and header_end > shader_code_pos - 5000:  # Only if | is within 5000 chars before shader code
			var p_after = html.find("<p>", header_end)
			if p_after != -1 and p_after < shader_code_pos:
				start = p_after
	
	# Approach 3: Just find the last <p> block before shader code
	if start == -1 or start >= shader_code_pos:
		var search_pos = 0
		var last_valid_p = -1
		while true:
			var p_pos = html.find("<p>", search_pos)
			if p_pos == -1 or p_pos >= shader_code_pos:
				break
			# Make sure this <p> has actual content
			var p_end = html.find("</p>", p_pos)
			if p_end != -1 and p_end < shader_code_pos:
				var content_check = html.substr(p_pos + 3, mini(100, p_end - p_pos - 3))
				# Skip if it looks like navigation or header
				if not content_check.contains("Sign in") and not content_check.contains("Toggle"):
					last_valid_p = p_pos
			search_pos = p_pos + 1
		if last_valid_p != -1:
			# Go back to find the first <p> in this description section
			# Usually there are multiple paragraphs together
			var desc_start = last_valid_p
			var prev_search = last_valid_p - 500
			if prev_search < 0:
				prev_search = 0
			# Find the first <p> in this cluster
			var first_in_cluster = html.find("<p>", prev_search)
			if first_in_cluster != -1 and first_in_cluster < last_valid_p:
				# Check if there's a significant gap (like a header) between them
				var between = html.substr(first_in_cluster, last_valid_p - first_in_cluster)
				if not between.contains("<h") and not between.contains("<article"):
					desc_start = first_in_cluster
			start = desc_start
	
	# Approach 4: Plain text description (not wrapped in <p> tags)
	# Look backwards from "Shader code" header for description text
	if start == -1 or start >= shader_code_pos:
		# Find the Shader code header position
		var code_header_pos = shader_code_pos
		if code_header_pos > 200:
			# Look backwards from shader code section to find content
			# Search for a larger area - 3000 chars before Shader code
			var search_start = code_header_pos - 3000
			if search_start < 0:
				search_start = 0
			var search_area = html.substr(search_start, code_header_pos - search_start)
			
			# Try multiple patterns to find the end of header info
			var desc_start_local = -1
			
			# Pattern 1: Look for likes count span closing: </span> after a number
			var likes_span = search_area.rfind("</span>")
			if likes_span != -1:
				# Check if there's meaningful text after it
				var after_span = search_area.substr(likes_span + 7).strip_edges()
				if after_span.length() > 20:
					desc_start_local = likes_span + 7
			
			# Pattern 2: Look for date pattern then find next content
			if desc_start_local == -1:
				var date_markers = ["2026", "2025", "2024", "2023", "2022"]
				for year in date_markers:
					var year_pos = search_area.rfind(year)
					if year_pos != -1:
						# Find closing tag after year
						var close_tag = search_area.find(">", year_pos)
						if close_tag != -1 and close_tag < search_area.length() - 50:
							var after_year = search_area.substr(close_tag + 1).strip_edges()
							if after_year.length() > 20 and not after_year.begins_with("<"):
								desc_start_local = close_tag + 1
								break
			
			if desc_start_local != -1:
				var plain_text = search_area.substr(desc_start_local)
				# Clean HTML tags
				var tag_regex = RegEx.new()
				tag_regex.compile("<[^>]+>")
				plain_text = tag_regex.sub(plain_text, "", true)
				plain_text = plain_text.replace("&nbsp;", " ")
				plain_text = plain_text.replace("&amp;", "&")
				plain_text = plain_text.replace("&#8217;", "'")
				plain_text = plain_text.replace("&#039;", "'")
				plain_text = plain_text.strip_edges()
				
				# Remove "Shader code" header if captured
				if plain_text.begins_with("Shader code"):
					plain_text = plain_text.substr(11).strip_edges()
				
				# Skip navigation/menu text
				if plain_text.length() > 10 and not plain_text.contains("Sign in") and not plain_text.contains("Toggle"):
					if plain_text.length() > 1500:
						plain_text = plain_text.substr(0, 1500) + "..."
					return plain_text
		
		return ""
	
	if start >= shader_code_pos:
		return ""
	
	# Find where shader code section begins
	var end = shader_code_pos
	
	var content = html.substr(start, end - start)
	
	# Skip if it contains navigation elements
	if content.contains("Sign in") or content.contains("Toggle Menu") or content.contains("<article"):
		return ""
	
	# Don't include if it's too short
	if content.length() < 30:
		return ""
	
	# Clean HTML
	content = content.replace("<p>", "")
	content = content.replace("</p>", "\n")
	content = content.replace("<br>", "\n")
	content = content.replace("<br/>", "\n")
	content = content.replace("<br />", "\n")
	content = content.replace("<ul>", "")
	content = content.replace("</ul>", "")
	content = content.replace("<li>", "• ")
	content = content.replace("</li>", "\n")
	content = content.replace("<strong>", "")
	content = content.replace("</strong>", "")
	content = content.replace("<em>", "")
	content = content.replace("</em>", "")
	content = content.replace("<b>", "")
	content = content.replace("</b>", "")
	content = content.replace("<i>", "")
	content = content.replace("</i>", "")
	content = content.replace("<code>", "`")
	content = content.replace("</code>", "`")
	content = content.replace("<h5>", "\n")
	content = content.replace("</h5>", "\n")
	content = content.replace("<h4>", "\n")
	content = content.replace("</h4>", "\n")
	content = content.replace("&nbsp;", " ")
	content = content.replace("&amp;", "&")
	content = content.replace("&lt;", "<")
	content = content.replace("&gt;", ">")
	content = content.replace("&#8211;", "–")
	content = content.replace("&#8216;", "'")
	content = content.replace("&#8217;", "'")
	content = content.replace("&rsquo;", "'")
	content = content.replace("&lsquo;", "'")
	content = content.replace("&ldquo;", "\"")
	content = content.replace("&rdquo;", "\"")
	content = content.replace("&#039;", "'")
	content = content.replace("&quot;", "\"")
	
	# Remove remaining HTML tags (complete and incomplete)
	var regex = RegEx.new()
	regex.compile("<[^>]*>?")
	content = regex.sub(content, "", true)
	# Also remove any leftover incomplete tags at the end
	var incomplete_tag = content.rfind("<")
	if incomplete_tag != -1 and content.find(">", incomplete_tag) == -1:
		content = content.substr(0, incomplete_tag)
	
	# Clean up multiple newlines and spaces
	while content.contains("\n\n\n"):
		content = content.replace("\n\n\n", "\n\n")
	while content.contains("  "):
		content = content.replace("  ", " ")
	
	content = content.strip_edges()
	
	# Limit length
	if content.length() > 1500:
		content = content.substr(0, 1500) + "..."
	
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
		tag = tag.replace("&#039;", "'")
		tag = tag.replace("&amp;", "&")
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
	else:
		var default_style = card.get_meta("default_style")
		if default_style:
			card.add_theme_stylebox_override("panel", default_style)

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
	# Clear grid
	for child in shader_grid.get_children():
		child.queue_free()
	
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
	badge.text = " " + shader.get("category", "Unknown").to_upper() + " "
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

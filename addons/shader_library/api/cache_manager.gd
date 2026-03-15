@tool
extends Node
class_name ShaderCacheManager

## Manages local cache of shader data
## Downloads shader database from GitHub (updated daily via Actions)

signal database_loaded(shaders: Array)
signal database_error(error: String)

const CACHE_DIR = "user://shader_library_cache/"
const CACHE_FILE = "shaders.json"
const IMAGE_CACHE_DIR = "user://shader_library_cache/images/"
const CACHE_DURATION = 86400  # 24 hours - check for updates daily

# GitHub raw URL to the shader database
const GITHUB_DATABASE_URL = "https://raw.githubusercontent.com/Kelpekk/Godot-Shader-Library/main/data/shaders.json"

var cached_shaders: Array = []
var cache_timestamp: int = 0
var image_requests: Dictionary = {}
var http_request: HTTPRequest

func _ready() -> void:
	_ensure_dirs()
	_setup_http()
	load_cache()

func _setup_http() -> void:
	http_request = HTTPRequest.new()
	http_request.timeout = 30
	add_child(http_request)
	http_request.request_completed.connect(_on_database_downloaded)

func _ensure_dirs() -> void:
	if not DirAccess.dir_exists_absolute(CACHE_DIR):
		DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	if not DirAccess.dir_exists_absolute(IMAGE_CACHE_DIR):
		DirAccess.make_dir_recursive_absolute(IMAGE_CACHE_DIR)

func load_cache() -> bool:
	var path = CACHE_DIR + CACHE_FILE
	
	if not FileAccess.file_exists(path):
		return false
	
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	
	var json_str = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	if json.parse(json_str) != OK:
		return false
	
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		return false
	
	cached_shaders = data.get("shaders", [])
	cache_timestamp = data.get("timestamp", 0)
	return true

func save_cache(shaders: Array) -> void:
	cached_shaders = shaders
	cache_timestamp = int(Time.get_unix_time_from_system())
	
	var data = {
		"shaders": shaders,
		"timestamp": cache_timestamp
	}
	
	var json_str = JSON.stringify(data, "\t")
	var file = FileAccess.open(CACHE_DIR + CACHE_FILE, FileAccess.WRITE)
	if file:
		file.store_string(json_str)
		file.close()

func is_cache_valid() -> bool:
	if cached_shaders.is_empty():
		return false
	
	var now = int(Time.get_unix_time_from_system())
	return (now - cache_timestamp) < CACHE_DURATION

func get_cached_shaders() -> Array:
	return cached_shaders

## Fetch shader database from GitHub (1 request instead of 52 pages!)
func fetch_from_github() -> void:
	var error = http_request.request(GITHUB_DATABASE_URL)
	if error != OK:
		database_error.emit("Failed to connect to GitHub")

func _on_database_downloaded(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		database_error.emit("Failed to download shader database")
		return
	
	var json_str = body.get_string_from_utf8()
	var json = JSON.new()
	if json.parse(json_str) != OK:
		database_error.emit("Invalid JSON from GitHub")
		return
	
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		database_error.emit("Invalid data format")
		return
	
	var shaders = data.get("shaders", [])
	if shaders.is_empty():
		database_error.emit("No shaders in database")
		return
	
	# Save to local cache
	save_cache(shaders)
	database_loaded.emit(shaders)

func clear_cache() -> void:
	cached_shaders = []
	cache_timestamp = 0
	
	var path = CACHE_DIR + CACHE_FILE
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

## Detect image format from binary data
func _detect_image_format(data: PackedByteArray) -> String:
	if data.size() < 12:
		return "unknown"
	
	# PNG: 89 50 4E 47 0D 0A 1A 0A
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
	
	# GIF: GIF87a or GIF89a
	if data[0] == 0x47 and data[1] == 0x49 and data[2] == 0x46:
		return "gif"
	
	return "unknown"

## Get cached image path (checks for all formats)
func get_image_cache_path(url: String) -> String:
	if url.is_empty():
		return ""
	var hash = url.md5_text()
	var base_path = IMAGE_CACHE_DIR + hash
	
	# Check for existing cached file in any format
	for ext in [".png", ".jpg", ".webp", ".gif"]:
		if FileAccess.file_exists(base_path + ext):
			return base_path + ext
	
	# Return base path if nothing cached yet
	return base_path

## Check if image is cached
func has_cached_image(url: String) -> bool:
	if url.is_empty():
		return false
	var hash = url.md5_text()
	var base_path = IMAGE_CACHE_DIR + hash
	
	for ext in [".png", ".jpg", ".webp", ".gif"]:
		if FileAccess.file_exists(base_path + ext):
			return true
	return false

## Save image to cache with correct extension
func cache_image(url: String, data: PackedByteArray) -> String:
	if url.is_empty() or data.is_empty():
		return ""
	
	var hash = url.md5_text()
	var format = _detect_image_format(data)
	
	var ext = ".bin"
	match format:
		"png": ext = ".png"
		"jpg": ext = ".jpg"
		"webp": ext = ".webp"
		"gif": ext = ".gif"
		_: ext = ".bin"
	
	var path = IMAGE_CACHE_DIR + hash + ext
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_buffer(data)
		file.close()
		return path
	return ""

## Load cached image
func load_cached_image(url: String) -> Image:
	var path = get_image_cache_path(url)
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	
	# Load raw data
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return null
	var data = file.get_buffer(file.get_length())
	file.close()
	
	# Try to decode based on detected format
	var image = Image.new()
	var format = _detect_image_format(data)
	var err = ERR_FILE_CORRUPT
	
	match format:
		"png":
			err = image.load_png_from_buffer(data)
		"jpg":
			err = image.load_jpg_from_buffer(data)
		"webp":
			err = image.load_webp_from_buffer(data)
		_:
			# Unknown format - return null
			return null
	
	if err == OK:
		return image
	return null

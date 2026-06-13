@tool
extends Node

## Manages local cache of shader data
## Internal class - not exposed to users
## Downloads shader database from GitHub (updated daily via Actions)

signal database_loaded(shaders: Array)
signal database_error(error: String)
# Fires once the on-disk cache has been read AND parsed on a worker thread,
# regardless of whether the parse succeeded. shader_browser._start_loading
# waits on this so it doesn't race the parser.
signal cache_load_finished
var is_cache_loaded: bool = false

const CACHE_DIR = "user://shader_library_cache/"
const CACHE_FILE = "shaders.json"
const IMAGE_CACHE_DIR = "user://shader_library_cache/images/"
const VIDEO_CACHE_DIR = "user://shader_library_cache/videos/"
const CACHE_DURATION = 86400  # 24 hours - check for updates daily

# GitHub raw URL to the shader database
const GITHUB_DATABASE_URL = "https://raw.githubusercontent.com/Kelpekk/Godot-Shader-Library/main/data/shaders.json"

var cached_shaders: Array = []
var cache_timestamp: int = 0
var image_requests: Dictionary = {}
var http_request: HTTPRequest

# In-memory index of files on disk in IMAGE_CACHE_DIR. Built lazily on first
# query and updated by cache_image. Replaces repeated FileAccess.file_exists
# calls (4 per query, 40 cards per page = up to 160 syscalls just to populate
# a page that's already fully cached).
#   key: url_hash (String)
#   value: file path including extension (String) — empty means "known absent"
var _image_index: Dictionary = {}
var _image_index_built: bool = false

func _ready() -> void:
	_ensure_dirs()
	_setup_http()
	# JSON.parse on a 2MB shader database blocks the editor for 100-300ms.
	# Read the file on the main thread (fast) but offload the parse to a worker.
	_start_async_cache_load()
	# Scanning the image cache dir can take seconds when it has thousands of
	# entries (heavy users). Run that off the main thread too.
	_start_async_image_index_build()

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
	if not DirAccess.dir_exists_absolute(VIDEO_CACHE_DIR):
		DirAccess.make_dir_recursive_absolute(VIDEO_CACHE_DIR)

func _start_async_cache_load() -> void:
	var path: String = CACHE_DIR + CACHE_FILE
	if not FileAccess.file_exists(path):
		is_cache_loaded = true
		cache_load_finished.emit()
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		is_cache_loaded = true
		cache_load_finished.emit()
		return
	var json_str := file.get_as_text()
	file.close()
	WorkerThreadPool.add_task(func():
		var parsed = JSON.parse_string(json_str)
		call_deferred("_on_async_cache_parsed", parsed)
	)

func _on_async_cache_parsed(parsed) -> void:
	if typeof(parsed) == TYPE_DICTIONARY:
		cached_shaders = parsed.get("shaders", [])
		cache_timestamp = parsed.get("timestamp", 0)
	is_cache_loaded = true
	cache_load_finished.emit()

# Synchronous reload (kept for callers that explicitly want it, e.g. after the
# database is re-downloaded from GitHub).
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
	is_cache_loaded = true
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

func _on_database_downloaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
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

## Build the IMAGE_CACHE_DIR index on a worker thread; the dir listing can take
## seconds when there are thousands of files. While the index is empty, the
## getters below fall back to direct file_exists() checks.
func _start_async_image_index_build() -> void:
	var cache_dir: String = IMAGE_CACHE_DIR
	WorkerThreadPool.add_task(func():
		var local_index: Dictionary = {}
		var dir := DirAccess.open(cache_dir)
		if dir != null:
			dir.list_dir_begin()
			var fname := dir.get_next()
			while fname != "":
				if not dir.current_is_dir():
					var dot := fname.rfind(".")
					if dot > 0:
						local_index[fname.substr(0, dot)] = cache_dir + fname
				fname = dir.get_next()
			dir.list_dir_end()
		call_deferred("_on_image_index_built", local_index)
	)

func _on_image_index_built(index: Dictionary) -> void:
	_image_index = index
	_image_index_built = true

## Get cached image path (checks for all formats)
func get_image_cache_path(url: String) -> String:
	if url.is_empty():
		return ""
	var url_hash = url.md5_text()
	if _image_index_built:
		var hit: String = _image_index.get(url_hash, "")
		if not hit.is_empty():
			return hit
		return IMAGE_CACHE_DIR + url_hash
	# Index not built yet — direct file_exists check (still fast for a handful
	# of cards, just N×4 syscalls per page until the worker finishes).
	var base_path: String = IMAGE_CACHE_DIR + url_hash
	for ext in [".png", ".jpg", ".webp", ".gif"]:
		if FileAccess.file_exists(base_path + ext):
			return base_path + ext
	return base_path

## Check if image is cached
func has_cached_image(url: String) -> bool:
	if url.is_empty():
		return false
	var url_hash := url.md5_text()
	if _image_index_built:
		return _image_index.has(url_hash)
	# Index pending — fall back to file_exists per extension.
	var base_path: String = IMAGE_CACHE_DIR + url_hash
	for ext in [".png", ".jpg", ".webp", ".gif"]:
		if FileAccess.file_exists(base_path + ext):
			return true
	return false

## Save image to cache with correct extension
func cache_image(url: String, data: PackedByteArray) -> String:
	if url.is_empty() or data.is_empty():
		return ""
	
	var url_hash = url.md5_text()
	var format = _detect_image_format(data)
	
	var ext = ".bin"
	match format:
		"png": ext = ".png"
		"jpg": ext = ".jpg"
		"webp": ext = ".webp"
		"gif": ext = ".gif"
		_: ext = ".bin"
	
	var path = IMAGE_CACHE_DIR + url_hash + ext
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_buffer(data)
		file.close()
		# Keep the in-memory index in sync so subsequent has_cached_image /
		# get_image_cache_path calls see this file without re-scanning.
		_image_index[url_hash] = path
		_image_index_built = true
		return path
	return ""

## Detect video file extension from URL
func _detect_video_ext(url: String) -> String:
	var lower = url.to_lower()
	if ".webm" in lower:
		return ".webm"
	if ".ogv" in lower:
		return ".ogv"
	return ".mp4"

## Get cached video path
func get_video_cache_path(url: String) -> String:
	if url.is_empty():
		return ""
	var url_hash = url.md5_text()
	var ext = _detect_video_ext(url)
	return VIDEO_CACHE_DIR + url_hash + ext

## Check if video is cached
func has_cached_video(url: String) -> bool:
	if url.is_empty():
		return false
	return FileAccess.file_exists(get_video_cache_path(url))

## Save video to cache
func cache_video(url: String, data: PackedByteArray) -> String:
	if url.is_empty() or data.is_empty():
		return ""
	var path = get_video_cache_path(url)
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

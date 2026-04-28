@tool
extends Node

## Checks for plugin updates from GitHub Releases
## Internal class - not exposed to users
## Checks every 24 hours for new stable releases

signal update_available(version: String, url: String, changelog: String)
signal update_check_completed(has_update: bool)
signal update_error(error: String)

const CACHE_DIR = "user://shader_library_cache/"
const UPDATE_CACHE_FILE = "update_check.json"
const CHECK_INTERVAL = 86400  # 24 hours - same as shader cache

# GitHub API endpoint for latest release
const GITHUB_RELEASES_URL = "https://api.github.com/repos/Kelpekk/Godot-Shader-Library/releases/latest"

var http_request: HTTPRequest
var last_check_time: int = 0
var cached_latest_version: String = ""
var checking: bool = false

func _ready() -> void:
	_ensure_dirs()
	_setup_http()
	_load_cache()

func _setup_http() -> void:
	http_request = HTTPRequest.new()
	http_request.timeout = 15
	add_child(http_request)
	http_request.request_completed.connect(_on_release_data_received)

func _ensure_dirs() -> void:
	if not DirAccess.dir_exists_absolute(CACHE_DIR):
		DirAccess.make_dir_recursive_absolute(CACHE_DIR)

func _load_cache() -> void:
	var path = CACHE_DIR + UPDATE_CACHE_FILE
	
	if not FileAccess.file_exists(path):
		return
	
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	
	var json_str = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	if json.parse(json_str) != OK:
		return
	
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		return
	
	last_check_time = data.get("last_check", 0)
	cached_latest_version = data.get("latest_version", "")

func _save_cache() -> void:
	var data = {
		"last_check": last_check_time,
		"latest_version": cached_latest_version
	}
	
	var json_str = JSON.stringify(data, "\t")
	var file = FileAccess.open(CACHE_DIR + UPDATE_CACHE_FILE, FileAccess.WRITE)
	if file:
		file.store_string(json_str)
		file.close()

func should_check() -> bool:
	if checking:
		return false
	
	var now = int(Time.get_unix_time_from_system())
	return (now - last_check_time) >= CHECK_INTERVAL

## Check for updates - respects 24-hour cache
func check_for_updates() -> void:
	if checking:
		return
	
	if not should_check():
		# Use cached result if available
		if not cached_latest_version.is_empty():
			var current = _get_current_version()
			if _is_newer_version(cached_latest_version, current):
				# Still have a pending update
				update_available.emit(cached_latest_version, "", "")
				update_check_completed.emit(true)
			else:
				update_check_completed.emit(false)
		return
	
	checking = true
	var error = http_request.request(GITHUB_RELEASES_URL)
	if error != OK:
		checking = false
		update_error.emit("Failed to connect to GitHub")
		update_check_completed.emit(false)

func force_check() -> void:
	last_check_time = 0
	check_for_updates()

func _on_release_data_received(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	checking = false
	
	if result != HTTPRequest.RESULT_SUCCESS:
		update_error.emit("Network error")
		update_check_completed.emit(false)
		return
	
	if code == 404:
		# No releases yet
		update_check_completed.emit(false)
		return
	
	if code != 200:
		update_error.emit("GitHub API error: " + str(code))
		update_check_completed.emit(false)
		return
	
	var json_str = body.get_string_from_utf8()
	var json = JSON.new()
	if json.parse(json_str) != OK:
		update_error.emit("Invalid JSON from GitHub")
		update_check_completed.emit(false)
		return
	
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		update_error.emit("Invalid release data")
		update_check_completed.emit(false)
		return
	
	# Update cache timestamp
	last_check_time = int(Time.get_unix_time_from_system())
	
	# Parse release info
	var tag_name = data.get("tag_name", "")
	var release_url = data.get("html_url", "")
	var release_body = data.get("body", "")
	
	if tag_name.is_empty():
		update_check_completed.emit(false)
		return
	
	# Remove 'v' prefix if present (e.g., "v1.4.0" -> "1.4.0")
	var version = tag_name.trim_prefix("v")
	cached_latest_version = version
	_save_cache()
	
	# Compare with current version
	var current = _get_current_version()
	
	if _is_newer_version(version, current):
		update_available.emit(version, release_url, release_body)
		update_check_completed.emit(true)
	else:
		update_check_completed.emit(false)

## Get current plugin version from plugin.cfg
func _get_current_version() -> String:
	var config = ConfigFile.new()
	var err = config.load("res://addons/shader_library/plugin.cfg")
	if err != OK:
		return "0.0.0"
	return config.get_value("plugin", "version", "0.0.0")

## Compare semantic versions (e.g., "1.4.0" vs "1.3.3")
func _is_newer_version(latest: String, current: String) -> bool:
	var latest_parts = latest.split(".")
	var current_parts = current.split(".")
	
	# Pad to 3 parts
	while latest_parts.size() < 3:
		latest_parts.append("0")
	while current_parts.size() < 3:
		current_parts.append("0")
	
	# Compare major.minor.patch
	for i in range(3):
		var latest_num = int(latest_parts[i])
		var current_num = int(current_parts[i])
		
		if latest_num > current_num:
			return true
		elif latest_num < current_num:
			return false
	
	return false  # Same version

func clear_cache() -> void:
	last_check_time = 0
	cached_latest_version = ""
	var path = CACHE_DIR + UPDATE_CACHE_FILE
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

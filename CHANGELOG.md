# Changelog

## [1.4] - 2026-06-02

### Added
- **Animated GIF previews** — first frame of animated GIF previews from godotshaders.com renders on cards and in the preview dialog (pure-GDScript decoder, no native dependencies)
  - ▶ badge in the corner marks GIF/video shaders
  - **Watch Video** button in the preview dialog opens the full animation in the user's browser
- **Video URL support** — the scraper now extracts `<video>` URLs from each shader's detail page; cards with a `video_url` (or a GIF `image_url`) show the Watch Video button
- **Multi-select filters** — Type and License are now `MenuButton` dropdowns with checkboxes; filter by multiple categories or licenses at once. The button text shows the active count, e.g. `All types (2)`
- **Clickable category badges** — clicking a badge on any card toggles that category in the type filter; matches godotshaders.com behavior
- **Theme picker** in `Project Settings ▸ Shader Library ▸ Appearance ▸ Theme`:
  - **Classic** — colored block badge above the card image (original look)
  - **godotshaders.com** — colored bold text badge in the footer row, pill-shaped filter controls, darker background (mirrors the source website)
- **Theme-change warning** — a yellow notice appears in the browser when the theme setting changes, telling the user to restart Godot for the new theme to apply
- **Responsive grid layout** — the number of shaders per page adapts to the editor window width × editor DPI scale, so the last row never has empty trailing slots regardless of viewport

### Changed
- **godotshaders.com theme styling** — text-style category badges (no colored block above the image), pill-shaped Search/Type/License/Sort controls, darker background, redder accent
- **Filter UI** — legacy `OptionButton` dropdowns for Type and License replaced with `MenuButton + PopupMenu` for multi-select
- **Card layout** — cards reuse their Node trees across page flips instead of being freed and rebuilt
- **Startup behavior** — the addon does no real work during editor startup; UI build, JSON parse, and component init are deferred until the first time the ShaderLib tab is opened
- **Major performance pass** — the browser stays responsive with 2000+ shaders loaded:
  - Lazy init keeps the addon out of the editor's "Loading plugin window layout" phase entirely
  - `JSON.parse` of the on-disk shader cache runs on a `WorkerThreadPool` worker (was ~100-300 ms of main-thread blocking)
  - Image-cache directory scan also runs on a worker (was multi-second hang for users with thousands of cached images)
  - **Card pool** — 40 cards built once, reused on every filter change / page flip (eliminated ~800 node allocations per page)
  - **Persistent `TextureRect` per card** — image texture is swapped in/out instead of allocating a new node on every image load
  - **`Theme` resource per category** — one assignment replaces ~12-18 `add_theme_*_override()` calls per badge
  - **Pre-computed per-shader fields** — `_lc_title`, `_lc_author`, `_lc_cat`, `_emoji`, `_likes_str`, `_disp_cat`, `_img_bg_color`, `_emoji_color`, `_badge_theme`, `_has_video` are computed once on data load so the hot paths do dict lookups instead of string ops
  - **Chunked updates** — populate / pool growth / precompute / cache-hit image apply all break their work into deferred chunks (6-300 items per frame) so the editor stays responsive
  - **Skip-if-same** — `_populate_card` only writes a property when its value actually changed, avoiding theme-propagation notifications
  - **In-memory texture cache** (FIFO, 160 entries) — revisiting a page applies already-uploaded GPU textures with no disk read, decode, or re-upload
  - **GIF first frames cached as flat textures** — each GIF is decoded at most once per session; later visits show it as a still image with no worker decode or GifPlayer
  - **Card-resolution downscale before GPU upload** — previews are capped at 480 px wide before texture creation, cutting upload size and keeping the texture cache well under ~50 MB
  - **Pre-sorted source views** — the "Most liked" and "Alphabetical" orders are built once on data load; changing filters iterates the matching sorted view and never re-sorts (was a `sort_custom` over the whole result on every filter change)
  - **Incremental search** — appending characters narrows the previous result set (tens of entries) instead of rescanning all ~2100 shaders on every keystroke
  - **Off-thread image decode** — PNG/JPG/WebP decode + downscale run on `WorkerThreadPool`; only the final GPU upload stays on the main thread (replaces the per-frame decode throttle)
  - Search input is debounced (200 ms)
  - Filter pipeline is a single pass instead of three chained `.filter()` calls
  - StyleBoxes for card panels and badges are shared across cards
  - `Translations.t()` caches resolved locale dictionaries
  - HTML-entity decoder reuses compiled `RegEx` and entity tables

### Fixed
- **Critical: shader database URL was pointing to a non-existent repo** — `cache_manager.gd` had `Kelpekk/shaderlibrary/main/data/shaders.json` (wrong) instead of `Kelpekk/Godot-Shader-Library/main/data/shaders.json` (correct). Without this fix the daily auto-updates of the shader database silently fail for end users.
- **Black image on GIF cards after a few filter changes** — `_on_gif_card_ready` was `queue_free`-ing the placeholder node, which broke the pooled card structure when the slot was later repopulated with another shader. Placeholder is now hidden, not freed.
- **Image decode error for some shaders** — `_load_image_from_buffer` now falls back through every decoder (PNG → JPEG → WebP) when magic-byte detection is inconclusive; previously these were silently skipped
- **GIF previews no longer glitch** — earlier attempts at full GIF animation produced corrupted frames after the first one because of disposal-method/encoder-convention divergence; the new first-frame-only strategy is stable across every preview on godotshaders.com
- **Card backgrounds render correctly behind transparent GIF pixels** — the GifPlayer uses a PanelContainer with an explicit black stylebox so the card's category-tinted background never leaks through
- **Category badge text on cards** — `_populate_card` and the badge-press handler now normalize `canvas_item` to `canvas item` consistently so the type filter and category color lookup match (previously badges for canvas-item shaders rendered with the default gray fallback color)
- **Black card tiles after resizing the window / changing cards-per-row** — three combined causes: `_display_page` blanked every static GIF player's texture on each repopulate; stale `GifPlayer`s could stack and render on top of new content; and cards re-queued images they were already showing. Fixed by removing the blanking loop, de-duplicating players in the apply functions, and tracking a per-card `loaded_url`.
- **Stale async results no longer land on the wrong card** — an image/GIF decode that finishes after its card was repopulated with a different shader is now dropped (the texture is still cached for a later visit) via the `_card_wants_url` guard

### Technical
- New `api/gif_decoder.gd` (GIF89a header + LZW, first frame only)
- New `ui/gif_player.gd` (static texture display, no animation timer)
- `cache_manager.gd`:
  - `_start_async_cache_load` + `_on_async_cache_parsed` + `cache_load_finished` signal — JSON parse moved off the main thread
  - `_start_async_image_index_build` + `_on_image_index_built` — image-cache directory scan moved off the main thread; getters fall back to `FileAccess.file_exists` while the index is pending
  - `cache_image()` keeps the index in sync with disk
- `translations.gd` caches `_primary_dict`, `_lang_dict`, `_english_dict`; `refresh_locale()` invalidates them; new `watch_video` key in all 9 locales
- `shader_browser.gd`:
  - `_card_pool: Array` + `_installed_cards: Array` — separate tracking so Browse-tab vs Installed-tab cards don't corrupt each other on tab switches
  - `_display_gen` counter — deferred update chunks bail when a newer `_display_page` starts (filter-spam safety)
  - `_create_category_badge_pooled` + card-bound signal handlers (`_on_card_preview_pressed`, `_on_card_install_pressed`, `_on_card_select_pressed`, `_on_card_badge_pressed`) — signals connect once at create time and read the current shader from `card.get_meta("shader")`
  - `_recompute_layout` listens to `shader_grid.resized` (150 ms debounce) and re-derives `shaders_per_page = cards_per_row × ROWS_PER_PAGE` so the last row stays full
  - `EditorInterface.get_editor_scale()` cached as `_editor_scale`; card / image-area sizes and grid separations are multiplied by it
  - `THEMES` array + `_apply_theme()` reads `shader_library/appearance/theme` from `ProjectSettings`; the palette controls `bg_color`, `card_bg`, `accent`, `text_dim`, and `_badge_style_mode`
  - `_make_pill_stylebox` + `_get_pill_button_theme` + `_get_pill_lineedit_theme` — shared pill styles for the godotshaders.com theme, applied via `node.theme = ...` rather than per-state stylebox overrides
  - `_tex_cache` / `_tex_cache_keys` — FIFO in-memory texture cache (`TEX_CACHE_MAX = 160`); `_tex_cache_put` evicts the oldest entry
  - `_downscale_for_card` (`CARD_TEX_MAX_WIDTH = 480`) — bilinear downscale before `ImageTexture.create_from_image`
  - `_shaders_by_likes` / `_shaders_by_title` built by `_build_sorted_views`; precompute adds `_likes_int` / `_sort_title` sort keys so the comparators don't recompute per comparison
  - `_filter_sig` + `_last_query` / `_last_filter_sig` — guard that enables incremental query narrowing only when type/license/sort are unchanged
  - `_decode_path_to_card_image` / `_decode_bytes_to_card_image` / `_on_async_image_decoded` (`MAX_DECODE_TASKS = 4`) — bounded off-thread decode pipeline; `_card_wants_url` is the staleness guard
  - per-card `loaded_url` meta — skips re-applying content the card already shows
- `plugin.gd`:
  - `_make_visible(true)` uses `call_deferred("lazy_init")` so the editor's plugin-layout-restore phase isn't blocked by addon work
  - Registers `shader_library/appearance/theme` project setting with a `Classic, godotshaders.com` enum hint
- `scripts/scrape_shaders.py` extracts `video_url` from `<video>` tags on each shader's detail page and marks GIF `image_url` entries as `video_url` so the Watch Video button works for both real videos and GIFs

## [1.3.4.1] - 2026-05-07

### Changed
- Added unofficial plugin disclaimer to README and Asset Library description, as requested by godotshaders.com

## [1.3.4] - 2026-04-28

### Added
- **Update Notification System** - Non-intrusive version checking and update notifications
  - Checks GitHub releases API every 24 hours for new plugin versions
  - Shows "Update Available" button in UI when new version is detected
  - Displays version comparison and changelog preview in dialog
  - Links directly to GitHub releases page for manual updates
  - Semantic version comparison ensures accurate version detection
  - Respects 24-hour cache system to minimize API requests
  - No automatic installation - users update manually via Godot AssetLib or GitHub

### Changed
- **Documentation Updates** - Improved update process clarity
  - Added warning about Godot AssetLib update limitation (requires plugin disable/reinstall)
  - Documented manual update process with clear step-by-step instructions
  - Added recommendation to use GitHub installation for easier updates
  - Removed references to non-existent auto-update system from documentation

### Technical
- New `UpdateChecker` class in `api/update_checker.gd`
- GitHub API integration: `/repos/Kelpekk/Godot-Shader-Library/releases/latest`
- Version caching and comparison system
- UI integration with shader browser

## [1.3.3] - 2026-04-23

### Fixed
- **Critical Parse Error** - Fixed shader browser not loading due to missing `update_checker.gd` file
  - Removed references to non-existent `UpdateChecker` class that was causing parse errors
  - Shader library window now loads correctly on plugin activation
  - Auto-update feature temporarily disabled until proper implementation
  - All update-related functions commented out to prevent future errors

### Changed
- Temporarily disabled auto-update system for stability
- Update button removed from UI until feature is fully implemented

### Technical
- Commented out `UpdateChecker` preload and initialization
- Disabled update-related signal connections and callbacks
- All update UI elements temporarily removed

## [1.3.2] - 2026-04-22

### Added
- **Auto-Update System** - Automatic plugin update detection and installation
  - Checks GitHub for new releases on startup (configurable)
  - Shows "Update Available" button when new version is detected
  - One-click download and installation of updates
  - Automatic editor restart after update
  - Configurable via `plugin.cfg` with `github_repo` setting
  - Smart version comparison using semantic versioning
  - Displays changelog in update dialog
  - Creates backup before updating
  - Graceful error handling with user notifications

### Changed
- Updated version to 1.4.0
- Added `[updates]` section in `plugin.cfg` for configuration

### Technical
- New `UpdateChecker` class in `api/update_checker.gd`
- GitHub API integration for release checking
- ZIP download and extraction system
- Editor restart functionality

## [1.3.1] - 2026-04-20

### Added
- **Clickable Links** - URLs in shader descriptions now open in browser when clicked
  - Links are highlighted in blue and underlined for visibility
  - Works with all links in descriptions (YouTube, Shadertoy, documentation, etc.)
  - Browser window automatically gets focus on Windows (no need to click window)

- **ShaderApplier Node** - New custom node type for applying shaders directly in inspector
  - Add ShaderApplier as child of any supported 2D or 3D node
  - Select shaders from library using built-in picker with "📚 Shader Library" option
  - Automatic shader application to parent node
  - Prevents duplicate ShaderApplier on same node
  - Warns when parent already has material assigned
  - **Supported 2D nodes (CanvasItem):**
    - Sprite2D, AnimatedSprite2D
    - ColorRect, TextureRect, Panel, NinePatchRect
    - Line2D, Polygon2D
    - Label, RichTextLabel, Button (all Control nodes)
    - GPUParticles2D, CPUParticles2D
    - Node2D, Control (and all descendants)
  - **Supported 3D nodes:**
    - MeshInstance3D
    - Sprite3D, AnimatedSprite3D
    - MultiMeshInstance3D
    - Label3D
    - CSGShape3D (CSGBox3D, CSGSphere3D, etc.)
    - GPUParticles3D, CPUParticles3D
- **HiDPI Scaling Support** - UI now scales properly on 4K/high-DPI displays
  - Uses `EditorInterface.get_editor_scale()` for proper scaling
  - All font sizes, margins, spacing, and UI elements scale correctly
  - Thanks to [@hapenia](https://github.com/hapenia) for this contribution! (PR #3)

- **License Filter** - Added new filter option to browse shaders by license type
  - Filter by MIT, CC0, CC-BY, Shadertoy port, or GNU GPL v.3 licenses
  - Located next to Shader Type filter for easy access
  - Translated to 6 languages (English, Polish, German, Spanish, French, Chinese)

### Changed
- **Sort Options** - Sorting options now match godotshaders.com for consistency:
  - Added "Most relevant" as first option (default sorting from API)
  - Changed "Popular" to "Most liked"
  - Changed "Name A-Z" to "Alphabetical"
  - Order: Most relevant, Newest, Most liked, Alphabetical

### Fixed
- **ShaderApplier Cleanup** - Shader material is now properly removed from parent node when ShaderApplier is deleted
  - Prevents orphaned shaders on nodes after removing ShaderApplier
  - Added `_exit_tree()` function to clean up on removal

- **New Shader Type Selection** - "New Shader" button now shows dialog to choose shader type
  - Choose from: Spatial (3D), CanvasItem (2D), Particles, Sky, or Fog
  - No longer hardcoded to canvas_item type
  - Visual Shader creation unchanged (creates VisualShader resource directly)

- **New Shader Buttons** - "New Shader" and "New Visual Shader" menu options in ShaderApplier now work correctly
  - Opens save dialog to save the new shader file
  - Automatically applies the shader after saving
  - Opens shader in editor for immediate editing

- **Nested List Descriptions** - Fixed shader parameters with nested descriptions not showing
  - Parameters like "Dissolve Value" now correctly show their sub-descriptions
  - Fixed `</li>` tag matching for nested list structures

- **Shader Description Display** - Fixed HTML entity decoding and description formatting
  - HTML entities (like `&#8220;`, `&#8221;`) now properly decode to readable characters
  - Removed metadata clutter (shader title, author name, duplicate dates, "Report" button text)
  - Removed CSS/JSON-LD junk from descriptions
  - Added BBCode formatting for better readability:
    - Bold text for `<strong>` tags
    - Italic text for `<em>` tags
    - Colored bullets (•) for list items
    - Section headers are bolded without bullets
  - List items (e.g., "Amount: Set this to...") automatically formatted with colored bullets
  - Section headers (e.g., "Parameters:", "Quick Setup:") displayed as bold text
  - Multi-line paragraphs with embedded metadata now properly split and cleaned
  - Description extraction now filters out navigation elements, dates, and schema markup

- Fixed static function call: `EditorInterface.get_base_control()` now called correctly
- Fixed variable shadowing built-in `hash` function in cache_manager.gd
- Fixed unused parameter warnings in shader_browser.gd and shader_applier_inspector.gd
- Cleaned up dead code (unused variables)

### Added (Scraper)
- **Extended Shader Data** - Now fetches additional information from shader detail pages:
  - Full shader description text
  - Tags list (e.g., "Retro", "Post Processing", "CRT")
  - Actual license type (MIT, CC0, CC-BY, Shadertoy port, GNU GPL v.3)
  - Complete shader code
  - Publication date
  - Author profile URL
- **Robust Error Handling**:
  - Automatic retry with exponential backoff (3 attempts)
  - URL validation for all collected links
  - JSON sanitization to prevent encoding issues
  - Detailed error logging with statistics
- **Connection Reuse** - Uses requests Session for better performance
- **Data Validation** - Validates all shader entries before saving
- **Statistics Report** - Shows detailed breakdown after scraping (categories, licenses, data completeness)

### Fixed (Scraper)
- **License Detection** - Fixed scraper not detecting all license types correctly
  - Now properly detects license indicator images (mit_license_icon.png, shadertoy_port.png, gpl_icon.png)
  - Improved text-based detection for Shadertoy ports (CC BY-NC-SA) and GNU GPL licenses
  - All 2000+ shaders were incorrectly marked as CC0 - now correctly categorized
  - Added support for "Shadertoy port" and "GNU GPL v.3" license types
- **HTML Entity Decoding** - Fixed `&#8220;` and `&#8221;` being displayed instead of proper quotes (`"`)
- Added double-pass HTML entity decoding for double-encoded entities
- Added Unicode normalization for special characters (smart quotes, dashes, etc.)
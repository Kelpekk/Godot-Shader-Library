# Changelog

## [1.3.2] - 2026-04-20

### Fixed
- **License Detection** - Fixed scraper license detection to correctly identify all license types
  - CC0: 1508 shaders
  - MIT: 466 shaders
  - Shadertoy port: 101 shaders
  - GNU GPL v.3: 20 shaders

### Changed
- **Shader Database** - Updated to 2095 shaders with accurate license information

## [1.3.1] - 2026-04-19

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
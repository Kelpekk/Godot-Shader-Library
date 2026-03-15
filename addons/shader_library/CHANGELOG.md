# Changelog

## [1.3.0] - 2026-03-12

### Added
- `.gitattributes` - Users download only addons folder from Asset Library

### Fixed
- GitHub Actions workflow permissions for auto-updates
- Updated to Node.js 24 compatible actions

### Changed
- Cache duration clarified to 24 hours (daily auto-refresh)
- Updated README documentation

## [1.2.0] - 2026-03-10

### Added
- **Installed Shaders Tab** - Manage installed shaders
  - View all installed shaders in res://shaders/shaderlib/
  - Open shader in editor with one click
  - Delete installed shaders with confirmation
  - Auto-scan on installation
- **Improved HTML Parser** - More reliable code extraction
  - Multiple extraction methods (code, pre, regex)
  - Better handling of different HTML structures
  - Fallback strategies for edge cases

### Changed
- Added tab navigation (Browse / Installed)
- Installed count shown in tab button
- Green border for installed shader cards

### Technical
- New `installed_manager.gd` for installed shaders
- Improved `_extract_shader_code()` with regex

## [1.1.0] - 2026-03-10

### Added
- **Shader Preview Dialog** - View shader code before installing
  - Syntax highlighting for GLSL/Godot shader language
  - Copy code to clipboard
  - Open in browser option
- **Category Placeholders** - Colorful category-based card backgrounds
  - Each category has unique color (Spatial=blue, Canvas Item=pink, etc.)
  - Category emoji icons (🎲 3D, 🎨 2D, ☁️ Sky, ✨ Particles, 🌫️ Fog)
- **Installation Progress** - Visual progress indicator during installation
  - Shows current status (connecting, parsing, saving)
  - Progress bar with percentage
- **Hover Effects** - Card highlighting on mouse over
- **Improved Card Design** - Rounded corners, borders, better spacing

### Changed
- Renamed "View" button to "Preview" for code preview
- Increased card height for better layout
- Enhanced visual feedback during operations

### Technical
- New `installation_progress` signal with detailed status
- Preview dialog with CodeEdit and CodeHighlighter
- Hover state management for cards
- Category-based color system for visual distinction

## [1.0.0] - 2026-03-10

### Added
- Initial release of Shader Library addon
- Browse shaders from godotshaders.com
- Search and filter functionality
- One-click shader installation
- Local caching system (1 hour cache)
- Proper author attribution and licensing
- Asset Library-style UI
- Support for CC0, MIT, and GPL v3 licenses
- Automatic shader directory creation
- Error handling and user feedback dialogs

### Features
- **Scraper** - Parses godotshaders.com HTML
- **Cache** - Stores shader data locally to reduce HTTP requests
- **Installer** - Downloads and saves shaders with proper headers
- **UI** - Clean, familiar interface similar to Godot Asset Library

### Technical
- Uses HTTPRequest for web scraping
- JSON-based cache storage
- Automatic HTML entity decoding
- Filename sanitization
- Rate-limiting friendly (cached requests)

## Roadmap

### [1.3.0] - Planned
- Live scraping from godotshaders.com (replace hardcoded data)
- Shader tags display
- Pagination support
- More accurate like counts

### [2.0.0] - Future
- Offline mode with full local database
- Integration with Godot's shader editor
- Real-time preview in viewport
- Shader parameter editor

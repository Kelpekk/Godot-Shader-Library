# Shader Library - Godot Addon

Browse and download shaders from [godotshaders.com](https://godotshaders.com) directly in the Godot Editor!

## 🎨 Features

- **Browse Shaders** - See all available shaders from godotshaders.com
- **Search & Filter** - Find shaders by name, author, or category
- **One-Click Install** - Download and add shaders to your project instantly
- **Local Cache** - Faster loading with automatic caching
- **Proper Attribution** - Shows author, license, and original links
- **Asset Library Style UI** - Familiar interface like Godot's Asset Library

## 📦 Installation

1. Copy the `addons/shader_library` folder to your Godot project
2. Open your project in Godot
3. Go to **Project → Project Settings → Plugins**
4. Enable **Shader Library**
5. The Shader Library panel will appear in the top-right dock

## 🚀 Usage

### Browse Shaders
1. Open the **Shader Library** panel (top-right dock)
2. Click **Refresh** to fetch latest shaders
3. Browse through shader cards

### Search
1. Type in the search box (e.g., "water", "glow")
2. Press Enter or click Search
3. Results update automatically

### Filter by Category
1. Use the **Filter** dropdown
2. Select: All, 2D, 3D, Visual Effect, or Post-Processing

### Install a Shader
1. Find the shader you want
2. Click **Install** button
3. Shader will be added to `res://shaders/shaderlib/` folder

### View Original
1. Click **View** button on any shader card
2. Opens the original shader page on godotshaders.com

## 📁 Project Structure

```
addons/shader_library/
├── plugin.cfg              # Plugin configuration
├── plugin.gd               # Main EditorPlugin
├── api/
│   ├── godotshaders_scraper.gd  # Web scraper
│   └── cache_manager.gd         # Local cache system
└── ui/
    ├── shader_browser.gd        # Main UI script
    └── shader_browser.tscn      # Main UI scene
```

## ⚖️ Legal & Attribution

This addon respects godotshaders.com's open philosophy:

- **All shaders** are under CC0, MIT, or GPL v3 licenses
- **Authors are credited** in the UI
- **Original links** are always provided
- **robots.txt compliance** - No restrictions on crawling
- **Rate limiting** - Respectful HTTP requests with delays

### From godotshaders.com:
> "We want to make Godot Shaders as free as possible and to follow the  
> open-source philosophy within the Godot community."

## 🔧 Technical Details

### Cache System
- Shaders are cached locally in `user://shader_library_cache/`
- Cache expires after 1 hour
- Manual refresh available via Refresh button

### HTTP Requests
- Uses Godot's HTTPRequest node
- Parses HTML to extract shader data
- Fallback data available for testing

### Data Structure
Each shader contains:
- Title
- Author
- URL (link to original)
- Category
- License
- Code (when detail page is fetched)

## 🚧 Roadmap

- [x] Basic UI and browsing
- [x] Search and filtering
- [x] Cache system
- [ ] Full shader installation
- [ ] Preview images
- [ ] Shader code preview
- [ ] Download progress indicator
- [ ] Favorites/bookmarks
- [ ] License display in cards
- [ ] Better HTML parsing

## 📝 License

This addon is under MIT License.

Individual shaders have their own licenses (CC0, MIT, or GPL v3) as specified by their authors on godotshaders.com.

## 🙏 Credits

- **Shaders** - Community contributors at [godotshaders.com](https://godotshaders.com)
- **Website** - Created by Peter Höglund
- **Addon** - Built with ❤️ for the Godot community

## 📧 Contact

For questions about:
- **This addon** - Open an issue on GitHub
- **godotshaders.com** - Contact info@godotshaders.com
- **Specific shaders** - Contact the shader's author

---

**Enjoy creating beautiful shaders! 🎨✨**

# 🎨 Shader Library - Godot Addon

[![Godot Engine](https://img.shields.io/badge/Godot-4.x-blue?logo=godot-engine&logoColor=white)](https://godotengine.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Browse and install shaders from [godotshaders.com](https://godotshaders.com) directly in the Godot Editor!

![Shader Library Preview](screenshots/preview.png)

## ✨ Features

- **🔍 Browse 2000+ Shaders** - Access the entire godotshaders.com library
- **🔎 Search & Filter** - Find shaders by name, author, or category (Spatial, Canvas Item, etc.)
- **📥 One-Click Install** - Download shaders directly to your project
- **👁️ Preview** - View shader details, description, tags, and code before installing
- **💾 Smart Caching** - 24-hour cache with daily auto-updates
- **🌍 Multi-Language** - Supports English, Polish, German, Spanish, French, Chinese, Japanese, Russian, Portuguese
- **🎯 Godot Native UI** - Seamless integration with Godot Editor

## 📦 Installation

### From GitHub

1. Download this repository (Code → Download ZIP)
2. Copy the `addons/shader_library` folder to your Godot project
3. Open your project in Godot 4.x
4. Go to **Project → Project Settings → Plugins**
5. Enable **Shader Library**
6. Click on **Shadery** tab in the top menu bar

### From Godot Asset Library

*Coming soon!*

## 🚀 Usage

### Browse Shaders
1. Open the **Shadery** tab (top menu bar)
2. Browse through shader cards with previews
3. Use pagination to navigate (40 shaders per page)

### Search
Type in the search box and press Enter to find specific shaders.

### Filter by Type
Use the dropdown to filter by:
- All Types
- Spatial (3D)
- Canvas Item (2D)
- Particles
- Sky
- Fog

### Preview Shader
Click **Preview** to see:
- Full-size image
- Author & license info
- Description & tags
- Complete shader code
- Direct link to godotshaders.com

### Install Shader
Click **Install** to download the shader to `res://shaders/` folder.

## 📁 Structure

```
addons/shader_library/
├── plugin.cfg          # Plugin configuration
├── plugin.gd           # Main plugin entry point
├── icon.svg            # Plugin icon
├── api/
│   ├── cache_manager.gd      # Downloads shader database from GitHub
│   ├── installed_manager.gd  # Track installed shaders
│   ├── shader_installer.gd   # Download & install shaders
│   └── translations.gd       # Multi-language support
└── ui/
    ├── shader_browser.gd     # Main UI logic
    └── shader_browser.tscn   # UI scene
```

## 🌐 Supported Languages

The addon automatically detects your Godot editor language:

| Language | Code |
|----------|------|
| English | en |
| Polski | pl |
| Deutsch | de |
| Español | es |
| Français | fr |
| 中文 | zh_CN |
| 日本語 | ja |
| Русский | ru |
| Português | pt_BR |

## 📋 Requirements

- Godot 4.0 or higher
- Internet connection (for fetching shaders)

## 🤝 Contributing

Contributions are welcome! Feel free to:
- Report bugs
- Suggest features
- Submit pull requests

## 📄 License

MIT License - see [LICENSE](LICENSE) file.

## 🙏 Credits

- Shaders from [godotshaders.com](https://godotshaders.com)
- All shader authors retain their original licenses

---

Made with ❤️ for the Godot community

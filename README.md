# 🎨 Shader Library - Godot Addon

[![Godot Engine](https://img.shields.io/badge/Godot-4.x-blue?logo=godot-engine&logoColor=white)](https://godotengine.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.3.3-orange)](CHANGELOG.md)

Browse and install shaders from [godotshaders.com](https://godotshaders.com) directly in the Godot Editor!

> 🎬 **[Watch Video Showcase](https://youtu.be/qrtgDjqs3Uk)** - See the plugin in action!

![Shader Library Preview](screenshots/preview.png)

## ✨ Features

### Core Features
- **🔍 Browse 2000+ Shaders** - Access the entire godotshaders.com library
- **🔎 Smart Search & Filter** - Find shaders by name, author, or category (Spatial, Canvas Item, Particles, Sky, Fog)
- **📥 One-Click Install** - Download shaders directly to your project with a single click
- **👁️ Rich Preview** - View full shader details:
  - 📸 High-quality preview image
  - 📝 Complete description with clickable links
  - 🏷️ Tags and categories
  - 💻 Full shader code
  - 👤 Author info and license
  - 🔗 Direct link to godotshaders.com

### Workflow Tools
- **🎯 ShaderApplier Node** - Apply shaders via custom inspector node
  - Supports 30+ node types (2D & 3D)
  - Browse library directly from inspector
  - Create new shaders with templates
- **📦 Installed Manager** - View, open, and delete installed shaders
- **� Auto-Update System** - Automatic update detection and one-click installation
  - Checks for new plugin versions on GitHub
  - Shows update notification when available
  - Downloads and installs updates automatically
  - Restarts editor to apply changes
- **�💾 Smart Caching** - 24-hour cache with daily auto-updates
- **🖥️ HiDPI Support** - Perfect scaling on 4K/high-DPI displays
- **🌍 Multi-Language** - 9 languages supported
- **🎨 Native Godot UI** - Seamless integration with editor theme

## 📦 Installation

### From Godot Asset Library

1. Open Godot 4.x
2. Go to **AssetLib** tab
3. Search for **"Shader Library"**
4. Click **Download** and **Install**
5. Enable in **Project Settings → Plugins**

### From GitHub

1. Download this repository (Code → Download ZIP)
2. Copy the `addons/shader_library` folder to your Godot project
3. Open your project in Godot 4.x
4. Go to **Project → Project Settings → Plugins**
5. Enable **Shader Library**
6. Click on **ShaderLib** tab in the top menu bar

## 🚀 Usage

### Browse Shaders
1. Open the **ShaderLib** tab (top menu bar)
2. Browse through shader cards with previews
3. Use pagination to navigate (40 shaders per page)

### Search & Filter
- Type in the search box and press Enter
- Use dropdown to filter by: All, Spatial (3D), Canvas Item (2D), Particles, Sky, Fog

### Preview Shader
Click **Preview** to see:
- Full-size image
- Author & license info
- Description & tags
- Complete shader code
- Direct link to godotshaders.com

### Install Shader
Click **Install** to download the shader to `res://shaders/shaderlib/` folder.

### Manage Installed
1. Switch to **Installed** tab
2. View all installed shaders
3. Click to open shader in editor
4. Delete shaders with confirmation

### ShaderApplier Node
1. Add **ShaderApplier** node as child of any supported node:
   - **2D (CanvasItem)**: Sprite2D, AnimatedSprite2D, ColorRect, TextureRect, Panel, NinePatchRect, Line2D, Polygon2D, Label, GPUParticles2D, CPUParticles2D, Node2D, Control, and all CanvasItem descendants
   - **3D**: MeshInstance3D, Sprite3D, AnimatedSprite3D, MultiMeshInstance3D, Label3D, CSGShape3D, GPUParticles3D, CPUParticles3D
2. In the inspector, click the shader selector dropdown
3. Select **"📚 Shader Library"** to browse and install shaders
4. Shader is automatically applied to the parent node

## 📁 Structure

```
addons/shader_library/
├── api/
│   ├── cache_manager.gd        # Downloads shader database
│   ├── installed_manager.gd    # Track installed shaders
│   ├── shader_installer.gd     # Download & install shaders
│   ├── translations.gd         # Multi-language support
│   └── update_checker.gd       # Auto-update system
└── ui/
    ├── shader_browser.gd       # Main UI logic
    ├── shader_browser.tscn     # UI scene
    └── shader_selector_dialog.gd # Shader selector for inspector
├── icon.png                    # Addon icon
├── plugin.cfg                  # Plugin configuration
├── plugin.gd                   # Main plugin entry point
├── shader_applier_inspector.gd # Custom inspector plugin
├── shader_applier.gd           # ShaderApplier custom node
```

## ⚙️ Configuration

### Auto-Update System

The plugin can automatically check for updates from GitHub. To configure:

1. Open `addons/shader_library/plugin.cfg`
2. In the `[updates]` section, set your GitHub repository:
   ```ini
   [updates]
   # GitHub repository for checking updates (format: username/repository)
   github_repo="YOUR_USERNAME/godot-shader-library"
   # Set to false to disable auto-update checks
   auto_check=true
   ```
3. The plugin will check for updates 2 seconds after startup
4. When an update is available, an "Update Available" button appears in the toolbar
5. Click to download and install - the editor will restart automatically

**For Plugin Developers:**
- Create releases on GitHub with version tags (e.g., `v1.4.0`)
- Include a `.zip` file with the addon in the release assets
- The plugin compares versions and notifies users automatically

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

All shader authors retain their original licenses (CC0, MIT, or GPL v3).

## 🙏 Credits

- Shaders from [godotshaders.com](https://godotshaders.com)
- HiDPI Support - [@hapenia](https://github.com/hapenia)
- Video Showcase - [Watch on YouTube](https://youtu.be/qrtgDjqs3Uk)

---

Made with ❤️ for the Godot community

# 🎮 UntoldArcade

**UntoldArcade** is a collection of demos built with the [Untold Engine](https://github.com/untoldengine/UntoldEngine).  
These demos give game developers a **quick look** at what the engine can do.

The demos included are:

- 🏠 **HomeDesign** – a visionOS mixed-reality demo: pick a pre-furnished floor plan, place it on your real floor, and walk through it at full scale or from a bird's-eye view. Also shows off the engine's Rendering Extension system by integrating **CoolWater** (below) to render a real-time animated pool.
- 🛠️ **SceneBuilder** – a declarative scene-building demo using SwiftUI-style syntax to construct 3D scenes programmatically.

### Rendering Extensions

- 💧 **CoolWater** – a reusable Rendering Extension package (owns its own shader library, pipelines, and render-graph passes) that draws an animated water surface with reflection/refraction and ripple simulation. Ships with its own standalone visionOS example (`CoolWater/Examples/CoolWaterVisionOS`) and is also consumed directly by **HomeDesign** as a real-world integration example.

---

## ⚙️ Requirements

- **Xcode 26.1** or later
- **macOS 26.01+** (for macOS demos)
- **iOS 26.01+** (for iOS demos)
- **visionOS 26.01+** (for Vision Pro demos)
- Metal-capable GPU

---

## 🚀 Getting Started

### 1. Clone the repo
```bash
git clone https://github.com/untoldengine/UntoldArcade.git
cd UntoldArcade
```

### 2. Open a demo project
Each demo is a standalone Xcode project. Navigate to the demo folder and open the `.xcodeproj` file:

```bash
# For HomeDesign (visionOS)
open HomeDesign/HomeDesign.xcodeproj

# For SceneBuilder
open SceneBuilder/SceneBuilder.xcodeproj

# For the CoolWater rendering extension's own example (visionOS)
open CoolWater/Examples/CoolWaterVisionOS/CoolWaterVisionOS.xcodeproj
```

> HomeDesign's Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen). If you add/remove source files or change dependencies, re-run `xcodegen generate` inside `HomeDesign/` before opening/building.

### 3. Build and run
- Select your target device (Mac, iPhone, iPad, or Vision Pro simulator)
- Press `⌘R` to build and run
- SPM will automatically fetch the Untold Engine dependency on first build

## 🔗 Engine Dependency

Each demo project depends on the Untold Engine via Swift Package Manager (SPM).

Game developers: The workspace is already configured to fetch the engine from its develop branch on GitHub.

## 📂 Project Structure

```bash
UntoldArcade/
├── HomeDesign/                # visionOS mixed-reality floor-plan/home-design demo
│   ├── Sources/                # App source code + bundled GameData (models, scenes, thumbnails)
│   ├── Vendor/CoolWater/       # Vendored copy of the CoolWater rendering extension
│   └── Tests/                  # Unit tests
├── CoolWater/                  # Rendering Extension: real-time animated water
│   ├── Sources/                 # Extension source (shaders, simulation, render passes)
│   ├── Examples/                # Standalone visionOS consumer example
│   └── Tests/                   # Unit tests
└── SceneBuilder/                # Declarative scene-building demo
    ├── Sources/                  # Demo source code
    └── Resources/                 # Demo assets
```

## 🤝 Contributing

We welcome contributions! If you'd like to:
- Add a new demo game
- Improve existing demos
- Enhance documentation

Please fork the repo, open a PR, or join discussions in the [Untold Engine repo](https://github.com/untoldengine/UntoldEngine).

📜 License

This project follows the same license as Untold Engine.

See the LICENSE file for details.

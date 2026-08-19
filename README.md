# 🎮 UntoldArcade

<!--
  MEDIA: top-of-README hero. Drop a short looping GIF or MP4 here (recommended: a fast
  cut of 3-4 demos in action, 1280x720, <10s loop) at docs/media/banner.gif and
  uncomment the line below.
-->
<!-- ![UntoldArcade banner](docs/media/banner.gif) -->

**UntoldArcade** is the demo playground for the [Untold Engine](https://github.com/untoldengine/UntoldEngine) — a real, running Xcode project for every major thing the engine can do, from mixed-reality digital twins to GPU cloth you can punch a ball through.

Clone it, open a folder, hit `⌘R`, and you're looking at the feature instead of reading about it.

---

## 📺 Demos

Each demo is a **standalone Xcode project** with its own README, tutorial, and bundled assets — no setup beyond opening the `.xcodeproj`. The three Rendering Extensions (CoolSaber, CoolWater, CoolCloth) are reusable plugins — each ships its own shader library, pipelines, and render-graph passes, and can be dropped into any project.

### ⚔️ CoolSaber — *visionOS · Rendering Extension*

![CoolSaber demo](docs/media/CoolSaber/demo.gif)

Lightsaber duels driven by PSVR2 Sense controllers — pull the trigger to ignite a glowing blade, then duel a friend over SharePlay with clashing sparks, haptic kicks, and synthesized saber audio. **Requires a physical Vision Pro** (the deferred G-buffer exceeds simulator tile memory).

```bash
open CoolSaber/Examples/CoolSaberVisionOS/CoolSaberVisionOS.xcodeproj
```

### 💧 CoolWater — *visionOS · Rendering Extension*

![CoolWater demo](docs/media/CoolWater/demo.gif)

Real-time animated water with reflection/refraction and ripple simulation.

```bash
open CoolWater/Examples/CoolWaterVisionOS/CoolWaterVisionOS.xcodeproj
```

### 🧵 CoolCloth — *visionOS · Rendering Extension*

![CoolCloth demo](docs/media/CoolCloth/demo.gif)

GPU cloth simulation (XPBD, small-steps scheme) hanging in your real room — pinch it to grab a particle, throw a ball through it, switch materials live, and let real furniture occlude it.

```bash
open CoolCloth/Examples/CoolClothVisionOS/CoolClothVisionOS.xcodeproj
```

### 🏛️ ArchvizViewer — *visionOS*

![ArchvizViewer demo](docs/media/ArchvizViewer/demo.gif)

Load a Blender-authored architectural visualization straight into mixed reality — lights, camera, and color management carried over exactly as the artist set them up. Pinch-drag and two-hand rotate to walk the scene around your room. Reference project for the [Archviz To Vision Pro](https://untoldengine.github.io/UntoldEngine/LearningPaths/ArchvizToVisionPro/) tutorial.

- Async, non-blocking model loading (`setEntityMeshAsync`)
- Blender-authored lights/camera/color management (`loadSceneAuthored`)
- Vision Pro spatial picking and two-hand scene rotation

```bash
open ArchvizViewer/ArchvizViewer.xcodeproj
```

### 🛋️ BedroomTwin — *visionOS*

![BedroomTwin demo](docs/media/BedroomTwin/demo.gif)

A digital twin of a bedroom: the same room model, but different parts of it behave differently. The window becomes a passthrough light portal; the lamps, door, curtains, and laptop stay individually tappable and carry live mock status data. Reference project for the [Bedroom Digital Twin](https://untoldengine.github.io/UntoldEngine/LearningPaths/BedroomDigitalTwin/) tutorial.

- `SceneChannel` splitting geometry into context / window / selectable objects by naming convention
- Light-portal + passthrough ghost rendering on the window channel
- Per-object tap selection resolved against mock digital-twin status data

```bash
open BedroomTwin/BedroomTwin.xcodeproj
```

### 🏙️ CityStreaming — *visionOS*

![CityStreaming demo](docs/media/CityStreaming/demo.gif)

A city too big to fit in GPU memory, streamed in tile by tile as you walk through it — nearby tiles load at full detail, distant ones fall back to LOD/HLOD, and static batching updates incrementally in the background. Reference project for [City Streaming On Vision Pro](https://untoldengine.github.io/UntoldEngine/LearningPaths/CityStreamingOnVisionPro/).

- Tiled streaming manifests (`setEntityStreamScene`) instead of one monolithic model
- Distance-based load/unload with LOD/HLOD fallback
- Spatial debug overlays for tile bounds, octree residency, and texture streaming tiers

```bash
open CityStreaming/CityStreaming.xcodeproj
```

### 🛠️ SceneBuilder — *macOS / iOS*

<!-- MEDIA: docs/media/SceneBuilder/hero.gif -->
<!-- ![SceneBuilder demo](docs/media/SceneBuilder/hero.gif) -->

A declarative, SwiftUI-style syntax for building 3D scenes in code — cubes, PBR materials, and animated waves assembled without a scene editor.

```bash
open SceneBuilder/SceneBuilder.xcodeproj
```

---

## ⚙️ Requirements

- **Xcode 26.1** or later
- **macOS 26.01+** (for macOS demos)
- **iOS 26.01+** (for iOS demos)
- **visionOS 26.01+** (for Vision Pro demos)
- Metal-capable GPU
- A physical Apple Vision Pro for CoolSaber (simulator can't run the deferred renderer's G-buffer)

---

## 🚀 Getting Started

### 1. Clone the repo
```bash
git clone https://github.com/untoldengine/UntoldArcade.git
cd UntoldArcade
```

### 2. Open a demo project
Each demo is a standalone Xcode project. Navigate to the demo folder and open the `.xcodeproj` file — see the `open` command under each demo above.

> Most demos generate their Xcode project from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen). If you add/remove source files or change dependencies, re-run `xcodegen generate` inside that demo's folder before opening/building.

### 3. Build and run
- Select your target device (Mac, iPhone, iPad, or Vision Pro simulator)
- Press `⌘R` to build and run
- SPM will automatically fetch the Untold Engine dependency on first build

## 🔗 Engine Dependency

Each demo project depends on the Untold Engine via Swift Package Manager (SPM). The workspace is already configured to fetch the engine from its `develop` branch on GitHub.

## 📂 Project Structure

```bash
UntoldArcade/
├── CoolSaber/           # Rendering Extension — PSVR2 lightsaber duels + SharePlay
├── CoolWater/           # Rendering Extension — real-time animated water
├── CoolCloth/           # Rendering Extension — GPU cloth simulation (XPBD)
├── ArchvizViewer/       # visionOS — Blender archviz scene in mixed reality
├── BedroomTwin/         # visionOS — digital-twin bedroom with channel-based selection
├── CityStreaming/       # visionOS — tiled city streaming with LOD/HLOD
├── SceneBuilder/        # macOS/iOS — declarative scene-building demo
└── docs/media/          # Screenshots/GIFs/video referenced by this README
```

Each demo folder generally follows:
```bash
<Demo>/
├── project.yml               # XcodeGen config (where used)
├── README.md                 # Demo-specific overview + what it teaches
└── Sources/<Demo>/
    ├── <Demo>App.swift        # App entry point
    ├── GameScene.swift        # Scene setup, input, per-frame logic
    └── GameData/               # Bundled models, textures, HDRs, streamed tiles
```

## 🤝 Contributing

We welcome contributions! If you'd like to:
- Add a new demo game
- Improve existing demos
- Enhance documentation

Please fork the repo, open a PR, or join discussions in the [Untold Engine repo](https://github.com/untoldengine/UntoldEngine).

## 📜 License

This project follows the same license as Untold Engine. See the [LICENSE](LICENSE) file for details.

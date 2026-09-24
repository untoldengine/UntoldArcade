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

Each demo has its own README with run instructions and a guided path through the checked-in code. App demos are standalone Xcode projects; the Rendering Extensions (CoolSaber, CoolWater, CoolCloth, CoolWeb) are reusable Swift packages with example Xcode apps. Each extension ships its own shader library, pipelines, and render-graph passes and can be dropped into another project.

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

### 🕸️ CoolWeb — *visionOS · Rendering Extension*

![CoolWeb demo](docs/media/CoolWeb/demo.gif)

A Spider-Man web-shooter demo — strike the classic web-shooter pose (thumb, index and pinky extended, middle and ring curled) and a web line fires from your wrist, blooms into a net on the surface it hits, and stays tethered to your hand until you open your palm to release it. **Requires a physical Vision Pro** (hand tracking and scene reconstruction aren't available in the simulator).

```bash
open CoolWeb/Examples/CoolWebVisionOS/CoolWebVisionOS.xcodeproj
```

### 🏀 CoolBasket — *visionOS · Physics Backend*

<!-- MEDIA: docs/media/CoolBasket/demo.gif -->
<!-- ![CoolBasket demo](docs/media/CoolBasket/demo.gif) -->

Mixed-reality basketball, and the first consumer of the engine's physics backend plugin seam: a pure-Swift `PhysicsBackend` simulates the ball against your real floor, walls and furniture (ARKit plane detection), the hoop you place in your room, and your hands. Look at the floor and pinch to place the hoop, pinch near the ball to pick it up, flick to throw — a shot only counts when it comes down through the rim.

- `PhysicsBackendPlugin` installed before renderer creation, driven by the engine's `PhysicsCoordinator` — zero engine changes
- Rigid bodies, static colliders and trigger volumes expressed with the engine-owned `RigidBodyComponent`/`ColliderComponent`
- Contact and trigger events delivered through `PhysicsEvents`

```bash
open CoolBasket/Examples/CoolBasketVisionOS/CoolBasketVisionOS.xcodeproj
```

### 🎳 CoolBowling — *visionOS · Jolt Physics*

<!-- MEDIA: docs/media/CoolBowling/demo.gif -->
<!-- ![CoolBowling demo](docs/media/CoolBowling/demo.gif) -->

Mixed-reality bowling on the shared Jolt Physics plugin — the demo that needs a real rigid-body solver. Look at your floor to lay a lane, pinch to pick up the ball and roll it; ten pins (lathe meshes with convex-hull colliders) stack, wobble, topple and knock each other over, and the pins down are counted from their poses.

```bash
open CoolBowling/Examples/CoolBowlingVisionOS/CoolBowlingVisionOS.xcodeproj
```

### 🧲 UntoldJoltPhysics — *plugin · Physics Backend*

[Jolt Physics](https://github.com/jrouwe/JoltPhysics) behind the engine's physics backend seam, as a Swift package every demo can depend on: [untoldengine/UntoldJoltPhysics](https://github.com/untoldengine/UntoldJoltPhysics). Jolt comes as source from the [untoldengine/JoltPhysics](https://github.com/untoldengine/JoltPhysics) fork (the upstream tree plus a `Package.swift`) and SwiftPM compiles it — no binaries — for macOS, iOS and visionOS. CoolBasket can run on it instead of its built-in backend: pick "Jolt Physics" in its control window.

```swift
.package(url: "https://github.com/untoldengine/UntoldJoltPhysics.git", branch: "develop")
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

### 🫧 SplatTwin — *macOS*

![SplatTwin demo: the same view as meshes and after the swap](docs/media/SplatTwin/demo.png)

Mesh-to-Gaussian-splat twins: three objects cross-fade from their mesh to a splat "capture" as you walk up to them and back as you leave, while the mesh keeps writing depth as a shrunk occluder shell and keeps casting its shadow. The captures are synthesised at first launch, so nothing large ships. The swap policy is the demo's own code on the engine's public API, an example of extending the engine from outside; a HUD exposes the swap distance, fade, splat exposure and the occluder shells.

```bash
open SplatTwin/SplatTwin.xcodeproj
```

---

## ⚙️ Requirements

- **Xcode 26.1** or later
- **macOS 26.0+** for the current macOS demo targets
- **iOS 26.0+** for the current SceneBuilder iOS target
- **visionOS 2.0+** for most Vision Pro demos; CoolSaber targets visionOS 26.0 because it uses accessory tracking
- Metal-capable GPU
- A physical Apple Vision Pro for CoolSaber (simulator can't run the deferred renderer's G-buffer) and CoolWeb (simulator has no hand tracking or scene reconstruction)

---

## 🚀 Getting Started

### 1. Clone the repo
```bash
git clone https://github.com/untoldengine/UntoldArcade.git
cd UntoldArcade
```

### 2. Open a demo project
Navigate to the demo folder and open the `.xcodeproj` shown under that demo above. Rendering-extension demos keep their consumer app under `Examples/`; their top-level directory is also a Swift package that can be built and tested independently.

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
├── CoolWeb/             # Rendering Extension — Spider-Man web-shooter demo
├── CoolBasket/          # Physics Backend — mixed-reality basketball on the plugin seam, on either backend
├── CoolBowling/         # visionOS — bowling on the Jolt Physics plugin
├── ArchvizViewer/       # visionOS — Blender archviz scene in mixed reality
├── BedroomTwin/         # visionOS — digital-twin bedroom with channel-based selection
├── CityStreaming/       # visionOS — tiled city streaming with LOD/HLOD
├── SceneBuilder/        # macOS/iOS — declarative scene-building demo
├── SplatTwin/           # macOS — mesh-to-Gaussian-splat twins
└── docs/media/          # Screenshots/GIFs/video referenced by this README
```

App demo folders generally follow:
```bash
<Demo>/
├── project.yml               # XcodeGen config (where used)
├── README.md                 # Demo-specific overview + what it teaches
└── Sources/<Demo>/
    ├── <Demo>App.swift        # App entry point
    ├── GameScene.swift        # Scene setup, input, per-frame logic
    └── GameData/               # Bundled models, textures, HDRs, streamed tiles
```

Rendering-extension demos instead separate reusable package code from the consumer app:

```text
<Demo>/
├── Package.swift
├── README.md
├── Sources/<Demo>/             # Plugin, extension, simulation/state, shaders
├── Tests/<Demo>Tests/
└── Examples/<Demo>VisionOS/    # Runnable consumer Xcode project
```

## 🤝 Contributing

We welcome contributions! If you'd like to:
- Add a new demo game
- Improve existing demos
- Enhance documentation

Please fork the repo, open a PR, or join discussions in the [Untold Engine repo](https://github.com/untoldengine/UntoldEngine).

## 📜 License

This project follows the same license as Untold Engine. See the [LICENSE](LICENSE) file for details.

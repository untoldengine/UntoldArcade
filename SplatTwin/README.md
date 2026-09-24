# SplatTwin

A macOS demo built with [UntoldEngine](https://github.com/untoldengine/UntoldEngine): three
objects stand on a floor, each a mesh linked to a Gaussian-splat twin. Walk up to one and the mesh
cross-fades to its splat with no popping; walk away and it fades back. While the splat shows,
the mesh keeps writing depth as a shrunk occluder shell, so the splat is hidden behind the
object's far side but never by its own surface, and it keeps casting its shadow.

## 🚀 Quick Start

This is an Xcode project generated via [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`.

```bash
xcodegen generate
open SplatTwin.xcodeproj
```

Select the `SplatTwin` scheme and press `Cmd+R` (macOS 26.0+, a Metal GPU). `Cmd+U` runs both
test bundles, the swap policy's included.

Controls: `WASD` move, `Q`/`E` up and down, right-drag to orbit. The HUD lists each object's
state (mesh, loading, fading, splat), the swap distance and the fade length as live sliders,
and a switch for the occluder shells so you can see what they do: turn them off while an object
is swapped and its far side shows through.

## How it works

- The twins are synthesised at first launch: `SplatSynthesizer` scatters flat splats over each
  primitive's surface, bakes a fixed light into their colours the way a real capture does, and
  writes a `.untoldgs` payload to the caches folder. No downloads, no large assets.
- `GaussianTwinSystem` (the demo's own code, in `Sources/SplatTwin/GaussianTwins/`) loads a
  payload when the camera comes within the swap distance, runs the cross-fade through the
  engine's `MeshFadeComponent` and the splat's `opacityScale`, and switches the mesh's colour
  off behind its `MeshOccluderComponent` shell.
- To try a real capture, put `capture.untold` (the mesh) and `capture.untoldgs` (its cooked
  splat) into `Sources/SplatTwin/GameData/Twins/`; the demo adds it as a fourth object.

## Code walkthrough

Read the implementation in this order:

1. `SplatTwinApp.swift` — SwiftUI entry point, renderer ownership, callbacks, and HUD.
2. `GameScene.swift` — engine setup, camera/input, extension installation, and per-frame HUD updates.
3. `TwinShowcase.swift` — creates the floor and twins and exposes live options/readouts.
4. `GaussianTwins/GaussianTwinComponent.swift` — per-entity state and configuration.
5. `GaussianTwinStateMachine.swift` — the pure, testable transition rules.
6. `GaussianTwinSystem.swift` — camera-distance checks, asynchronous loading, and render presentation.
7. `SplatSynthesizer.swift` — generates the three built-in `.untoldgs` payloads.

### Startup and ownership

`SplatTwinApp` creates one `DemoHost`. The host creates `UntoldRenderer`, constructs `GameScene`, connects `update` and `handleInput` callbacks, and gives the renderer to `SceneView`.

`GameScene.init` configures rendering and keyboard input, creates the camera and sun, installs `GaussianTwinSystem` as an engine extension, and asks `TwinShowcase` to build the demo. The showcase creates normal mesh entities and links each one to a generated or bundled Gaussian payload with `setEntityGaussianTwin`.

### The swap state machine

Once installed, `GaussianTwinSystem` is updated by the engine. For each linked entity it measures camera distance and advances these states:

```text
armed
  → loading          camera enters swap distance; payload is not resident
  → crossFading      payload is resident and camera is still close
  → swapped          fade reaches 100%
  → reverting        camera leaves the distance plus hysteresis
  → armed            reverse fade finishes
```

If the camera reverses direction during a fade, the state machine preserves complementary progress so the image does not pop. If a resident payload disappears, the state returns immediately to `armed`, ensuring the ordinary mesh is visible.

### Turning state into presentation

`GaussianTwinSystem` maps the state-machine result onto engine mechanisms:

- `MeshFadeComponent` controls mesh color during the cross-fade.
- The splat's `opacityScale` supplies the complementary Gaussian opacity.
- `MeshOccluderComponent` keeps a shrunk, depth-writing shell after the mesh color disappears.
- The original mesh remains available to cast its shadow.

`GameScene.update` samples `TwinShowcase.readouts()` about ten times a second and sends them back to `DemoHost` on the main actor. SwiftUI publishes those state names, distances, progress values, and splat counts in the HUD. HUD sliders update showcase options, which are then applied to every twin.

```text
camera movement
  → GaussianTwinSystem distance check
  → pure state-machine step
  → optional async payload load
  → mesh fade + splat opacity + occluder shell
  → TwinReadout
  → SwiftUI HUD
```

### Follow the actual functions

The ownership chain starts in `DemoHost.init`:

```swift
guard let renderer = UntoldRenderer.create() else {
    self.renderer = nil
    return
}
self.renderer = renderer

let gameScene = GameScene()
renderer.setupCallbacks(
    gameUpdate: { deltaTime in
        gameScene.update(deltaTime: deltaTime)
    },
    handleInput: {
        gameScene.handleInput()
    }
)
```

`SceneView(renderer:)` displays that same renderer. The callbacks capture `gameScene`, while `DemoHost` retains the renderer and exposes only UI-facing settings/readouts.

In `GameScene.init`, installation happens before the showcase creates links:

```swift
GaussianTwinSystem.shared.install()
showcase.build(
    lightDirection: getDirectionalLightShaderDirection(entityId: sun)
)
setSceneReady(true)
```

`install` registers `GaussianTwinComponent` with the component registry and registers the system as an `EngineExtension`. That lets the engine call `GaussianTwinSystem.update` as part of its normal frame, even though `GameScene.update` does not call the twin system itself.

The pure decision logic lives in `gaussianTwinStep`. For example:

```swift
case .armed:
    guard wantsSwap, !loadFailed else {
        return GaussianTwinStep(state: .armed, progress: 0)
    }
    return GaussianTwinStep(
        state: payloadResident ? .crossFading : .loading,
        progress: 0
    )

case .crossFading:
    guard wantsSwap else {
        return GaussianTwinStep(
            state: .reverting,
            progress: 1 - progress
        )
    }
```

The state machine receives facts—distance decision, payload residency, load failure, time—and returns only the next state/progress. It does not touch an entity or renderer, which is why `GaussianTwinStateMachineTests` can exercise all transitions without Metal.

`GaussianTwinSystem.update` supplies those facts, begins asynchronous loading when entering `.loading`, and passes the result to `applyPresentation`. Follow that function to see the three visual outputs updated together: mesh fade, splat opacity, and occluder-shell presence. Keeping that mapping in one function prevents transient states such as an invisible mesh before its splat is resident.

The HUD is deliberately lower frequency. `GameScene.update` accumulates `deltaTime` and publishes `showcase.readouts()` every 0.1 seconds; rendering and swap decisions still run every engine frame. This avoids causing SwiftUI updates at the display refresh rate.

## 📁 Project Structure

```
SplatTwin/
├── project.yml
├── README.md
├── Sources/SplatTwin/
│   ├── SplatTwinApp.swift      # Window, renderer, HUD
│   ├── GameScene.swift         # Engine setup, camera, light, input
│   ├── TwinShowcase.swift      # The objects and their twins
│   ├── SplatSynthesizer.swift  # Splat covers for primitives, written as .untoldgs
│   ├── GaussianTwins/          # The swap policy: component, state machine, system
│   └── GameData/Twins/         # Optional real capture pair
├── Tests/SplatTwinTests/
│   └── SplatSynthesizerTests.swift
└── Tests/GaussianTwinTests/    # The policy on its own, without the app around it
    ├── GaussianTwinStateMachineTests.swift  # The swap's decisions, no scene needed
    ├── GaussianTwinSwapRenderTests.swift    # The whole swap against the engine (Metal GPU)
    └── Resources/test_gaussians.ply
```

## Dependencies

Only the engine's `develop` branch. The engine stays a renderer: it provides the mechanisms, a
mesh entity that carries a Gaussian splat beside its geometry, the depth-only occluder shell,
the mesh fade and the `gaussianAsset` link a `.untold` scene carries. The swap policy that
drives them (when a twin loads, from what distance it swaps, how fast it fades, how it comes
back) is this demo's own code in `Sources/SplatTwin/GaussianTwins/`, written against the
engine's public API only. That is the point of the demo: an app extends the engine from
outside, without the policy living in the engine; it also served as the test bed for the
engine's new Gaussian implementation.

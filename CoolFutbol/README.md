# CoolFutbol

A visionOS demo built with [Untold Engine](https://github.com/untoldengine/UntoldEngine) — a custom Metal-based game engine with native ARKit/CompositorServices support for Vision Pro.

This README isn't about the soccer game itself. It's a walkthrough of **how an Untold Engine XR app is put together**, using this project's own code as the example — from app launch, to engine initialization, to the two functions every frame runs through: `update()` and `handleInput()`.

## 🎯 Requirements

- visionOS 26.0 or later (required for spatial controller tracking)
- Xcode 26 or later
- A device or the Apple Vision Pro Simulator

## 🚀 Running It

```bash
xcodegen generate   # regenerates CoolFutbol.xcodeproj from project.yml
open CoolFutbol.xcodeproj
```

Build and run (`Cmd+R`) targeting the Vision Pro Simulator or a device. Press **Start Experience** in the window that opens.

> Re-run `xcodegen generate` any time you add new Swift files — the Xcode project is generated from `project.yml` and won't pick up new files on its own.

---

## 1. How an Untold Engine XR app boots

Every Untold Engine visionOS app follows the same bootstrap shape, found in `Sources/CoolFutbol/CoolFutbolApp.swift`:

```swift
ImmersiveSpace(id: "ImmersiveSpace") {
    CompositorLayer(configuration: UntoldEngineConfiguration(), renderer: { layerRenderer in
        let xr = UntoldEngineXR(layerRenderer: layerRenderer)
        xr.setImmersionMode(xrImmersionMode: .mixed)

        let gameScene = GameScene()

        xr.setupCallbacks(
            gameUpdate: { deltaTime in gameScene.update(deltaTime: deltaTime) },
            handleInput: { gameScene.handleInput() }
        )

        Thread {
            xr.start()
            xr.runLoop()   // blocking — runs on its own thread, not @MainActor
        }.start()
    })
}
```

Four things are happening here, in order:

1. **`UntoldEngineXR(layerRenderer:)`** creates the engine's XR runtime against the CompositorServices layer SwiftUI handed it.
2. **`setImmersionMode(.mixed)`** puts the app in passthrough AR (as opposed to a fully opaque VR space).
3. **Your game object is created** — in this project that's `GameScene()`, a plain Swift class that owns all of your game-specific state and logic. The engine doesn't require this exact name or shape; it only needs two callbacks.
4. **`setupCallbacks(gameUpdate:handleInput:)`** registers your `update(deltaTime:)` and `handleInput()` functions. From this point on, the engine calls them every frame on its dedicated render thread.

Everything below lives inside `GameScene.swift` and is what runs once that thread starts spinning.

## 2. Initialization — `GameScene.init()`

```swift
init() {
    logBundleInfo()
    setupAssetPaths()
    configureEngineSystems()

    loadUntoldScene(named: "futbol") { success in
        setSceneReady(success)
        // ...scene is now loaded; safe to look up entities by name
    }
}
```

- **`setupAssetPaths()`** tells the engine where to find your bundled `GameData/` folder (models, textures, animations, scene files).
- **`configureEngineSystems()`** (see below) turns on the engine subsystems you need before anything renders.
- **`loadUntoldScene(named:completion:)`** loads a `.untoldscene` file — the scene authored in the Untold Engine editor (lights, cameras, static meshes, and any entities you placed by hand, like `Ball` and `Stadium` and the players in this project). The completion handler fires once loading finishes; **do not touch scene entities before this fires** — `findEntity(name:)` and friends only work once the scene is actually loaded. `setSceneReady(_:)` flips a flag that `handleInput()`/`update()` check so they don't run early.

### `configureEngineSystems()`

```swift
private func configureEngineSystems() {
    let sun = createEntity()
    createDirLight(entityId: sun)
    setLight(entityId: sun, .intensity(0.4))
    setLight(entityId: sun, .directional(.active))

    gameMode = true
    AnimationSystem.shared.isEnabled = true
    InputSystem.shared.registerXREvents()
    InputSystem.shared.setXRSpatialPickingBackendPreference(.octreeGPUPreferred)
    InputSystem.shared.setXRTwoHandRotateAxisMode(.dynamicSnapped)
    setRendering(.maxShadowCastingDistance(2.0))
    setRendering(.antiAliasing(.msaa))
}
```

This is the project's one-time setup checklist, and it's a reasonable template for any Untold Engine XR app:

- **`createEntity()` + `createDirLight(entityId:)`** — entities are just integer IDs (`EntityID`); you create one, then attach engine-provided behavior to it (here, a directional light) and tune it with `setLight(entityId:_:)`.
- **`gameMode = true`** — tells the engine your game logic should run (as opposed to e.g. an editor/idle state).
- **`AnimationSystem.shared.isEnabled = true`** — turns on skeletal animation playback.
- **`InputSystem.shared.registerXREvents()`** — subscribes to spatial pinch/tap/gaze gesture events; required before `handleInput()` will see anything in `xrSpatialInputState`.
- **`InputSystem.shared.setXRSpatialPickingBackendPreference(...)`** / **`setXRTwoHandRotateAxisMode(...)`** — configuration knobs for how spatial picking and two-hand rotate gestures behave.
- **`setRendering(...)`** — rendering-wide settings (shadow distance, anti-aliasing). The engine exposes most tunables as `setRendering(.someCase(...))`/`setPostFX(...)` calls like this one.

## 3. The per-frame loop: `update()` and `handleInput()`

Once the render thread is running, the engine calls these two every frame, in this order: `handleInput()` first, then `update(deltaTime:)`.

### `handleInput()`

```swift
func handleInput() {
    if gameMode == false { return }
    if isSceneReady() == false { return }

    let state = InputSystem.shared.xrSpatialInputState
    // ...branch on your own game state and act on `state`
}
```

- **`InputSystem.shared.xrSpatialInputState`** is your snapshot of this frame's spatial input: pinch/tap activity (`spatialPinchActive`, `spatialTapActive`), two-hand rotate state, and a ray (`rayOriginWorld`/`rayDirectionWorld`) that's only valid **during an active pinch** — there's no continuous gaze ray.
- From there, this project calls engine helpers depending on what it's doing — e.g. `pickRealSurfacePosition(rayOrigin:rayDirection:filter:)` to raycast against ARKit-detected real-world planes (tables, floors) during placement, or `SpatialManipulationSystem.shared.processAnchoredSceneRotateLifecycle(from:sensitivity:)` to let the user rotate the scene with a two-hand pinch-twist gesture.
- For a game controller (PSVR2 Sense, or any `GCController`), the equivalent snapshot is `InputSystem.shared.gameControllerState` / `InputSystem.shared.keyState`, read the same way.

The pattern to take away: **`handleInput()` reads one input snapshot per frame and translates it into calls against engine systems or your own component data** — it doesn't poll devices directly.

### `update(deltaTime:)`

```swift
func update(deltaTime: Float) {
    if gameMode == false { return }
    // ...per-frame simulation logic
}
```

`deltaTime` is the elapsed seconds since the last frame — use it to make movement/timers frame-rate independent. This is where you'd drive any logic that isn't a direct response to input: timers, AI, physics-adjacent bookkeeping.

In this project, `update()` itself is mostly empty — the actual per-frame simulation work happens through **custom systems** registered with the engine (see below) rather than written inline here. Either approach is valid; registered systems just scale better once you have many independent behaviors.

## 4. Entities, Components, and Custom Systems

Once the scene has loaded, this project wires up gameplay with three engine concepts that show up constantly:

```swift
let ball = findEntity(name: "Ball")              // look up a scene-authored entity by name
registerComponent(entityId: ball, componentType: BallComponent.self)  // attach data to it

registerCustomSystem(ballSystemUpdate)            // register a per-frame system function
```

- **Entities** (`EntityID`) are the engine's lightweight identifiers. `findEntity(name:)` resolves one that was placed in the scene editor; `createEntity()` makes a new one in code.
- **Components** are plain data attached to an entity via `registerComponent(entityId:componentType:)`, and read back with `scene.get(component:for:)`. The engine ships some (e.g. kinetics via `setEntityKinetics(entityId:)`); your own are just classes conforming to `Component`.
- **Custom systems** are free functions with the signature `(deltaTime: Float) -> Void`, registered once via `registerCustomSystem(_:)`. The engine calls every registered system each frame, in registration order — which is why you'll see ordering comments in `startGameplay()` (e.g. a "match state" system must run before a "formation" system that reads its output). This is the scalable alternative to writing everything inline in `update()`.

That's the full loop: **App launch → `UntoldEngineXR` → your game object's `init()` configures systems and loads a scene → every frame, `handleInput()` translates spatial/controller input into action, `update()` (plus any registered custom systems) advances simulation state.** Everything else in this codebase — dribbling, shooting, formations — is just gameplay logic built on top of that same handful of primitives.

## 🔗 Untold Engine

- Engine repo: [github.com/untoldengine/UntoldEngine](https://github.com/untoldengine/UntoldEngine)
- API docs: `docs/API/` in the engine repo — see `UsingSpatialInput.md`, `UsingInputSystem.md`, and `GettingStarted.md` for more on the APIs introduced above.

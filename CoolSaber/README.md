# CoolSaber

A lightsaber-duel demo plugin for [Untold Engine](https://github.com/untoldengine/UntoldEngine) on Apple Vision Pro, driven by **PSVR2 Sense controllers** (visionOS 26 accessory tracking). Pull a controller's trigger to ignite a glowing blade from its tip; start a SharePlay session on a FaceTime call and duel a friend — blades clash with sparks, haptic kicks, and synthesized saber audio.

## Layout

- `Sources/CoolSaber` — render-extension plugin (`registerCoolSaberPlugin()`): one additive HDR pass drawing up to 4 blades (local left/right + remote left/right) and clash sparks, plus pure helpers (segment distance, ignition animator, clash detector) and the Codable SharePlay wire types.
- `Sources/CoolSaber/Shaders` — procedural blade/spark shaders (capsule SDF glow, no vertex buffers). Built into committed metallibs by `Scripts/build-metallib.sh`.
- `Examples/CoolSaberVisionOS` — the visionOS app: PSVR2 input → blades, SharePlay session (`GroupActivities`), CoreHaptics, `AVAudioEngine` synthesized hum/ignite/clash.

## Build

```sh
Scripts/build-metallib.sh       # regenerate metallibs after shader edits
swift test                      # host tests: plugin contract, ABI stride, math, wire codec
```

Open `Examples/CoolSaberVisionOS/CoolSaberVisionOS.xcodeproj` for the app (visionOS 26+).

## Controls

- **Trigger or Cross (A)** on a controller: ignite/retract that hand's blade. Bindings are attached per wand straight from GameController (the wand's trigger surfaces as a "Button A" alias on real firmware), so each saber always toggles independently.
- **Start Duel** button in the control window: begin the SharePlay activity (on a FaceTime call, or via the system share flow).

## Code walkthrough

Read the demo in this order:

1. `CoolSaberVisionOSXRApp.swift` — control window, plugin installation, immersive-space lifecycle.
2. `SaberXRGame.swift` — controllers, ignition, remote blades, clashes, and per-frame state publication.
3. `SaberSessionController.swift` and `SaberActivity.swift` — SharePlay session lifecycle.
4. `CoolSaberState.swift` and `CoolSaberRenderExtension.swift` — CPU-to-renderer state and drawing.
5. `SaberAudio.swift` and `SaberHaptics.swift` — feedback driven by game events.

### Startup

When the immersive space opens, the app installs `CoolSaberPlugin` before constructing `UntoldEngineXR`. This makes the blade/spark metallib and render pass available during renderer creation. The app creates `SaberXRGame`, starts controller/audio support, registers its callbacks, and runs the XR loop on a dedicated thread. Closing the space calls `shutdown` and releases the retained renderer state so it can be opened again.

The SwiftUI window separately starts a `SaberSessionController` observer. Starting a duel activates the `GroupActivity`; session messages are exchanged through the mailbox that `SaberXRGame` reads and writes from its frame loop.

### Local blade flow

Each frame, `SaberXRGame.update` reads the connected PSVR2 wands and their poses. A trigger edge changes that hand's ignition target. The ignition animator grows or retracts the visible blade over time, after which the game publishes the blade base, direction, length, color, and intensity with `setCoolSaberBlade`.

The render extension snapshots the published state in its render pass and procedurally draws each blade as an HDR glowing capsule. Sparks use the same extension rather than engine mesh entities.

### SharePlay and clashes

When a SharePlay session is active, the game sends compact local blade poses and consumes the latest remote participant state. Spatial participants share the group immersive-space origin; non-spatial participants are rebased to the fixed opponent anchor described below.

The clash detector compares active blade segments. A new contact produces a world-space contact point and intensity, which drives three outputs: spark state for the render extension, a haptic pulse, and synthesized clash audio. The event is also sent through SharePlay so the opponent receives matching feedback.

```text
PSVR2 pose + trigger
  → SaberXRGame ignition/blade state
  → local SharePlay message
  → local + remote blade segments
  → clash detector
  → render state + sparks + haptics + audio
  → CoolSaberRenderExtension
```

### Follow the actual functions

`SaberXRGame.update` is the table of contents for one frame:

```swift
func update(deltaTime: Float) {
    let dt = min(max(deltaTime, 0), 1.0 / 30.0)
    elapsed += dt

    updateLocalInput(dt: dt)
    updateLoadingSpinner(dt: dt)
    updateRemote(dt: dt)
    publishBlades()
    detectClashes(dt: dt)
    updateAudio()
    sendPoses(dt: dt)
}
```

Read these calls in exactly that order. Local and remote poses must be updated before blades are published; published lengths and positions must be current before clash detection; audio and outgoing network state use the result of the same frame.

Inside `updateLocalInput`, tracked controller orientation transforms two tuning vectors:

```swift
state.hilt = pose.position
    + pose.orientation.act(tuning.gripOffsetLocal(hand: hand))
state.direction = simd_normalize(
    pose.orientation.act(tuning.bladeAxisLocal(hand: hand))
)
state.ignition.update(
    deltaTime: dt,
    ignited: state.ignitedTarget
)
```

The grip offset moves from the controller tracking origin to the modeled hilt. The blade axis is also authored in controller-local space, so quaternion rotation turns it into a world-space direction. `ignitedTarget` is a boolean request; `CoolSaberIgnitionAnimator` turns it into smooth progress. Multiplying that eased progress by `fullLength` produces the current blade length.

`publishBlades` is the application/render-extension boundary. Each slot receives either a complete `CoolSaberBladeDesc` or `nil`:

```swift
setCoolSaberBlade(
    .localLeft,
    length > 0.01
        ? CoolSaberBladeDesc(
            hilt: state.hilt,
            direction: state.direction,
            length: length,
            radius: tuning.coreRadius,
            color: localColor,
            glowIntensity: tuning.glowIntensity
        )
        : nil
)
```

No render encoder is called here. The setter updates thread-safe package state; `CoolSaberRenderExtension` snapshots it later when the engine executes the extension's pass.

Finally, `detectClashes` converts every visible blade into a line segment and calls `CoolSaberMath.segmentSegmentClosest`. `CoolSaberClashDetector.update` adds thresholding/cooldown so adjacent frames do not create a new hit continuously. When it returns true, the same contact point feeds `spawnCoolSaberClashSpark`, `audio.playClash`, per-hand haptics, and the SharePlay event mailbox. That function is the best place to start when modifying clash behavior.

## Known limitation: visionOS simulator

The engine's deferred G-buffer needs 44 bytes of per-pixel tile storage; the visionOS **simulator** supports 32, so `UntoldEngineXR` aborts at pipeline creation (`InitModelPipeline`, "requires 44 bytes of pixel storage") before anything renders. This is an engine-wide issue (all revisions with the deferred path), not specific to CoolSaber — run on a real Vision Pro. The app still contains a simulator path (auto-entering immersive space with two self-swinging debug blades) that will light up once the engine gains a simulator-sized G-buffer.

## Requires hardware verification

- PSVR2 Sense pairing + per-hand trigger element names (the app logs controller state on connect).
- Haptics handedness on the two wands (falls back to pulsing both).
- SharePlay duel: two Vision Pros on a FaceTime call with spatial Personas; the shared group-immersive-space origin is the load-bearing assumption. When a participant is not spatial, remote blades are re-based to a fixed opponent anchor 2 m in front, facing you.

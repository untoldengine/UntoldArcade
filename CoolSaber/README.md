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

## Known limitation: visionOS simulator

The engine's deferred G-buffer needs 44 bytes of per-pixel tile storage; the visionOS **simulator** supports 32, so `UntoldEngineXR` aborts at pipeline creation (`InitModelPipeline`, "requires 44 bytes of pixel storage") before anything renders. This is an engine-wide issue (all revisions with the deferred path), not specific to CoolSaber — run on a real Vision Pro. The app still contains a simulator path (auto-entering immersive space with two self-swinging debug blades) that will light up once the engine gains a simulator-sized G-buffer.

## Requires hardware verification

- PSVR2 Sense pairing + per-hand trigger element names (the app logs controller state on connect).
- Haptics handedness on the two wands (falls back to pulsing both).
- SharePlay duel: two Vision Pros on a FaceTime call with spatial Personas; the shared group-immersive-space origin is the load-bearing assumption. When a participant is not spatial, remote blades are re-based to a fixed opponent anchor 2 m in front, facing you.

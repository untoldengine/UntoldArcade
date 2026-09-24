# CoolWeb

A Spider-Man web-shooter demo for [Untold Engine](https://github.com/untoldengine/UntoldEngine),
built as a Rendering Extension plugin. Strike the classic web-shooter pose on
Apple Vision Pro — thumb, index and pinky extended, middle and ring curled —
and a web line fires from your wrist, blooms into a small net near the
surface it hits, and stays tethered to your hand (a closed fist keeps
holding it). Open your palm to let it go.

## How it works

- **Gesture** — CoolWeb runs its own `ARKitSession` with `HandTrackingProvider`.
  A per-finger extension ratio (end-to-end distance over chain length) feeds a
  hysteresis classifier; the web fires on pose onset, aimed from the wrist
  through the knuckles.
- **Attach** — `SceneReconstructionProvider` meshes are kept twice: as
  `MTLBuffer`s for a depth-only occlusion pre-pass, and as CPU world-space
  triangles for the fire-time raycast (Möller–Trumbore), so webs stick to
  arbitrary room geometry, not just detected planes.
- **Strand** — a position-based rope (Verlet + sequential distance
  constraints). The tip flies kinematically toward the hit while rope pays out
  behind it, then pins to the surface with slight slack so the strand sags;
  the root follows the tracked wrist. Released strands dangle, then dissolve.
- **Rendering** — one alpha-blended draw at `.beforePostProcess`: every rope
  segment is a camera-facing ribbon (procedural from the vertex id, capsule SDF
  in the fragment) plus a surface-oriented impact splat that draws a procedural
  spoke-and-spiral web pattern.

## Code walkthrough

Read the implementation in this order:

1. `CoolWebVisionOSXRApp.swift` — installs the plugin, creates the XR renderer, and hosts diagnostics and controls.
2. `WebXRGame.swift` — the complete frame-level orchestration.
3. `CoolWebSpatialSession.swift` — ARKit hand, head, and reconstruction updates.
4. `CoolWebGesture.swift` and `CoolWebShooter.swift` — gesture events and web ownership.
5. `CoolWebNet.swift` — strand/net phases and position-based simulation.
6. `CoolWebState.swift` and `CoolWebRenderExtension.swift` — published draw state and render-graph encoding.

### Startup and shutdown

The immersive-space compositor installs `CoolWebPlugin` before it creates `UntoldEngineXR`. It then creates `WebXRGame`, loads the optional rigged glove assets, and starts `CoolWebSpatialSession`. Engine callbacks invoke `WebXRGame.update(deltaTime:)` on the XR render thread. When the space closes, the game stops ARKit, resets the shooter, and clears web and glove render state.

### One frame from hands to pixels

For each hand, `WebXRGame.update`:

1. Requests a predicted hand pose to reduce visible tracking lag.
2. Updates the rigged glove and its gaze-gated suit-up animation.
3. Builds collision spheres around the wrist, palm, and finger joints.
4. Computes the web-shooter muzzle at the inner wrist.
5. Sends the pose through that hand's hysteresis-based gesture classifier.
6. Calls `CoolWebShooter.fire` on pose onset or `release` when the palm opens.

`CoolWebShooter.fire` asks its surface query for an attachment. The query tries the CPU copy of the reconstruction mesh first and detected planes second. A hit creates a `CoolWebNet`; later frames update the hand root, step every live net, and publish segment and splat descriptions to `CoolWebSceneState`.

The render extension snapshots those descriptions, draws reconstruction meshes depth-only for occlusion, skins the glove, expands each strand segment into a camera-facing ribbon, and draws the procedural impact splat.

```text
ARKit hand/reconstruction updates
  → predicted hand pose
  → glove + gesture classifier
  → mesh/plane surface raycast
  → CoolWebShooter
  → CoolWebNet simulation
  → CoolWebSceneState
  → occlusion, glove, strand, and splat render passes
```

The control window's test-fire action enters the same shooter pipeline after gesture recognition, making it useful for separating gesture problems from raycast, simulation, or rendering problems.

### Follow the actual functions

`WebXRGame.init` injects a surface-query closure into `CoolWebShooter`:

```swift
shooter = CoolWebShooter { origin, direction, maxDistance in
    if let meshHit = raycastCoolWebSurface(
        origin: origin,
        direction: direction,
        maxDistance: maxDistance
    ) {
        return meshHit
    }
    if let planeHit = pickRealSurfacePosition(
        rayOrigin: origin,
        rayDirection: direction,
        maxDistance: maxDistance
    ) {
        return CoolWebSurfaceHit(
            position: planeHit.worldPosition,
            normal: planeHit.surfaceNormal,
            distance: planeHit.distance
        )
    }
    return nil
}
```

This dependency injection keeps `CoolWebShooter` independent of ARKit. It only knows how to ask for a hit; the visionOS app decides that reconstruction triangles have priority and engine plane picking is the fallback.

The central loop in `WebXRGame.update` operates once per hand. After acquiring a predicted pose, it computes a muzzle and supplies collision spheres to the shooter. Gesture output then becomes a small event switch:

```swift
switch classifiers[side]?.update(pose: pose) {
case let .webShooterFired(_, direction):
    shooter.fire(
        hand: side,
        origin: muzzle,
        direction: direction,
        now: now
    )
case .palmOpened:
    shooter.release(hand: side, now: now)
case nil:
    break
}
```

The classifier's hysteresis means `.webShooterFired` is emitted on pose onset, not every frame that the fingers remain in the pose. That prevents a held gesture from spawning a new net every update.

After both hands are processed, `shooter.step(now:dt:)` advances all live nets. In `CoolWebNet.update`, the phase determines whether the leader is still flying, attached, hanging after release, or dissolving. The position-based step integrates points, applies pins, solves distance constraints in alternating directions, resolves the hand collision spheres, and can tear overstretched links.

`CoolWebShooter.step` collects the surviving nets into flat render descriptions and calls `setCoolWebScene`. That setter is the boundary between simulation and rendering. `CoolWebRenderExtension.encodeScene` later snapshots the descriptions, uploads segment/splat buffers, and issues procedural draws. To change physical behavior, follow `CoolWebShooter → CoolWebNet`; to change appearance, follow `CoolWebState → CoolWebRenderExtension → CoolWeb.metal`.

## Building

```sh
swift build            # library (use /usr/bin/swift)
swift test             # host tests
Scripts/build-metallib.sh   # rebuild committed metallibs after shader edits
```

The example app is in `Examples/CoolWebVisionOS`. Hand tracking and scene
reconstruction require a real Vision Pro; the simulator provides neither.

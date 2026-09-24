# CoolCloth

A GPU cloth simulation demo for Untold Engine, packaged as a Rendering Extension
plugin (same architecture as CoolWater). A silk-like sheet hangs in the user's
real room on visionOS: pinch it to grab the particle under your gaze, throw the
ball through it, switch materials live, and let real furniture occlude it.

## Simulation

XPBD (extended position-based dynamics) with the *small steps* scheme:

- Many substeps per frame (default 8), **one** constraint iteration per substep.
  With a single iteration the Lagrange multipliers always start at zero, so no
  per-constraint λ storage is needed — Δλ = −C / (Σw + α/dt²).
- 12 distance constraints per particle, gathered Jacobi-style in a compute
  kernel: 4 structural, 4 shear, 4 bending, each family with its own
  **compliance** (inverse stiffness). Material presets (silk / cotton / denim /
  rubber) are just compliance triples — elasticity is physical, independent of
  iteration count and frame rate.
- Particle state lives in `RGBA32Float` textures (one texel per particle,
  128×128 grid): ping-pong positions (w = inverse mass, 0 = pinned), previous
  positions, velocities, and normals (w = stretch ratio).
- Kernel sequence per substep: `predict` (gravity, normal-dependent gusty wind,
  damping) → `solve` (XPBD constraints + floor/sphere collision + grab) →
  `finalize` (velocity update). Normals recompute once per frame.

## Rendering

Cloth vertices are fetched from the simulation textures by vertex id (no vertex
buffer). Double-sided fabric shading: wrap diffuse, view-dependent sheen (which
shifts per eye in stereo — very effective on Vision Pro), procedural weave, and
strain-driven brightening/darkening so wrinkles read. On visionOS the ARKit
scene-reconstruction mesh is rendered depth-only so real surfaces occlude the
cloth.

## Layout

- `Sources/CoolCloth/` — plugin, render extension, simulation state, picking
- `Sources/CoolCloth/Shaders/CoolCloth.metal` — kernels + render shaders
- `Scripts/build-metallib.sh` — rebuilds the per-platform metallibs after any
  shader change (commit the resulting `Resources/*.metallib`)
- `Examples/CoolClothVisionOS/` — mixed-reality demo app
- `Tests/CoolClothTests/` — state/ABI/picking unit tests (`swift test`)

## Public API (main entry points)

```swift
registerCoolClothPlugin()                    // once, before renderer creation
setCoolClothModelMatrix(_:)                  // place the sheet in the world
advanceCoolCloth(deltaTime:)                 // feed dt from the game update
resetCoolCloth(pinMode:)                     // .topEdge/.topCorners/.leftEdge/.topSpaced/.none
setCoolClothMaterial(.silk)                  // or explicit CoolClothMaterialParameters
setCoolClothWind(directionWorld:strength:gustiness:)
setCoolClothFloor(worldY:)
setCoolClothSphere(centerWorld:radius:)      // collider (+ demo ball)
pickCoolClothParticle(rayOriginWorld:rayDirectionWorld:maxDistanceToRay:)
grabCoolClothParticle(column:row:targetWorld:) / setCoolClothGrabTarget / releaseCoolClothGrab
```

## Demo interactions (visionOS example)

- Pinch while looking at the cloth: grab that particle and drag it.
- Pinch the ball: carry it; release with motion to throw it through the sheet.
- Pinch elsewhere: slide the whole sheet along the floor.
- Two-hand pinch: resize / rotate.
- Control window: material preset, hang mode, wind strength and gusts, reset.

## Run it

Open `Examples/CoolClothVisionOS/CoolClothVisionOS.xcodeproj`, select the visionOS scheme, and run it on Apple Vision Pro. The example depends on the local `CoolCloth` package. Run `swift test` from this directory for the package tests; rebuild the committed metallibs with `Scripts/build-metallib.sh` after changing Metal code.

## Code walkthrough

Read these files in order:

1. `CoolClothVisionOSXRApp.swift` — installs the plugin, creates the immersive renderer, and owns the control window.
2. `ClothXRGame.swift` — initializes the demo and translates XR input into cloth, ball, and placement operations.
3. `CoolClothSimulation.swift` — owns simulation configuration and GPU state.
4. `CoolClothRenderExtension.swift` — declares pipelines and builds the frame graph.
5. `Shaders/CoolCloth.metal` — implements the simulation kernels and fabric shaders.

### Startup

The compositor-layer closure calls `registerCoolClothPlugin()` before it creates `UntoldEngineXR`. Installation lets the engine validate the plugin manifest, load its metallib, register its pipelines, and include its render-graph passes when the renderer starts.

The app then creates `ClothXRGame`, calls `start()`, connects its frame callbacks, and starts the XR loop. `start()` selects the initial silk material, gravity, wind, ball visibility, and top-edge pinning. It also supplies the initial model, floor, and sphere state to the package API.

### Per-frame flow

`ClothXRGame.update(deltaTime:)` clamps large frame deltas and calls `advanceCoolCloth`. It then interprets the current XR input:

1. On pinch begin, it tests the ball first, then calls `pickCoolClothParticle` to find a cloth particle near the gaze ray; otherwise the gesture manipulates the whole sheet.
2. A cloth hit calls `grabCoolClothParticle`; subsequent frames move its target with `setCoolClothGrabTarget`.
3. Releasing ends the cloth grab or throws the ball using tracked motion.
4. One-hand movement positions the sheet, while two-hand input changes its scale and rotation.
5. The current model matrix, floor, and sphere collider are published for simulation/rendering.

The render extension consumes that state when it builds and executes the frame graph. For each simulation substep it encodes `predict → solve → finalize`, recomputes normals once per frame, draws real-world reconstruction depth for occlusion, and finally draws the cloth and demo ball.

```text
SwiftUI controls + XR input
  → ClothXRGame
  → CoolCloth public API/state
  → render-graph compute passes
  → simulation textures
  → normal generation
  → occlusion + fabric draw
```

The control window calls the same public API as the game. That is why changing material, wind, pin mode, or occlusion updates the running extension without rebuilding the renderer.

### Follow the actual functions

In `ClothXRGame.update`, simulation advancement happens before interpreting the current input:

```swift
let dt = min(deltaTime, 1.0 / 30.0)
advanceCoolCloth(deltaTime: dt)

let input = InputSystem.shared.xrSpatialInputState
let pinching = input.spatialPinchActive
let pinchBegan = pinching && !wasPinching
```

Clamping avoids a very large simulation step after a pause or dropped frame. `pinchBegan` is an edge, while `pinching` is a held state. On that edge the function chooses exactly one drag mode:

```swift
if rayHitsBall(...) {
    drag = .ball
} else if let pick = pickCoolClothParticle(...) {
    drag = .cloth
    grabCoolClothParticle(
        column: pick.column,
        row: pick.row,
        targetWorld: pick.worldPosition
    )
} else {
    drag = .sheet
}
```

This ordering gives the visible ball priority over cloth particles behind it. A cloth pick stores grid coordinates, because the simulation textures are a 128×128 particle grid. Later held frames only change the world-space target; the GPU solver pulls the selected neighborhood toward it. Releasing calls `releaseCoolClothGrab`, which clears the grab from the next consumed frame state.

Now move to `CoolClothRenderExtension.encodeSimulation`. This is where the public CPU API becomes GPU work:

```swift
let state = CoolClothSimulation.shared.consumeFrameState()
let frameDelta = min(max(state.deltaTime, 1.0 / 240.0), 1.0 / 30.0)
let substepDelta = frameDelta / Float(state.substeps)

for _ in 0 ..< state.substeps {
    encodePredict(context, textures: textures, params: params)
    for _ in 0 ..< state.iterations {
        encodeSolve(context, textures: textures, params: params)
    }
    encodeFinalize(context, textures: textures, params: params)
}
encodeNormals(context, textures: textures, params: params)
```

`consumeFrameState` gives the render thread one coherent snapshot of gravity, wind, material, grab, collider, reset generation, and accumulated delta time. Only eye zero runs simulation; otherwise stereo rendering would advance the cloth twice per displayed frame.

`makeParams` converts world-space interaction into the cloth's local simulation space. In particular, it multiplies the grab target by the inverse model matrix and converts the world grab radius into particle units. Follow `encodePredict`, `encodeSolve`, and `encodeFinalize` from here into the identically named Metal kernels to see where each field in `CoolClothSimParams` is used.

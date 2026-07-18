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

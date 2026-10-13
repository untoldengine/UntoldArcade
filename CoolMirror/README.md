# CoolMirror 🪞

A virtual mirror for Apple Vision Pro on Untold Engine: a rigged, high-poly
character stands in front of you and moves as you do, and shows off the
engine's character-deformation stack while it does.

Two devices watch you. An iPhone on a stand tracks your whole body with ARKit
and sends it over the local network. It sees you from the front, so it guesses
depth: standing still, it moves your head by 5 cm and your feet by 25. The
headset knows two things far better, where your head is and where your hands
are while its cameras have them. The mirror holds the character between what
is known: its head where the headset has yours, each planted foot where it
landed, and what the phone got wrong in between spread along the body like a
lean. The hands follow the headset while it sees them and the phone while it
does not, and the change never shows.

This README isn't just about the mirror itself. It's also a walkthrough of
**how a more involved Untold Engine XR app is put together** — one with a
second data source (the iPhone) feeding the character every frame, a
swappable deformation stack, and a physics plugin — using this project's own
code as the example.

## What's inside

| Piece | What it demonstrates |
|---|---|
| `CoolMirrorGame` | The character, its clips, the live skinning switch (vertex shader, compute linear blend, dual quaternion, Direct Delta Mush), morph sliders, pose drivers, the XPBD muscle simulation and the ML deformer trained on it. |
| `CoolMirrorMocapController` | Capture to character every rendered frame: the engine's external pose for the body, reach IK targets for both hands and both held feet, the headset's own orientation for the head. |
| `CoolMirrorMocap` (library, shared with the iPhone app) | The wire format and transport, and everything that makes the capture watchable, each piece pure and tested: `MocapPoseFilter` (medians, jump limits, a heading guard against the tracker's flips, one-euro smoothing), `MocapRetargeter` (bone directions from positions, relative to how you stood at calibration), `MocapFootAnchor` (the character stands on its planted foot), `MocapBodyAnchor` and `MocapHeadTrack` (held by the head and the planted feet), `MocapArmReach` (a hand placed on the body where yours is), `MocapHandLadder` (headset or phone, per hand). |
| `MocapRecording` | A session on file: the phone's frames, the headset's head and hands at every frame it rendered, and a marker per guided step. Recordings replay through the same code on a Mac. |
| `CoolMirrorJoltCape`, `CoolMirrorCapeColliders` | Batman's cape as a Jolt soft body on the cape's own mesh, coarsened for the solver, colliding with convex hulls fitted to the character's mesh. |
| `CoolMirrorHandSession` | Hand tracking in an ARKit session of the demo's own. |
| `Examples/CoolMirror/iOS` | The capture app: rear-camera body tracking, a preview stream so the headset can show what the phone sees. |

## Run it

You need a Vision Pro and an iPhone whose rear camera supports ARKit body
tracking, on the same Wi-Fi.

1. Open `Examples/CoolMirror/CoolMirror.xcodeproj`. Run `CoolMirrorCapture`
   on the iPhone and `CoolMirrorVisionOS` on the Vision Pro. The visionOS
   scheme runs the Release configuration: in Debug the cape and the capture
   filters are ten to thirty times slower.
2. Stand the phone sideways (body tracking is landscape only) with the back
   camera facing you, three to four metres away, so your whole body is in the
   picture, feet included.
3. In the headset, open the mirror, pick Spider-Man or Batman and turn on
   **Use iPhone body tracking**. The phone's screen faces away from you, so
   the headset walks you through the setup and shows the phone's picture.
4. Stand upright facing the phone, tap **Calibrate** and hold still for the
   countdown. The character now mirrors you.

The panel's toggles compare each stage with what it replaces: **Mirror**,
**Flip**, **Move** (root motion), **Ground** (stand on the planted foot),
**Reach** (hands by reach IK), **Head** (held by the headset's head and the
planted feet), **Hands** (the headset's hands). Allow hand tracking when
asked, or the hands stay the phone's.

## How this app is built

### 1. Boot: two engine subsystems before the renderer exists

Most Untold Engine XR apps only need `UntoldEngineXR(layerRenderer:)`. This one
needs two more things set up *before* that call, in
`Examples/CoolMirror/visionOS/CoolMirrorVisionOSXRApp.swift`:

```swift
CoolMirrorGame.registerRenderPlugins()          // the cape's cloth plugin
let joltBackend = registerJoltPhysics(settings: joltSettings)

guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
xr.setImmersionMode(xrImmersionMode: .mixed)

let game = CoolMirrorGame()
game.setJoltBackend(joltBackend)
game.start()
xr.setupCallbacks(
    gameUpdate: { dt in game.update(deltaTime: dt) },
    handleInput: { game.handleInput() }
)
```

- **`registerRenderPlugins()`** installs a custom render plugin (here, the
  cape's cloth pass) into the pipeline — a hook most demos never touch,
  needed only when a feature adds its own GPU pass.
- **`registerJoltPhysics(settings:)`** stands up the shared Jolt Physics
  plugin (also used by CoolBasket, CoolBowling) and hands back a
  `JoltPhysicsBackend` that `CoolMirrorGame` threads down to whatever needs
  rigid bodies or cloth — here, Batman's cape (`CoolMirrorJoltCape`).
- Both calls happen **before** `UntoldEngineXR(layerRenderer:)` — plugins and
  physics backends have to exist before the renderer that will call into them
  does.

Two more providers get wired after `start()`, both closures the engine calls
every render-thread frame rather than values read once:

```swift
game.setMocapHeadPoseProvider { [weak xr] in xr?.currentDevicePose }
game.setMocapHandProvider { [weak hands] in hands?.hands ?? [:] }
```

The headset already knows where the wearer's head and hands are, every frame,
more precisely than a phone watching from across the room ever could — so
rather than re-deriving them, the mocap controller just asks for them.

### 2. Initialization — `CoolMirrorGame.start()`

```swift
public func start() {
    registerXREvents()
    setSceneReady(true)
    setCharacter(character)
}
```

Smaller than most demos' `init()` because there's no `.untoldscene` to load —
no authored lights, cameras, or placed entities. `setCharacter(_:)` is doing
the work a scene file usually would: it creates one entity, loads a mesh
*asynchronously*, and only touches that entity again inside the completion
handler:

```swift
let entity = createEntity()
setEntityMeshAsync(entityId: entity, filename: newCharacter.rawValue, withExtension: "untold") { [weak self] _ in
    guard let self, self.generation == expectedGeneration, let characterId = self.characterId else { return }
    // ...translateTo, rotateTo, scaleTo, setEntityMuscleRig, applyClip(), applySkinningPath()...
}
```

The `generation` counter guards against the completion firing after the user
has already switched characters again (or the scene is tearing down) — the
same hazard `loadUntoldScene(named:completion:)` guards against with its own
"is the scene still ready" check, just handled by hand here since there's no
scene-load API doing it for a single async mesh load.

### 3. The per-frame loop: thin on the surface, busy underneath

```swift
public nonisolated func update(deltaTime: Float) {
    mocap.update()
    cape.update(deltaTime: deltaTime)
    joltCape.update(deltaTime: deltaTime)
}

public nonisolated func handleInput() {}
```

`handleInput()` is empty — this app has no spatial-pinch or controller input
to translate (the SwiftUI control window's `@Observable` bindings call
straight into `CoolMirrorGame`'s setters instead, off the render thread).
`update()` doesn't do simulation itself either; it just fans out to three
collaborators that do, each driven by the same `deltaTime`/render tick. This
is the demo's version of CoolFutbol's registered custom systems — same idea
(independent per-frame updaters), done as plain delegate calls because there
are only three of them.

### 4. Driving a skinned character without a scene file: `setEntityExternalPose`

Every frame, `CoolMirrorMocapController.update()` turns the iPhone's latest
tracked frame into **per-joint world-space rotation deltas** and a root
translation, then hands them to the engine in one call:

```swift
setEntityExternalPose(
    entityId: characterId,
    worldRotationDeltas: result.worldRotationDeltas,
    rootJoint: result.rootJoint,
    rootTranslationDelta: result.rootTranslationDelta,
    weight: retargeter.options.weight
)
```

This is the engine's hook for driving a skeleton from *outside* its own
animation clips — the clip underneath keeps playing (frozen, once mocap is
enabled) and these deltas layer on top, per joint, blended by `weight`. Hands
and feet go through a second engine API, `setReachIKChainTargets`, because a
hand or foot needs to *reach a position* (a spot on the body, a point on the
floor), not just copy a captured rotation:

```swift
setReachIKChainWeights(entityId: characterId, weights: weights)
setReachIKChainTargets(
    entityId: characterId, targets: targets, weight: options.weight,
    halflife: Self.reachHalflife, reach: Self.reachExtent, targetHalflife: Self.reachTargetHalflife
)
```

`setReachIKChains(entityId:chains:)` (called once, lazily, the first time
a character is driven) tells the engine which three-joint chains
(shoulder→elbow→hand, hip→knee→ankle) it's allowed to solve; after that,
`setReachIKChainTargets` just moves the end effector each frame. Everything
upstream of these two calls — `MocapRetargeter`, `MocapBodyAnchor`,
`MocapFootAnchor`, `MocapArmReach`, `MocapHandLadder` in
`Sources/CoolMirrorMocap/` — is this demo's own code, pure data transforms
with no engine dependency; they exist to produce the deltas and targets these
two API calls need, and are unit-tested in isolation for exactly that reason.

### 5. The deformation stack: swapping engine systems live

The control window's skinning/muscle/morph pickers all resolve to the same
small set of calls on `CoolMirrorGame`:

```swift
setEntityDeformation(entityId: characterId, skinningMode: .lbs)   // or .dqs, .ddm
removeEntityDeformation(entityId: characterId)                    // back to vertex-shader skinning
setEntityMuscleRig(entityId: characterId, rig: CoolMirrorMuscles.rig(for: newCharacter))
setEntityMuscleSimulation(entityId: characterId, enabled: muscleMode == .simulation)
setEntityMLDeformer(entityId: characterId, enabled: muscleMode == .mlDeformer)
setEntityPoseDrivers(entityId: characterId, enabled: enabled)
setEntityMorphTargetWeight(entityId: characterId, name: name, weight: weight)
```

The pattern to take away: skinning mode, muscle simulation, the ML deformer,
pose drivers and morph targets are all **independent engine systems toggled
per entity**, not a single monolithic "character state." `applySkinningPath()`
and `applyMuscles()` in `CoolMirrorGame` exist only to re-apply the demo's own
settings (which muscles are disabled, manual activations, flex) each time one
of those systems is swapped out from under it — the engine itself treats each
call as independent.

That's the shape of it: **boot registers plugins and a physics backend
before the renderer exists → `start()` creates one entity and loads its mesh
asynchronously → every frame, three collaborators (`mocap`, `cape`,
`joltCape`) each turn their own inputs into calls against
`setEntityExternalPose`/`setReachIKChainTargets`/`setEntityDeformation` and
friends.** Everything else — the ARKit retargeting math, the recording
format, the cape's cloth setup — is this codebase's own code built on top of
that same handful of engine entry points.

## Recordings

**Record** runs a guided session of a minute (stand still, lift a foot, raise
the arms, step, turn, hands in view and out of it) and saves a `.cmr` file to
the app's Documents folder. `Tests/CoolMirrorTests/Recordings` holds four of
them, and `MocapReplayTests` replays them through the filters, the anchors
and the hand handover: what jumped on the headset once must stay steady
there.

```bash
swift test   # the capture pipeline on synthetic data and on the recorded sessions, the cape's cloth and colliders
```

## Characters

`Scripts/prep_character.py` prepares a rigged FBX in Blender (transforms,
textures, biceps shape keys), `author_flex.py` writes the flex clip, and the
engine's exporter cooks the `.untold`. `swift run CoolMirrorBake` bakes the
muscle simulation into training data for the ML deformer.

## Credits

The two characters are community models from Sketchfab, used under the
[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/)
licence their authors published them with:

- **Spider-Man**: ["Spider-Man (2017; Homecoming - Tech Suit)"](https://sketchfab.com/3d-models/spider-man-2017-homecoming-tech-suit-6f58018044e147c08b8c2d7f552f46d1) by Mr. P (mrpgremlin).
- **Batman**: ["Batman Origins Suit - Textured and Rigged"](https://sketchfab.com/3d-models/batman-origins-suit-textured-and-rigged-ce83e407d259482c9ba284bced828933) by Light.k.

Changes made for the demo: transforms applied and textures relinked in
Blender, biceps shape keys and a flex clip added (`Scripts/`), cooked to
`.untold`, shown at a human height, and Batman's cape replaced by a simulated
one. Spider-Man and Batman are trademarks of their respective owners; the
models are fan works and this demo is not affiliated with or endorsed by them.

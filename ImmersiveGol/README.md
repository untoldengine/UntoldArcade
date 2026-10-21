# ImmersiveGol

A visionOS penalty-goalie demo built with [Untold Engine](https://github.com/untoldengine/UntoldEngine) and the [UntoldJoltPhysics](https://github.com/untoldengine/UntoldJoltPhysics) plugin.

This README isn't about the goalie game itself. It's a walkthrough of **how an Untold Engine XR app wires in a physics backend plugin, ARKit hand tracking, and animation-driven gameplay**, using this project's own code as the example.

## 🎯 Requirements

- visionOS 26.0 or later
- Xcode 26 or later
- A physical Apple Vision Pro for hand tracking (the simulator has no hand-tracking provider, so the goalie's palm colliders stay parked)

## 🚀 Running It

```bash
xcodegen generate   # regenerates ImmersiveGol.xcodeproj from project.yml
open ImmersiveGol.xcodeproj
```

Build and run (`Cmd+R`), press **Start Experience**, look at the real floor, then pinch and release to calibrate it. Once the stadium and shooter finish loading, press **Start Kicking**.

> Re-run `xcodegen generate` any time you add new Swift files.

---

## 1. How an Untold Engine XR app boots with a physics plugin

The bootstrap shape is the same as any Untold Engine XR app (see CoolFutbol's README for the baseline), with one addition: **the physics backend has to exist before `UntoldEngineXR` is created.** Found in `Sources/ImmersiveGol/ImmersiveGolApp.swift`:

```swift
CompositorLayer(configuration: UntoldEngineConfiguration(), renderer: { layerRenderer in
    guard let physics = GameScene.installPhysics() else { return }
    if let xr = UntoldEngineXR(layerRenderer: layerRenderer) {
        xr.setImmersionMode(xrImmersionMode: .mixed)

        let gameScene = GameScene(physics: physics)
        xr.setupCallbacks(
            gameUpdate: { deltaTime in gameScene.update(deltaTime: deltaTime) },
            handleInput: { gameScene.handleInput() }
        )

        Thread {
            xr.start()
            xr.runLoop()          // blocking — dedicated thread, not @MainActor
            gameScene.shutdown()  // tear down after the render loop actually stops
        }.start()
    }
})
```

`GameScene.installPhysics()` is a static function, callable before any `GameScene` exists:

```swift
static func installPhysics() -> JoltPhysicsBackend? {
    var world = PhysicsWorldConfiguration()
    world.gravity = Self.gravity
    PhysicsCoordinator.shared.setWorldConfiguration(world)

    var settings = JoltWorldSettings()
    settings.continuousCollision = true
    settings.maxKinematicStep = 1.0   // lets a >1m hand reposition teleport instead of sweeping
    settings.maxKinematicSpeed = 6.0

    return registerJoltPhysics(settings: settings)
}
```

- **`PhysicsCoordinator.shared`** is the engine's physics-backend-agnostic seam — the same one CoolBasket's plugin backend installs into. World gravity is set there regardless of which backend ends up registered.
- **`registerJoltPhysics(settings:)`** (from `UntoldJoltPhysics`) installs Jolt as that backend and returns a `JoltPhysicsBackend` handle. **The backend choice locks on the first simulated substep**, so this must run before `UntoldEngineXR` starts ticking — and the returned handle is what `GameScene` holds on to for direct calls like `resetBody`/`bodyState`/`didRemoveBody` later (see §3).
- From here on, `RigidBodyComponent`/`ColliderComponent` and the engine's automatic physics stepping work exactly as in any other Untold Engine physics demo — the game code never calls Jolt directly except through that one `JoltPhysicsBackend` handle.

## 2. Initialization — `GameScene.init()`

```swift
@MainActor
init(physics: JoltPhysicsBackend) {
    self.physics = physics
    setupAssetPaths()
    configureEngineSystems()
    setupPalms()
    setupGloves()
    setupContactEvents()
    handTracking.start()
}
```

Notice there's no `loadUntoldScene` call here. `configureEngineSystems()` deliberately leaves the scene empty:

```swift
private func configureEngineSystems() {
    setRendering(.maxShadowCastingDistance(250.0))
    gameMode = true
    registerXREvents()
    setSceneReady(true)   // ready with an EMPTY scene, so floor-tap input works immediately
    AnimationSystem.shared.isEnabled = true
}
```

The stadium (`goaliegame.untoldscene`) only loads **after** the player taps a real-world floor in `handleInput()` (§4) — at that point the measured floor height is already known, so the stadium's physics plane can be placed at the right world Y the instant it loads. This is the same `loadUntoldScene(named:completion:)` / `findEntity(name:)` pattern CoolFutbol uses, just deferred behind a gate:

```swift
loadUntoldScene(named: "goaliegame") { success in
    let ball = success ? findEntity(name: "Ball") : nil
    let plane = success ? findEntity(name: "PlanePhysics") : nil
    let player = success ? findEntity(name: "Player") : nil
    // ...publish to the frame thread; setSceneReady(true) once consumed
}
```

## 3. Entities, Components, and a physics-backend handle

Scene-authored entities get physics bodies attached the usual Untold Engine way — `registerComponent(entityId:componentType:)` plus `scene.get(component:for:)` to tune them:

```swift
registerComponent(entityId: ballEntity, componentType: ColliderComponent.self)
registerComponent(entityId: ballEntity, componentType: RigidBodyComponent.self)
if let collider = scene.get(component: ColliderComponent.self, for: ballEntity) {
    collider.shape = .sphere(radius: Self.ballRadius)
    collider.friction = 0.5
    collider.restitution = 0.35
}
if let body = scene.get(component: RigidBodyComponent.self, for: ballEntity) {
    body.motionType = .dynamic
    body.mass = 0.43
}
```

The two tracked-palm colliders are created the same way but with `motionType = .kinematic` — the engine drives kinematic bodies from positions you set every frame (`translateTo`/`rotateTo`) rather than from forces.

Where this demo goes beyond CoolFutbol is calling the `JoltPhysicsBackend` handle directly for operations the component API doesn't expose:

```swift
physics.resetBody(entity: ballEntity, position: trajectory.origin, velocity: velocity)
physics.bodyState(for: ballEntity)          // read back position for pass/fail checks
physics.didRemoveBody(entity: entity)       // tell Jolt a destroyed entity's body is gone
```

`resetBody` is how the ball is teleported to the penalty spot and given its launch velocity in one call — gravity-compensated so the shot actually reaches the chosen target (see `PenaltyShot.swift`'s `launchVelocity`, which integrates the engine's fixed 60 Hz step against Jolt's default linear damping). `didRemoveBody` is called from `shutdown()` after `destroyEntity(entityId:)`, so a reopened immersive space doesn't leave stale bodies behind.

Physics **events**, not polling, are how the demo knows a palm touched the ball:

```swift
contactSubscription = PhysicsEvents.shared.onContact { [weak self] event in
    guard let self, event.phase == .began else { return }
    for (side, entity) in self.palmEntities {
        if (event.entityA == self.ballEntity && event.entityB == entity)
            || (event.entityB == self.ballEntity && event.entityA == entity) {
            // ...record which palm made first contact
        }
    }
}
```

## 4. `handleInput()` — one-shot floor calibration via `pickRealSurfacePosition`

```swift
func handleInput() {
    guard gameMode, floorY == nil else { return }   // only runs before the floor is set
    let state = getXRSpatialInputState()
    guard state.spatialTapActive else { return }
    guard let hit = pickRealSurfacePosition(
        rayOrigin: state.rayOriginWorld,
        rayDirection: state.rayDirectionWorld,
        filter: .floorOnly
    ) else {
        setShotStatus("No floor detected yet...")
        return
    }
    floorY = hit.worldPosition.y
    Task { @MainActor [weak self] in self?.loadGameScene() }
}
```

Same `getXRSpatialInputState()` / `pickRealSurfacePosition(rayOrigin:rayDirection:filter:)` pattern CoolFutbol uses for table placement, with `.floorOnly` as the ARKit plane-classification filter instead of `.tableOnly`. Once `floorY` is set, this whole code path is dead for the rest of the session — `handleInput()` only matters once, before the stadium exists.

## 5. ARKit hand tracking outside the engine's own input system

The engine's `InputSystem` covers spatial pinch/tap/controller input, but **continuous palm position/orientation** isn't part of that snapshot — so `GoalieHandTracking.swift` runs its own `ARKitSession` with a `HandTrackingProvider` and a `WorldTrackingProvider`, independent of the engine:

```swift
let hands = HandTrackingProvider()
let world = WorldTrackingProvider()
try await session.run([hands, world])
for await update in hands.anchorUpdates { /* publish lock-protected samples */ }
```

Every frame, `GameScene.updatePalms()` queries this tracker (50 ms forward-predicted, same scheme as CoolBasket) and feeds the result straight into the engine's transform API, the same way any other per-frame positioning works:

```swift
let pose = handTracking.palmPose(side, now: now)
translateTo(entityId: palmEntity, position: pose?.position ?? Self.parkedPosition)
if let pose { rotateTo(entityId: palmEntity, rotation: pose.rotation) }
```

An untracked hand parks its collider 100 m below the scene rather than leaving a stale pose active — `maxKinematicStep` (set in §1) turns that reposition into a teleport instead of a 100 m-per-frame sweep through the ball.

The visible gloves ride on the same per-frame pose, loaded asynchronously and fit with a scale/rotation/offset onto the tracked palm frame:

```swift
setEntityMeshAsync(entityId: gloveEntity, filename: url.path,
                   withExtension: "untold", blockRenderLoop: false) { success in /* ... */ }
```

`blockRenderLoop: false` keeps the stadium rendering while a glove's textures are still uploading.

## 6. Animation-driven gameplay: `changeAnimation`, root motion, and joint sampling

The shooter is the most engine-API-dense part of this demo. Four clips (`forwardstrike`, `offensiveidle`, `jobbackward`, `jogforward`) are bound with `setEntityAnimations(entityId:filename:withExtension:name:)`, and blending between them at runtime uses `changeAnimation(entityId:name:transitionHalflife:)`:

```swift
changeAnimation(entityId: shooterEntity, name: Self.strikeName, transitionHalflife: 0.05)
// ...later, after the kick finishes:
changeAnimation(entityId: shooterEntity, name: Self.idleName, transitionHalflife: 0.15)
```

Root motion is turned on so the kick's authored forward travel actually moves the entity, and playback is read back frame-by-frame rather than counted in renderer frames:

```swift
setRootMotionEnabled(entityId: shooterEntity, enabled: true)
restartAnimation(entityId: shooterEntity, name: Self.strikeName, repeats: false)
// every frame:
let time = getAnimationPlaybackTime(entityId: shooterEntity)
if time >= shooterContactTime { /* release the ball */ }
```

`shooterContactTime` itself comes from sampling the exported clip's data directly at load time — not a hardcoded guess:

```swift
let asset = try NativeFormatLoader().loadAssetSync(from: url)
let clip = asset.animationClips.first!
let contact = clip.channels.max(by: { $0.translations.count < $1.translations.count })!
    .translations[Self.strikeContactFrame - 1].time   // frame 13's authored timestamp
```

Before the kick, the demo also needs to know **where the foot will land** so it can position the shooter such that contact happens exactly at the ball. `sampleAnimationJointPosition(entityId:name:jointName:time:)` previews a joint's pose at an arbitrary time in a clip without playing it:

```swift
let foot = sampleAnimationJointPosition(entityId: shooterEntity, name: Self.strikeName,
                                        jointName: "RightToeBase", time: shooterContactTime)
```

Because root motion strips out the clip's initial translation/heading, the raw sampled joint and the displayed joint disagree by that initial offset — `PenaltyContactAlignment.predictedToe` (in `PenaltyShot.swift`) reconstructs the correction from the clip's first-frame `Hips` rotation, and any residual error is closed out by nudging the entity once contact is actually reached, read back with `getJointModelTransforms(entityId:)`.

That's the full extra surface this demo adds on top of the CoolFutbol baseline: **a physics backend installed before `UntoldEngineXR` exists, direct `JoltPhysicsBackend` calls for teleport/readback, `PhysicsEvents` for contact instead of polling, an ARKit session run independently of the engine for continuous hand pose, and the animation-sampling APIs (`getAnimationPlaybackTime`, `sampleAnimationJointPosition`, `getJointModelTransforms`) for frame-accurate, root-motion-aware contact timing.**

## 🔗 Untold Engine

- Engine repo: [github.com/untoldengine/UntoldEngine](https://github.com/untoldengine/UntoldEngine)
- Physics plugin: [github.com/untoldengine/UntoldJoltPhysics](https://github.com/untoldengine/UntoldJoltPhysics)
- API docs: `docs/API/` in the engine repo — see `UsingSpatialInput.md`, `UsingInputSystem.md`, and `GettingStarted.md`; CoolBasket's and CoolBowling's READMEs cover the physics-backend plugin seam in more depth.

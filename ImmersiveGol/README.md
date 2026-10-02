# ImmersiveGol

A visionOS penalty-goalie prototype built with Untold Engine and UntoldJoltPhysics.

## M1 — Physics setup

After creating the project, the first implementation step was to import the
**UntoldJoltPhysics plugin**:

1. Add UntoldJoltPhysics to `project.yml` and link its library product to the app.
   Use `develop` for both UntoldEngine and UntoldJoltPhysics to match the plugin's
   engine dependency, then regenerate the Xcode project with XcodeGen.
2. Add `import UntoldJoltPhysics` in `GameScene.swift` and implement the
   `GameScene.installPhysics()` startup hook using `registerJoltPhysics()`.
3. Call that hook from `ImmersiveGolApp.swift` **before creating UntoldEngineXR**,
   then pass the installed backend into GameScene. The physics registry locks
   its backend choice on the first simulated substep.
4. Create a static floor and a dynamic ball using the engine's
   `ColliderComponent` and `RigidBodyComponent`. The engine coordinator advances
   Jolt and writes simulated transforms back to the scene automatically.
5. Add the repeat control, drop-check diagnostics, and scene cleanup.

**Status:** the visionOS simulator build passed, and the user confirmed the
physics demo works at runtime.

Open `ImmersiveGol.xcodeproj` in Xcode and run the ImmersiveGol scheme on Apple
Vision Pro or a visionOS simulator. The deployment target is visionOS 26.
Select **Start Experience** in the control window.

A yellow placeholder ball appears 3 metres ahead at a centre height of 1.5 m.
It falls, bounces on the green floor, and rests with its centre approximately
0.11 m above the floor. The Xcode console prints `ImmersiveGol M1 PASS` after
observing a fall, a floor contact, and 0.5 seconds of rest. A check that does
not settle within 10 seconds prints diagnostic values. Use **Repeat Physics
Check** to drop the same ball again.

M1 establishes physics. Gloves, penalty launches, the shooter,
and the stadium follow in later milestones. The ball uses a primitive mesh.
The space uses passthrough while we validate the mechanics.

## M2 — Tracked palms

**Status:** the visionOS simulator build passed, and the user confirmed on the
headset that both markers follow their palms correctly.

`GoalieHandTracking.swift` runs an ARKit hand-tracking session and transforms the
wrist and knuckle joints into world coordinates. Their midpoint defines each
palm position. GameScene moves two kinematic sphere colliders to those positions,
using the same 50 ms pose prediction as CoolBasket. Debug spheres show their
coverage: **blue for left**, **orange for right**, each with a 0.07 m radius.

The app includes `NSHandsTrackingUsageDescription`. Allow hand tracking when
requested. On a real Vision Pro, raise both hands and verify each sphere follows
its palm. Hands continue updating after the M1 check finishes.

Use **Drop Ball Above Palm** to reset the ball 0.4 m above a tracked palm (right
preferred, left as fallback). Hold the palm beneath the ball; Jolt resolves the
contact and the console prints `ball blocked by left/right palm`. This control
ends the M1 floor-check diagnostics; **Repeat Physics Check** restores that check.

An untracked hand, missing required joint, paused provider, or expired streamed
pose parks its collider 100 m below the scene. Streamed fallback poses expire
after 150 ms. The console logs tracking acquisition and loss. Large parking and
reacquisition jumps teleport rather than impart velocity; nearby kinematic
motion is capped at 6 m/s by the M1 Jolt settings. Session shutdown cancels
tracking and removes both colliders.

Hand tracking requires a real headset. On an unsupported simulator, the palm
colliders remain parked and the M1 floor check still runs. Both palm markers have
been verified on the headset. Tracking loss/reacquisition, ball contacts, and
closing and reopening the immersive space remain checks to confirm separately.
Goalie gloves and catching come later.

## Integration

- `GameScene.swift` owns Jolt registration, scene construction, and the drop
  check. The engine advances physics automatically; do not call `step` again.
- `ImmersiveGolApp.swift` installs Jolt before constructing `UntoldEngineXR`.
  Scene cleanup runs after the render loop stops, allowing the space to reopen.
- `GoalieHandTracking.swift` publishes lock-protected palm snapshots from ARKit;
  physics transforms and ball resets are applied on the XR frame thread.
- Engine and Jolt dependencies both use `develop`, matching Jolt's manifest.
  Retain the workspace's generated `Package.resolved` for reproducible revisions.
- `project.yml` is the XcodeGen source of truth. Regenerate from the parent
  directory with `xcodegen generate --spec ImmersiveGol/project.yml`.
- `DocumentationIssues.tmp.md` tracks documentation gaps across milestones.

## Build check

Run from this directory:

```sh
xcodebuild -project ImmersiveGol.xcodeproj -scheme ImmersiveGol -destination 'generic/platform=visionOS Simulator' -derivedDataPath /tmp/ImmersiveGol-M1-build CODE_SIGNING_ALLOWED=NO build
```

Compilation and the runtime drop check are separate validations. Observe the
ball and the console result in an immersive space to confirm runtime behavior.

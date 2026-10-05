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
Select **Start Experience** in the control window. Look at your real floor and
pinch and release to set the floor height. The ball stays hidden until a detected floor
is selected; shot and drop controls become available after placement. If no
floor is detected at the pinch location, scan the floor and pinch again.

The soccer ball model appears 3 metres ahead at a centre height of 1.5 m above
the selected floor.
It falls, bounces on the invisible floor collider, and rests with its centre approximately
0.11 m above the selected floor. The Xcode console prints `ImmersiveGol M1 PASS` after
observing a fall, a floor contact, and 0.5 seconds of rest. A check that does
not settle within 10 seconds prints diagnostic values. Use **Repeat Physics
Check** to drop the same ball again.

M1 establishes physics. Gloves, penalty launches, the shooter,
and the stadium follow in later milestones. The ball uses the supplied
`GameData/Models/ball/ball.untold` asset and its diffuse/normal textures.
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
colliders remain parked. The M1 floor check runs after floor placement. Both palm markers have
been verified on the headset. Tracking loss/reacquisition, ball contacts, and
closing and reopening the immersive space remain checks to confirm separately.
Goalie gloves and catching come later.

## M3 — First penalty

**Status:** the user confirmed the first penalty works on the headset. The
flatter flight (M3.b) was also confirmed on the headset. Random targeting
(M3.c) needs a headset check.

1. Start the experience. Choose **Distance** (2–10 m), **Maximum flight time**
   (0.2–0.5 seconds) in the control window. Each shot chooses its aim randomly.
   Defaults are 3 m and 0.35 seconds. Shorter flight times make faster shots.
   Close-range shots may shorten the requested time further to keep the flight
   directed toward the goalie; the launch status shows the actual time.
2. Face the direction from which the ball should arrive and press **Repeat Shot**.
   The current head position and horizontal heading establish the goalie frame.
   The ball waits at the penalty spot during a three-second countdown.
3. Raise your palms and react to the ball. A random target is chosen 0.55 m ahead
   of the goalie, within ±0.35 m sideways and ±0.2 m vertically of the chest-height
   center (0.35 m below head height, with a 0.6 m minimum target height).
   The target stays fixed for that shot, allowing either hand to block it.
   The aim picker and purple target marker have been removed.
4. The ball launches from floor height. Jolt handles its flight and palm impacts.
   The control window and console report which palm made contact. If the whole
   ball passes the captured goalie plane, feedback reports **Passed goalie**,
   including whether a palm touched it. Otherwise, after flight time plus three
   seconds, feedback reports a deflection or an end without palm contact.
5. Press **Repeat Shot** for another attempt using the current settings and goalie
   frame, with a fresh random target. Repeating during a countdown or flight replaces the previous attempt.

`PenaltyShot.swift` computes launch velocity with gravity, the engine's 60 Hz
fixed step, and Jolt 5.6's default linear damping of 0.05. This keeps the ball
aligned with the chosen target across the available settings. The flight limit keeps
the ball rising toward the target rather than lobbing above it, and short-range
shots favor horizontal launch velocity over vertical launch velocity. These integration
assumptions must be revisited if physics stepping or damping changes.

An independent host Jolt check exercised 54 trajectories (distance/flight-time
limits and defaults, the original three aims, and two headings), both palm identities, repeat
resets, and parked-hand misses. All passed. Real hand prediction and blocking
still need headset validation: try a left-palm block, a right-palm block, and an
unblocked shot, then change distance and repeat.

M3 feedback checks palm contact and passing the goalie plane. Goal-mouth bounds,
scoring, catching, the animated shooter, and stadium presentation come later.
**Repeat Physics Check** and **Drop Ball Above Palm** remain available and cancel
an active penalty. The simulator uses a fixed goalie pose if head tracking is
unavailable; its palm colliders remain parked.

### M3.c — Random targeting

Each attempt samples continuous lateral and height offsets, rather than selecting
among three lanes. Direction is selected before the countdown and never follows
the hands during flight. The target hint is hidden so blocking requires reacting
to the ball. Distance and maximum flight time remain configurable.

The visionOS simulator build passed. Verification covered 90 trajectories at the
random area's corners and center, both palm colliders, repeat resets, parked-hand
misses, and 1,000 random samples within the intended bounds. Headset validation
of random targeting remains pending.

### M3.d — Soccer ball model

The visible ball loads with `createEntity()` and
`setEntityMeshAsync(entityId:filename:withExtension:)` from
`GameData/Models/ball/ball.untold`. Its authored materials and adjacent textures
replace the yellow placeholder. The native model is approximately 1 m across,
so a uniform scale of 0.22 matches the existing 0.11 m sphere collider radius.

The async completion publishes a readiness flag. On the XR frame thread, the
finished model is sized and positioned before its dynamic physics body is
registered. This avoids the loader's imported root transform overwriting a
simulated pose. Mass, collider dimensions, random shots, and palm interactions
retain their existing settings. The visionOS simulator build passed, and the
model and both textures were verified in the app bundle. Headset validation of
the model appearance remains pending.

### M3.f — Ball and ghost plane

On startup, look at the floor, then pinch and release. Scene setup calls
`registerXREvents()` to enable event ingestion and restores `setSceneReady(true)`
when reopening the immersive scene. `handleInput()` consumes the
completed `spatialTapActive` signal and calls `pickRealSurfacePosition` with
`.floorOnly`, using the engine's `UsingSpatialInput.md` tap flow. This requires
ARKit to classify the selected surface as floor; scan the floor and retry while
classification is pending. The engine-provided `hit.worldPosition.y` positions
a horizontal mesh from `BasicPrimitives.createPlane(width:depth:)` directly at
the detected height, attached using `setEntityMeshDirect`. The physics collider
is a 0.1 m slab with local offset Y = -0.05, so its top meets that same height.
The scene root is reset to identity for consistent world/physics coordinates. Misses print
plane diagnostics and show a retry instruction. There is no assumed y = 0
fallback, including in the simulator.

The BasicPrimitives test plane is 1 m × 1 m and uses
`updateMaterialOpacity(entityId: floorEntity, opacity: 0)`. Shadow casting is
disabled. Its existing 32 m × 32 m static Jolt slab remains active for ball
collisions; mesh opacity does not affect physics. The initial drop, rest-height
check, and penalty origins use the measured floor height. The future stadium
will supply the visible grass.

**Place Floor Again** cancels the current shot and waits for a new floor tap.
Placement is retained for the current immersive session and repeated after
reopening. Palms keep tracking while placement is pending.

Headset validation confirmed the plane was at the correct floor height: the
large opaque surface covered real tables/chairs in passthrough, creating the
impression that it was elevated. The device log confirms floor hit/top
Y = -0.0000608 m and resting ball Y = 0.10993921 m. This was a visual occlusion
issue, not a floor-height or XR rendering error. The visionOS simulator build
passed, and the user confirmed the ball and transparent ghost-plane setup works
on the headset.

Headset check: select the floor, confirm the real furniture remains visible,
and verify the ball bounces/rests on the real floor and can be blocked by either
palm. Use **Place Floor Again** to repeat calibration.

## M3.g — Stadium scene

The demo now loads `GameData/Scenes/goaliegame.untoldscene` with
`loadUntoldScene(named: "goaliegame")`. Its completion finds the named **Ball**
and **PlanePhysics** entities with `findEntity(name:)`. Input is gated with
`setSceneReady` until loading succeeds and both names are found. A load failure
or missing name shows an error in the control window.

The scene supplies the stadium, ball mesh, physics plane, camera, and light.
The app creates only the palm proxies. Once loading finishes, the XR frame
thread configures the loaded entities: PlanePhysics becomes transparent with
no shadows, while Ball retains the existing 22 cm gameplay diameter and Jolt
sphere collider. Plane collider dimensions follow the authored procedural
plane's X/Z scale. Floor calibration changes its Y and preserves its authored
X/Z position. Random shots, repeat controls, and palm collisions remain in place.

Loaded scene entities are tracked for cleanup when the immersive experience
closes, including the stadium hierarchy. The visionOS simulator build passed;
the scene bundle and required names were verified. The current stadium export
has 16 model references and 13 texture references, all present in GameData.
The user confirmed the stadium scene and authorized the M3.g commit.

## M4 — Goalie gloves

The app creates separate left/right glove entities and loads `left-glove.untold`
and `right-glove.untold` asynchronously from `GameData/Models/gloves`. Glove
loading passes each full bundled file path: the engine's bare-name lookup
does not search the extra `gloves` folder. Startup logs identify the requested
path and whether each load completed successfully.
The stadium finishes loading and becomes scene-ready before glove loading starts.
Gloves then load left followed by right, using `blockRenderLoop: false` so their
load duration does not pause the stadium's rendering. Short ECS registration
sections still use the engine's mutation gate. Shutdown prevents starting a
queued glove load after the immersive space closes.
Glove loading does not add physics bodies: the existing 7 cm palm spheres remain the
kinematic colliders, and their colored markers have been removed.

Each frame queries one predicted palm pose per hand and uses it for both the
collider and glove. The palm position retains the wrist/knuckle midpoint used
in M2; rotation comes from the wrist-to-knuckle direction and across-palm axis,
with chirality accounted for. The 50 ms prediction and 150 ms streamed fallback
apply to the complete pose. Lost tracking hides the glove and parks the collider;
reacquisition restores both.
Incomplete joint poses on an otherwise tracked hand can use the last complete
streamed pose until its 150 ms expiry. Explicitly untracked anchors still park
the collider immediately.

Fit is applied after async loading on the XR frame thread: scale 0.25 gives an
approximately 25 cm cuff-to-fingertip length, a -90° Y rotation aligns the
exported palm-facing axis, and a model-space palm origin provides the attachment
offset. `gloveScale`, `gloveRotation`, and `glovePalmOrigin` in `GameScene` are
the initial fit settings for headset tuning. Shutdown removes glove entities.

The supplied `.untold` files and Blender source contain no skeleton or armature.
These gloves therefore follow palm position/rotation as solid meshes; finger
articulation requires a rigged export. The visionOS simulator build passed;
both models and their three shared textures were verified in the app bundle.
Headset validation remains pending:
check left/right fit, turn palms over, block with either hand, hide/reveal hands,
and close/reopen the immersive space.

Headset testing confirmed the stadium and glove loads complete with the revised
startup order. The immersive space now requests `.upperLimbVisibility(.hidden)`,
matching CoolWeb's glove mode, so system-composited real hands do not cover the
rendered gloves. Hand tracking continues to drive the glove poses and colliders.
This controls compositing; any remaining physical fit offset is tuned separately.

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

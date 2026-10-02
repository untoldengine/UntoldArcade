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

## M3 — First penalty

**Status:** the user confirmed the first penalty works on the headset. The
flight was subsequently adjusted to reduce its upward arc; this adjustment
needs a headset check.

1. Start the experience. Choose **Distance** (2–10 m), **Maximum flight time**
   (0.2–0.5 seconds), and **Left**, **Center**, or **Right** aim in the control window.
   Defaults are 3 m, 0.35 seconds, and Center. Shorter flight times make faster shots.
   Close-range shots may shorten the requested time further to keep the flight
   directed toward the goalie; the launch status shows the actual time.
2. Face the direction from which the ball should arrive and press **Repeat Shot**.
   The current head position and horizontal heading establish the goalie frame.
   The ball waits at the penalty spot during a three-second countdown.
3. Raise a palm to the purple target marker. It is 0.55 m ahead of the goalie,
   0.35 m below head height, with a 0.22 m lateral offset for left/right aims.
   The target stays fixed for that shot, allowing either hand to block it.
4. The ball launches from floor height. Jolt handles its flight and palm impacts.
   The control window and console report which palm made contact. If the whole
   ball passes the captured goalie plane, feedback reports **Passed goalie**,
   including whether a palm touched it. Otherwise, after flight time plus three
   seconds, feedback reports a deflection or an end without palm contact.
5. Press **Repeat Shot** for another attempt using the current settings and goalie
   frame. Repeating during a countdown or flight replaces the previous attempt.

`PenaltyShot.swift` computes launch velocity with gravity, the engine's 60 Hz
fixed step, and Jolt 5.6's default linear damping of 0.05. This keeps the ball
aligned with the marker across the available settings. The flight limit keeps
the ball rising toward the target rather than lobbing above it, and short-range
shots favor horizontal launch velocity over vertical launch velocity. These integration
assumptions must be revisited if physics stepping or damping changes.

An independent host Jolt check exercised 54 trajectories (distance/flight-time
limits and defaults, all aims, and two headings), both palm identities, repeat
resets, and parked-hand misses. All passed. Real hand prediction and blocking
still need headset validation: try a left-palm block, a right-palm block, and an
unblocked shot, then change distance and repeat.

M3 feedback checks palm contact and passing the goalie plane. Goal-mouth bounds,
scoring, catching, the animated shooter, and stadium presentation come later.
**Repeat Physics Check** and **Drop Ball Above Palm** remain available and cancel
an active penalty. The simulator uses a fixed goalie pose if head tracking is
unavailable; its palm colliders remain parked.

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

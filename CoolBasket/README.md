# CoolBasket 🏀

Mixed-reality basketball for Apple Vision Pro, built on Untold Engine — and
the first real consumer of the engine's **physics backend plugin seam**
(untoldengine/UntoldEngine discussion #1116, PRs #1123/#1129/#1139/#1140).

Look at the floor and pinch to put a hoop in your room. Pinch near a ball to
pick it up, flick to throw; your hands also dribble, swat and catch. Drop as
many balls as you like — every one can be grabbed, thrown and scored with. They
bounce off your **real floor, walls and furniture** (ARKit plane detection),
off the backboard, the rim and each other — put one down through the hoop to
score.

## What's inside

| Piece | What it demonstrates |
|---|---|
| `CoolBasketPhysicsBackend` | A complete pure-Swift `PhysicsBackend`: dynamic spheres vs. real-world planes, static box and sphere colliders, and kinematic hand bodies; restitution/friction/rolling; fixed-capacity contact & trigger buffers drained through the engine's `PhysicsEventSink`. |
| `CoolBasketPlugin` | `PhysicsBackendPlugin` manifest + `registerCoolBasketPhysics()` — installed before renderer creation, driven by the engine's `PhysicsCoordinator`, zero engine changes. |
| `CoolBasketScene` | Ball, hoop (pole + backboard as static boxes, the rim as a ring of static **sphere** colliders) and an invisible under-rim **trigger volume**, all expressed with the engine-owned `RigidBodyComponent`/`ColliderComponent` vocabulary. |
| `CoolBasketGame` | Gaze-driven hoop placement with a ghost preview. Any number of equal balls: grab the nearest via pinch, throw with the tracked hand velocity (grabbing removes the body, releasing re-adds it through the component seam), lost balls come back. Score via `PhysicsEvents.onTrigger`, counting only a downward pass through the rim. |
| `CoolBasketSpatialSession` | visionOS ARKit adapter: hand tracking (predicted poses), plane detection feeding the backend's world planes, and head tracking for placement. The real floor height is measured from the detected planes; the simulator falls back to a flat floor. |

The heavyweight backend (Jolt) lives in its own package; this demo
proves every seam the engine exposes — body lifecycle both ways, kinematic
writes, transform read-back, contact events, triggers — with the whole
simulation in a few hundred lines of Swift.

## Run it

Open `Examples/CoolBasketVisionOS/CoolBasketVisionOS.xcodeproj` and run the
`CoolBasketVisionOS-visionOS` scheme on a Vision Pro (or the simulator — no real
surfaces there, but the fallback floor keeps the ball in play). Press
**Step onto the Court**, grant hand-tracking and surroundings permissions,
place the hoop, and shoot.

The control window's **Physics** picker chooses the backend before the Court
opens: the demo's own pure-Swift backend, or the shared
[UntoldJoltPhysics](https://github.com/untoldengine/UntoldJoltPhysics) plugin (Jolt Physics). The
choice persists; the engine's registry locks on the first physics step, so
switching afterwards needs an app restart. `-physicsEngine jolt` selects it
from the command line.

The backend itself is platform-independent:

```bash
swift test   # 10 unit tests: bounce, rest, bounded planes, box rebound, trigger, the swat, the rim, a made basket
```

Automated simulator runs can skip the gaze-and-pinch steps with the launch
arguments `-autoOpenSpace` (opens the immersive space at launch),
`-autoPlaceHoop` (confirms the hoop placement after a short beat) and
`-autoDropBalls` (drops five balls in front of the hoop), and pick the backend
with `-physicsEngine jolt` or `-physicsEngine coolBasket`. Dropping balls is the
quickest way to see the backends apart: the built-in backend resolves no
ball-against-ball contact, so balls fall through each other; Jolt piles them.

## Code walkthrough

Read the demo in this order:

1. `Examples/CoolBasketVisionOS/.../CoolBasketVisionOSXRApp.swift` — UI, backend selection, immersive-space lifecycle, renderer creation.
2. `BasketXRGame.swift` — the small adapter between engine callbacks and `CoolBasketGame`.
3. `Sources/CoolBasket/CoolBasketGame.swift` — placement, hands, grabbing, throwing, scoring, and the frame loop.
4. `CoolBasketScene.swift` — engine entities and physics components for the court.
5. `CoolBasketPlugin.swift` and `CoolBasketPhysicsBackend.swift` — plugin installation and the built-in simulation.
6. `CoolBasketSpatialSession.swift` — ARKit hands, planes, and head pose.

### Startup order

The order in the immersive-space closure is part of the plugin contract:

1. Create `BasketXRGame`.
2. Read the selected physics engine and call `installPhysics(engine:)` **before** creating `UntoldEngineXR`. The registry accepts one backend for the process and locks after physics begins.
3. Create and retain `UntoldEngineXR`.
4. Call `CoolBasketGame.setupScene()` on the main actor to create hand proxies, lighting, and the translucent placement hoop.
5. Start ARKit tracking through `BasketXRGame.start()`.
6. Register `update` and `handleInput` as engine callbacks and start the XR run loop on its dedicated thread.

When the immersive layer is invalidated, the render thread calls `shutdown`, and the main actor releases the XR, game, and thread references so the court can be opened again cleanly.

### From placement to play

`CoolBasketGame` begins in `.placingHoop`. Each frame, the head pose supplies a gaze ray, detected planes supply the real floor, and the ghost follows a valid target. A fresh pinch or the control-window button sets a placement request. The game then removes the ghost, builds the hoop and trigger, creates the first ball, and switches to `.playing`.

During play, the frame loop:

- converts tracked hands into kinematic bodies so they can dribble and swat;
- detects a pinch near a ball and temporarily removes that ball's rigid-body components while it is held;
- estimates release velocity from recent hand samples, restores the components, and throws the ball;
- respawns lost balls and applies queued control-window actions;
- pushes updated ARKit planes into the active backend.

The engine's `PhysicsCoordinator` detects component changes, advances the selected backend, and writes dynamic transforms back to entities.

### How scoring works

The under-rim collider is a trigger, but a trigger alone would count upward and sideways motion. The game records each ball's previous center and accepts a score only when two facts agree: the ball crossed the rim plane downward inside the ring, and the under-rim trigger event arrived within the scoring window. The trigger subscription then increments the score and updates audio/UI state.

```text
ARKit hand/plane/head data
  → CoolBasketGame frame update
  → engine rigid-body/collider components
  → PhysicsCoordinator
  → selected physics backend
  → transforms + contact/trigger events
  → grab, bounce, score, audio, and control-window diagnostics
```

### Follow the actual functions

The app's compositor closure makes the ordering rule concrete:

```swift
let game = BasketXRGame()
guard game.game.installPhysics(engine: chosen) else { return }
guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }

game.game.setupScene()
game.start()
xr.setupCallbacks(
    gameUpdate: { dt in game.update(deltaTime: dt) },
    handleInput: { game.handleInput() }
)
```

`BasketXRGame` is intentionally thin. Its `update` drains button requests from `BasketXRHolder`, forwards them to `CoolBasketGame`, calls `game.update`, and copies score/ball/plane diagnostics back to the holder. Business logic belongs to the package rather than the SwiftUI target.

In `CoolBasketGame.update`, the phase is the top-level branch:

```swift
if currentPhase == .placingHoop {
    updatePlacement(now: now)
    return
}

updateHands(now: now)
trackRingCrossings(now: now)
recoverLostBalls()
```

While placing, `updatePlacement` intersects the head's forward vector with the floor. `distance = drop * horizontalLength / -forward.y` is the ray/plane intersection expressed using the head height (`drop`) and gaze direction. The result is clamped between 1.2 and 4.5 meters so the hoop stays usable. A fresh pinch changes `phase` to `.playing`, then schedules `buildCourt` on the main actor because entity construction is main-actor work.

During play, follow `updateHands → updateGrab`. It uses two thresholds:

```swift
if grabbingSide == side, let held = heldBall {
    if pose.pinchDistance > pinchReleaseDistance {
        releaseBall(at: pose.pinchPoint, now: now)
    } else {
        scene.moveBall(held, to: pose.pinchPoint)
    }
    return
}

guard grabbingSide == nil,
      pose.pinchDistance < pinchGrabDistance else { return }
```

The smaller distance starts a grab and the larger distance ends it. This hysteresis prevents noisy tracking near one threshold from rapidly grabbing and releasing. While held, recent pinch positions are retained for roughly 120 ms; `releaseBall` converts that short history into throw velocity.

Scoring is deliberately split between geometry and physics events. `trackRingCrossings` calls `crossedRimDownward`, which interpolates the exact point where the ball crossed the rim's Y plane and checks its horizontal radius. That arms the ball briefly in `throughRingAt`. The `PhysicsEvents.onTrigger` callback only increments the score if the armed ball subsequently enters the under-rim trigger. Read `crossedRimDownward` next if you want to understand or test the scoring rule without running ARKit or the renderer.

## Coming next

An XPBD net hanging from the rim, reusing the backend's low-restitution
"catch" planes and `nudgeBody` reaction channel.

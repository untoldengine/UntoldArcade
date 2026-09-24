# CoolBowling 🎳

Mixed-reality bowling for Apple Vision Pro on Untold Engine, running on the
shared [UntoldJoltPhysics](https://github.com/untoldengine/UntoldJoltPhysics) plugin — the demo
that needs a real rigid-body solver: ten pins that stack, wobble, topple and
knock each other over.

Look at your real floor where the foul line should be and pinch: an alley
runs away from you — a lane on a low plinth, bumpers, ten pins racked at the
far end, a pit behind them and a ball return along your right. Pinch the ball
off the rack and roll it. The pit swallows the ball and the return brings it
back; two balls a frame, the deadwood cleared in between, a fresh rack after
a strike or the second ball. Pins down are counted from their poses.

The alley is the game's, not the room's: a real surface that cuts into it (a
chair on the lane, a table over the return) is left out of the simulation
altogether, so the ball rolls through it. The floor, and every surface that
stays clear of the alley, remains solid.

## What's inside

| Piece | What it demonstrates |
|---|---|
| `CoolBowlingScene` | The alley — lane plinth, pit, bumpers, backstop and the sloped ball return (static boxes), ten pins (a lathe mesh built at runtime by `CoolBowlingPinMesh` and handed to the engine with `setEntityMeshDirect`, with a **convex-hull collider** from the same profile), the ball (dynamic sphere, 6 kg), the placement ghost and two kinematic hand bodies — all in the engine-owned `RigidBodyComponent`/`ColliderComponent` vocabulary. |
| `CoolBowlingGame` | Gaze-driven lane placement, pinch grab and roll with the tracked hand velocity, pins-down scoring from pin orientation and displacement, the pit → return → frame cycle (deadwood parked by dropping its body, re-rack by teleporting pins through the backend), lost-ball recovery, contact-driven sounds. |
| `CoolBowlingWorld` | ARKit planes as Jolt environment slabs, minus those intersecting the alley's keep-out box (a separating-axis test), plus the game's side channel (body state, teleports). |
| `CoolBowlingSpatialSession` | Hand tracking (predicted poses), plane detection (floor-classified planes preferred), head tracking. |
| `CoolBowlingAudio` | Synthesized thud, pin clack and strike fanfare in an AVAudioSourceNode mixer. |

The pin mesh is revolved from a profile at runtime (the engine's file
loaders only take cooked `.untold` assets); `Scripts/make_bowling_textures.swift`
paints the ball, pin and lane textures. Everything is deterministic, no assets
are hand-made.

## Run it

Open `Examples/CoolBowlingVisionOS/CoolBowlingVisionOS.xcodeproj` and run the
`CoolBowlingVisionOS-visionOS` scheme on a Vision Pro (or the simulator — no
real surfaces there, but a fallback floor keeps everything in play). Press
**Step onto the Lane**, grant hand-tracking and surroundings permissions,
place the lane, and roll.

Launch arguments for unattended simulator runs: `-autoOpenSpace` (opens the
immersive space), `-autoPlaceLane` (confirms placement after a short beat) and
`-autoRoll` (bowls four balls from the foul line, one per frame step) and
`-hideWindow` (with `-autoOpenSpace`: closes the control window once the
space has opened, so a screenshot sees the alley).

```bash
swift test   # alley geometry, pit and return, frame rule, keep-out filter, a rolled ball knocking pins over and ending in the pit on Jolt
```

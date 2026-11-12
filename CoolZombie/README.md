# CoolZombie

AI character locomotion demo for [Untold Engine](https://github.com/untoldengine/UntoldEngine) — **no animation state machine**.

A wandering target orbits the arena and the character chases it. Every frame the AI states a *goal* (desired velocity and facing, straight from steering); the engine's animation stack does the rest:

- **Motion matching** searches the loaded clips for the frame that best matches the current pose and predicted trajectory — nobody calls `changeAnimation`.
- **Inertialized transitions** smooth every clip jump.
- **Root motion** moves the entity: the clips' own travel is authoritative, so there is no foot sliding from mismatched speeds.
- **Foot IK** plants the feet on the ground.

Far from the target the character runs, closing in it walks, arrived it idles — all emergent from one `setMotionMatchingGoal` call per frame.

## Run

```bash
swift run CoolZombie
```

macOS 14+. The package pins the engine to the miolabs fork's `develop`
branch, and `Package.resolved` (the visionOS project keeps its own copy)
records the exact commit (upstream 0.24.1 merged into the fork, the
reach IK bend fix the elbows need and the per-frame simulation stepping
the headset needs, as of 27 October 2026). Moving on is
`swift package update UntoldEngine` plus the same revision in the Xcode
project's resolved file.

The Mac build is the sandbox: it runs the very same `ZombieChaseGame` as
the headset, with the orbiting red cube standing in for the player, so
whatever is tuned here holds on the device. A row of dropdowns along the
top (and the keys) control it, paused or running; reset and play/pause
sit bottom right. The zombie appears on the first running frame, not in
the paused start: the body stays hidden until an update has posed it and
set the ragdoll on that pose (a skinned mesh with no pose yet draws
stretched across the room, which is what the headset showed while the
clips loaded):

- **Layout** (or K): Open, Pillars, Wall, Room — boxes the zombie routes
  around (`ZombieNavigator`: a grid path with the obstacles inflated by
  the character's radius, string-pulled so the goal is the farthest
  waypoint in a clear line; root motion that carries the zombie into a
  box is pushed back out). The chase judges distance along the route, so
  a cube behind the wall is approached the long way round. **Room file**
  appears when the app was started with `-layoutFile <name|path>`: the
  bundled `sample` living room, or a room saved on the headset (see
  visionOS below) — the same walls and furniture the zombie met there,
  with the spawn point moved out to the headset's 4 m.
- **Cube** (or L): Orbit circles the arena; Behind wall parks the cube
  0.8 m past the wall, walling the zombie off. With the player within 3 m
  but the way round at least 1.4 times longer than the straight line, the
  chase enters its *contact* phase: it walks to the wall in front of the
  player, turns to
  face it and plants both hands on it (the `k_wall_hold` clip, the hold
  segment of the Kimodo hands-on-wall take, standing 0.22 m off the face
  so the palms meet it), and lets go the moment the player is reachable
  again or moves away. No IK yet: the pose is aligned to the wall plane,
  which is exact for a flat wall.
- **Height**: Low keeps the cube near the floor; Person lifts it to chest
  height, so the reach for it can be checked at both (`-height person`).
- **Clips** (or J): the clip set — every set present in the bundle is
  loaded at start and a switch rebuilds the motion database in place;
  `-clipSet <name>` only picks the initial one.
- **Reset**: back to the spawn point.
- Camera: WASD pans and dollies, Q/E move vertically, right-drag orbits
  the zombie, Shift+right-drag free-looks; Space plays and pauses.
- Test hooks: `-layout wall` starts on a layout, `-play` skips the paused
  start, `-debugLog` prints the phase, positions and distance every two
  seconds, so `swift run CoolZombie -layout wall -play -debugLog` shows in
  its console whether the zombie goes around the wall, and adding
  `-target behindWall` whether it ends up with its hands on it.

## Assets

The demo is written so assets swap without code changes: drop in new
`.untold` clips, list them in `ZombieResources.chaseClips`, and the motion
database rebuilds from whatever is loaded. The layout is:

```
Sources/CoolZombieKit/Resources/
  Models/Zombie/Zombie.untold                 the zombie: skeleton + one skinned mesh
  Models/Zombie/Textures/Zombie_BaseColor.png 4K atlas: face, body, clothes tiles
  Models/Zombie/Textures/Zombie_Roughness.png
  Models/Zombie/Textures/Zombie_Normal.png
  Animations/<clip>/<clip>.untold             one folder per clip
```

Texture paths inside a `.untold` resolve relative to the model file, so the
`Textures/` folder must sit next to it.

The model is the studio's own zombie (`Zombie_intact_blood_dirt.blend`,
the artist's review scene). `Tools/blender/prep_zombie.py` turns that file
into the game rig and cooks it: it keeps the final set (armature, skinned
body, the fused skinned clothing, eyes), scales it to 1.75 m, renames the
bones to the UE4-mannequin convention the clip pipeline and the ragdoll
expect (`root/pelvis/spine_01..03/neck_01/head`, `clavicle_l/upperarm_l/
lowerarm_l/hand_l`, `thigh_l/calf_l/foot_l/ball_l`, fingers) with the sides
taken from the bones' positions, merges the two neck bones, re-skins the
clothes with the body's weights (interpolated from the nearest skin face,
and with every hand and finger weight removed, so shirt and skin bend as
one and the rolled cuffs stay on the forearms instead of turning with the
wrist), drops from body and clothes every weight of a bone more than
25 cm away (the automatic weights left a little of the pelvis on the
wrists, which hang beside the hips in the bind pose, and with the arm
raised that little was a 15 cm fin on the cuff), bakes the shape keys that
give the face its zombie look, packs the
face, body and clothes texture sets into one 4K atlas, removes the skin
the clothes cover (a ray from each body face along its normal that meets
the clothes within 4 cm; a one-face ring stays under every edge of the
clothes, so a sleeve that lifts shows skin, not a hole — about a sixth of
the body's faces go, and with them what poked through the shirt) and joins
the three objects into one mesh of 44k vertices and 74k triangles with
one opaque material (the alpha-masked hair cards and the cornea shell are
dropped). One mesh, one material is not a choice of taste: the engine
binds the animation per skinned mesh node, and the exporter splits a
multi-material object into one node per material, so a split body would be
animated once per part. `Tests/CoolZombieKitTests/ZombieModelTests.swift`
holds the cooked model to this. The script writes the rig `.blend` the
retarget tools take as `BLEND` and exports through the Untold add-on:

```bash
SRC=~/Downloads/Zombie_intact_blood_dirt.blend OUT_BLEND=~/Projects/Untold/zombie_bd.blend \
/Applications/Blender.app/Contents/MacOS/Blender -b --python Tools/blender/prep_zombie.py
```

The artist's separate shirt and trousers (render meshes and their cloth
simulation proxies, which carry bone weights and per-panel groups) are left
out for now: they are for the cloth simulation, where the ragdoll's
capsules become the colliders. Until then the fused clothing mesh is what
the zombie wears.

## License

MPL-2.0, matching the engine. This demo is non-commercial. The zombie
model and its textures under `Models/Zombie` are the studio's own work and
ship with the demo.

## Animations

The demo ships with two interchangeable clip sets; pick one with the
launch argument `-clipSet style100` (default, committed) or `-clipSet pack`
(bring your own copy).

### 100STYLE Zombie (`-clipSet style100`, default)

The Zombie style of the [100STYLE dataset](https://www.ianxmason.com/100style/)
(Mason, Starke, Komura 2022, CC BY 4.0): one Xsens capture per locomotion
type — idle, forward/backward/sideways walks and runs, and a transitions
take — retargeted onto the mannequin rig and cooked with
`Tools/retarget_100style.py`. The script imports each BVH into Blender
headless, retargets it with a world-space delta retarget (rest poses
aligned by bone direction, so the rig's A-pose meets the Xsens T-pose;
the pelvis's direction is taken toward the second spine joint, because on
the studio's rig the first sits level with the hips and would pitch the
pelvis over), keeps every elbow in its anatomical plane (the Xsens zombie
idle holds both elbows 1.6 cm inside the shoulder-to-wrist line, a locked
hang that reads as a broken elbow at arm's length; an elbow more than 60°
from its natural pole, back and out when hanging, down and out when
raised, is moved around the shoulder-to-hand axis onto it, each bone by
the smallest swing that takes its old direction to its new one, never a
turn about its own axis, with the hand left where it was), puts the
low-passed hip path and heading into the
`root` bone (a static root for the idle), and exports through the Untold
add-on:

```bash
mkdir -p ~/Downloads/100STYLE/Zombie   # Zombie_*.bvh + Frame_Cuts.csv from the dataset page
CLIPS="ID:s100_idle,FW:s100_walk,FR:s100_run,BW:s100_walk_back,BR:s100_run_back,SW:s100_side_walk,SR:s100_side_run,TR1:s100_transitions" \
OUT=/tmp/s100 /Applications/Blender.app/Contents/MacOS/Blender -b --python Tools/retarget_100style.py
```

then copy each `<clip>/<clip>.untold` under `Sources/CoolZombieKit/Resources/Animations/`.
The cooked files (54 MB) are committed — CC BY 4.0 allows it; the demo
credits *100STYLE dataset, Mason, Starke & Komura* — so a fresh clone runs
without any pack. Pass `BLEND=<the prepped rig .blend>` to cook them for
another rig.

### Kimodo (`-clipSet kimodo`) and Mixed (`-clipSet mixed`)

Clips generated with [NVIDIA Kimodo](https://github.com/nv-tlabs/kimodo)
(`nvidia/Kimodo-SOMA-RP-v1.1`, weights licensed by NVIDIA Corporation under
the NVIDIA Open Model License) on a rented GPU from text prompts and
root-path constraints. `kimodo` is a complete set in one zombie style: an
idle and two hold idles, a shamble-to-sprint ladder (0.4 to 3.5 m/s),
backward and side walks, 45°/90°/180° turns at walking and running pace,
walking and standing pivots, start/stop transitions, plus the hands-on-a-wall
contact clip (`Tools/runpod/clips_core.json` and `clips.json`). `mixed` is
the 100STYLE set with only the Kimodo gap clips added, the first combination
tried. `Tools/runpod/README.md` documents the pod, `gen_clips.py` and the
triage; `Tools/retarget_kimodo.py` retargets the SOMA BVH output onto the
rig the same way as the 100STYLE tool:

```bash
python3 Tools/runpod/triage_clips.py ~/Downloads/kimodo_out/kimodo --prefer p0 --json picks.json   # one take per clip, one prompt style
Tools/runpod/retarget_batch.sh picks.json /tmp/kimodo_cook          # retarget + cook (cook_options.json adds trims/idle flags)
```

then copy each `<clip>/<clip>.untold` under `Sources/CoolZombieKit/Resources/Animations/`.

The arms no longer belong to the locomotion clips. A matcher jump is
chosen on feet, hips and path, so with the generated set every jump could
land on a take whose arms sat somewhere else — up, down, out — and the
upper body flapped between them. Now a pose layer (engine branch
`feature/mm_oneshot_clips`, `docs/API/UsingPoseLayers.md`) owns both arms
from the clavicles down, with a posture per chase state: the idles keep
their own arms, roaming hangs them (the idle's arms over any walk),
chasing puts the clawing hold's arms on them (the lift crossfaded over
0.4 s), and the wall hold keeps its own. Within 3 m of the player reach
IK bends the arms toward it — not a steady point but grabs: each hand
lunges at the cube and pulls back on a 1.1 s cycle, the two half a cycle
apart, whatever height the cube sits at. The arm postures are their own
Kimodo takes (`Tools/runpod/clips_arms.json`, picked by hand motion):
`k_arms_grab` reaches and grasps for the chase and the hold, `k_arms_high`
for the hyper chase — the model kept its arms forward rather than overhead,
so that tier is a small step up, not the frantic reach the prompt asked for. Hand positions also join the matching
features at a low weight, so what the clips still decide about the arms
stays close across a jump.

The feet stay where they are planted. The stance lock used to watch the
displayed foot and let go the moment a transition moved it — the one
moment a foot needs holding — so a jump's blend, the root-velocity
crossfade and the heading warp all slid the planted foot. It now locks on
the playing clip's own contact (`setFootIKStanceLocking(source:
.clipContact)`): a foot the clip holds still stays pinned whatever the
entity does, and lets go only when the clip lifts it, so the catch-up
hides in the swing. The search also weights foot position higher on the
Kimodo set (`SpeedProfile.footWeight`), so a jump lands where the feet
already are. In the headless harness the drift of a planted foot fell
from 12 to 4 cm/s, from 29-38 to 4-9 while moving.

Turning is the other place the sets differ. With no clip turning sharply
enough, the matcher's orientation warp rotates the entity under whatever
plays, which reads as the mesh turning on still feet. The pure Kimodo set
has 45°/90°/180° arcs and standing pivots, so its warp is cut to 0.3 rad/s
and only bites at walking speed (`SpeedProfile.warpRate`/`warpSpeed`):
the feet do the turning, at the price of a few degrees of heading lag. The
100STYLE set has no turn clips and keeps the full warp.

Generated takes are not cyclic: a walk's last frame sits 20-30 cm from its
first, and a start, stop or pivot cannot loop at all, so a loop wrap is a
hard cut. The chase therefore lists every locomotion clip as *one-shot* in
the motion-matching descriptor (`ZombieResources.oneShotClips`, engine
branch `feature/mm_oneshot_clips`): the database extrapolates their
trajectories past the end instead of wrapping and the matcher leaves them
through an inertialized jump before the end. The in-place idles, which play
on repeat outside the matcher while the zombie holds, are cooked with their
loop seam closed (`loop` in `cook_options.json`: half the last-to-first
mismatch eased out over each end). Peak pose acceleration in the headless
chase harness fell 3-5x and snap frames halved on the Kimodo and Mixed
sets; see `Tools/runpod/harness/README.md` for the harness and the
settings it chose (transition halflife 0.1 s, `minPlayTime` 0.3 s,
`maxTurnRate` 3 rad/s).

### MoCap Online Zombie Pro (`-clipSet pack`)

The zombie's animation clips are cooked from [MoCap Online's Zombie Pro
pack](https://mocaponline.com/products/ue4-zombie-pro), whose license does
not permit redistributing animation data — so this repository contains no
clips, only the code. To run the demo:

- own the pack, export the sequences as glTF, and cook them with the
  Untold Engine Blender add-on into
  `Sources/CoolZombieKit/Resources/Animations/<clip>/<clip>.untold`, or
- download a prebuilt demo binary from the Releases page, where the
  clips ship embedded in the compiled app as the license allows.

The pack's clips were cooked for the UE4 mannequin skeleton of the earlier
marketplace model; they play on the current rig only after a retarget onto
it, which the tools above do not cover yet.

## Physics

The room is a physics world on the
[UntoldJoltPhysics](https://github.com/untoldengine/UntoldJoltPhysics) plugin
(Jolt Physics as an engine backend). Every navigation box — the sandbox
layouts, a saved room, the walls and furniture ARKit detects — is a static
box in it, with a floor slab under everything, and the zombie is a
character controller (`ZombiePhysics`, over the plugin's `JoltCharacter`):
a cylinder 1.8 m tall and 0.2 m in radius standing on the entity's origin.
Each frame the controller is moved by whatever root motion did to the
entity, collides and slides that motion against the boxes — however long
the frame, so a stall never skips it over a wall — and the entity is put
where the controller ended up; the jumps the game means (spawn, reset)
are told to the controller as teleports. So a run cannot carry the zombie
through a wall, and the transition's root-velocity crossfade cannot slide
it into one once its hands are planted. That replaces the planner's
push-out (still there for a build without physics, and still the spawn
search's notion of a free point); the grid planner keeps routing around the
boxes and the chase keeps judging distance along the route. The controller
owns nothing vertical: the game pins the height to the floor it knows, so
the cylinder's flat base never climbs a low object, and a floor that moves
under the zombie moves the controller with it.

The radius is set by the wall hold: Jolt keeps the controller 2 cm off
every surface, so 0.2 m of radius stops the zombie exactly at the 0.22 m
stand-off the hold clip's hands reach. Props with rigid bodies bounce off
the controller (its inner body carries the zombie's entity, so contacts
and rays name it) and are pushed by it, but never shove it. The world is
installed before the first simulated frame — in the sandbox's setup, and
on the headset before the renderer exists — because the engine keeps the
first backend for the whole process; a reopened immersive space finds it
in place and only re-creates the controller. `-debugLog` prints
`physics=jolt` while the controller exists.

### Hits: ragdoll and reactions

Throw a ball at it: **H** or the ball button in the sandbox; in the
headset pick *Toss* or *Throw hard* in the control window, then pinch
anywhere in the room — the ball goes where you were looking when you
pinched, at the arm, leg or head your gaze crosses, or past the zombie if
you look beside it (the window's *Throw* button throws along your head
instead; `-throwBall <seconds>` and `-autoThrow <seconds>` throw one at
the chest every so often for scripted runs). The
ball is a rigid body in the same world, and so is the zombie's body: it
is a powered ragdoll all the time — the pelvis rides the animation, the
other nineteen parts are dynamic under gravity and held onto the
animation by 60 Hz joint motors (Jolt runs three sub-steps per engine
step for that; the hands then follow a run within a few centimetres; the
targets are aimed a frame ahead, except across a jump of the pelvis — a
floor snap, a respawn: over 20 cm in a frame, which no animation does —
when every part is re-seated on the new pose instead, since dynamic parts
cannot follow a teleport by force and would arrive bent, or pinned under a
floor slab raised above the feet) —
so the ball meets the actual arm, leg or head and bends it, and the
motors bring everything back (the character controller's own shape
ignores balls). What the mesh shows of the parts is a separate choice
(`Configuration.showsTrackedParts`, on): every part all the time, so
whatever the body meets bends what you see — a tracked part is off the
animation by its tracking error (hands 8-13 cm and head 7 cm in an idle,
from the joint limits; feet 2-4 cm) — or only a part a hit has (a
reaction, a stagger, the fall), the animation otherwise. Showing the
parts needs the simulation to step with every frame: both hosts set
`setEngine(.simulationStepping(.perFrame))`, because against the
engine's fixed 60 Hz step a headset drawing 100 frames a second showed
no new pose on two frames in five while the animation moved on — a
stutter of the whole upper body. When it strikes, the contact's
impulse decides what happens (only a ball counts — the fallen body's own
landings on the floor are not hits). A hard hit (2.5 N s, a 0.6 kg ball at about 4 m/s) knocks it down in
two beats. First the struck chain staggers: everything from the part
below the pelvis up — the whole upper body for a hit on the head or an
arm, one leg for a hit on a leg — goes physical under gravity, held by
soft motors that keep trying for the animation, and takes the hit
several times over, so the head snaps back and drags the torso and the
arms after it while the legs keep stepping. Half a second later the body
lets go: twenty capsules on the rig's bones
— pelvis, three spine links, neck, head, a clavicle and three more per
arm, three per leg, jointed by swing-twist constraints with a limp body's
ranges (a knee's cone centred mid-bend, so it folds backward and never
forward) — take the pose and motion the animation left the
body in plus a shove along the hit (a ball would not really floor
anyone; the body is set going the way it was struck), go dynamic with
next to no joint friction (so it collapses rather than freezing in the
shape it landed in), the character
controller steps aside, and from then on the mesh follows the parts
through the engine's physics pose (a full-weight override of every joint
that has a part; the joints without one, the toes and fingers, keep their
animated offsets under whichever part moves them). Balls keep
shoving the fallen body; *Reset* stands it up again at the spawn point.
A lighter hit ripples instead: only the parts hanging from the struck one
(the torso, for a hit on the pelvis) lose their motors and their gravity
for 0.12 s, so only the ball's momentum shows (three times over, so it
reads), then soft motors pull them back toward the live animation pose —
the animation's own, not the one on screen — and after a second the
tracking motors take them again; a second hit during the ripple widens it
and restarts it. *Reset* or a mode change cuts straight back to the
animation, standing. The engine side is a small seam (the skeleton's
joints and bind pose, this frame's joint transforms, a per-joint physics
pose with weights, applied after foot IK); the physics side is the
plugin's ragdoll (`JoltRagdoll`), built by `ZombieRagdollRig` from the
skeleton's bind pose so the parts sit on the joints and read straight back
onto them. The character controller and the ragdoll are on collision
layers that ignore each other; the balls pass through the controller's
shape and meet the ragdoll's parts. The room's walls
and furniture are on a layer of their own that the controller and the
balls meet but the powered ragdoll passes through — a desk within reach
would bend a tracked arm, and a box edge jittering into a part would push
it out while the motor pulls it back, every frame — and that the fallen
body lands on: the layer matrix follows the knock-down and the stand-up.
The floor slab stays on the common layer, so the feet keep it either way.

The package depends on the miolabs fork of the plugin at its
`feature/ragdoll` branch (the character controller, the ragdoll, the
environment boxes' layers) until upstream takes it; then the dependency
goes back to the plugin's own URL. To work on the plugin and the demo
together, `swift package edit UntoldJoltPhysics --path
../../UntoldJoltPhysics-ragdoll` points the build at a local checkout, and
`swift package unedit UntoldJoltPhysics` returns to the branch.

## visionOS (Apple Vision Pro)

`Examples/CoolZombieVisionOS` is a mixed-reality build: the zombie waits a
few meters in front of you in your real room; walk toward it and it comes
for you, stopping an arm's length away — around the furniture, and with
its hands on the wall when you stand behind one. The chase logic lives in
the `CoolZombieKit` library target (shared with the macOS demo); the app
feeds it the head pose from ARKit world tracking and the room from ARKit
plane detection and scene reconstruction.

Where it appears: 4 m ahead of your head when you enter the room, not of
the world origin — on the device the origin is wherever tracking last
started or was recentred, which the first captured room showed can be
against a wall with the room behind it. If a wall or furniture is closer
than that, the spawn pulls back to the last clear point, and if that
leaves it under 1.5 m away it goes sideways or behind you instead; the
zombie faces you either way. While it is still waiting, a room that
arrives after it was placed moves it to the corrected point. *Reset*
re-anchors to wherever you are now.

The room: every plane ARKit classifies becomes a box for the navigator
(`ZombieRoom`). Walls, doors and windows are thin boxes the height of the
plane; tables, seats and any other horizontal top between 15 cm and
1.9 m above the floor become boxes from the floor up to the top (the
zombie does not crawl under a table); floors, ceilings, slanted surfaces
and fragments under 40 cm are ignored. What has no plane — a sofa's arms,
a bed, a cabinet, a plant — comes from the scan: ARKit's scene
reconstruction mesh is rasterized, one mesh anchor at a time, into a
10 cm occupancy grid of everything between 15 cm and 1.9 m above the
floor; the cells within 30 cm of a wall's box or 15 cm of a top's box
belong to those (a wall's scan carries skirting, radiators and
curtains), the rest are clustered, clusters under six cells are noise,
and each remaining cluster becomes an oriented box (its smallest
enclosing rectangle, from the floor to its highest point), within half a
cell of the object's size. A wall the plane detection missed still
arrives this way, as a 1.9 m box along it. Once ARKit's room tracking knows which room you are
in, only that room's planes and meshes count, so what shows through an
open door stays out. The set is re-read twice a second while ARKit
refines its planes and meshes, so the boxes firm up over the first
minute in a new room — walk around it once. The control window's *Show
the room's boxes* draws them translucent to check the alignment; *Save
the room* writes the layout to the app's Documents folder (visible in
the Files app, under the app's name), from where it replays in the Mac
sandbox with `swift run CoolZombie -layoutFile <file.json>`.

Open `Examples/CoolZombieVisionOS/CoolZombieVisionOS.xcodeproj` and run the
`CoolZombieVisionOS-visionOS` scheme. The control window has *Provoke it*,
*Reset*, a *Clips* picker (the clip set, switchable while it runs) and an
inspection mode picker — *Chase* is the game; *Roam* walks
a circle around the spawn point at a walk/jog/run speed, *Idle* stands in
the idle clip, *Freeze* pauses the animation on its current pose, *T-pose*
holds the model's bind pose (an A-pose) with no clip, no foot IK and no
ragdoll pose, the asset exactly as exported — none of
which target you, so you can walk around the zombie and inspect it. On the
device the zombie stands on the floor plane ARKit detects (the world
origin's own floor estimate can be a centimetre or two off; the footnote
shows the height in use and whether it was detected or assumed, next to
the floor height the scene mesh gives and the trim in force; *Show the
detected floor* draws a 60 cm pad under the zombie at that height with a
post of 1 cm green and white bands beside it, and the *Floor trim*
stepper nudges the height by 5 mm, so feet that float or sink can be
blamed on the estimate, the asset or the clips by looking: the pad and
the bands, the T-pose, the idle. The plane detector's bias is a property
of each floor, a centimetre either way between rooms, so the height is
calibrated at run time: once the scene mesh has enough floor classified
around the zombie, the median height of those vertices is used instead of
the plane, as long as the two agree within 5 cm, and the footnote names
which one is in use; the trim is zero by default and not remembered). The
footnote also
prints the zombie's world position: a body that drifts on screen while
those numbers hold is the tracking correcting its world under it, not the
game. A standing zombie is never pushed by the room's boxes (they are
rebuilt twice a second as ARKit refines its meshes, and a jittering edge
used to shove it), and it ignores floor refinements under 1.5 cm and
follows larger ones at 2 cm/s rather than hopping or gliding with every
millimetre ARKit adjusts; the Xcode console reports any move of
a standing body with what changed in that frame. The zombie appears
about 4 m in front of wherever you look the moment it is ready, and
*Reset* brings it back in front of you; when the way ahead is blocked
within 1.5 m it takes the longest clear line to the side or behind. In the
simulator no planes are detected: the floor is placed 1 m below the
head and the bundled `sample` room (four walls, a sofa between the spawn
point and you, a table and an armchair) stands in for detection, drawn
by default so it can be seen. `-room <name|path>` loads a saved room on
either platform (`-room none` turns the sample off); launch arguments
`-autoOpenSpace`, `-autoProvoke`, `-autoRoam walk|jog|run` and
`-autoMode idle|freeze|tpose` open the immersive space and start a mode
(and `-inputWait always|never|auto`, `-framePacing full|half|halfWhenLate`
set the engine's pose-timing knobs at launch; the window's *Pose*,
*Pacing* and *AA* pickers switch the same two and the anti-aliasing live,
for telling the presentation from the tracking when the body sways against
the room while its coordinates hold)
without gaze-and-pinch input, for automated runs:

```bash
xcrun simctl launch <udid> com.miolabs.CoolZombieVisionOS -autoOpenSpace -autoProvoke
```

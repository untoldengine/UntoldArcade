# UntoldViewer

A comparison bench for the Untold Engine on Apple Vision Pro. The same objects, at the same
spot in your room, drawn by the engine or by RealityKit, one tap apart — so sharpness,
aliasing, lighting and frame time can be compared like for like while the engine is pushed.

It started as a debug mode inside the Oche darts game, where the engine's foveated rendering
and temporal anti-aliasing were first measured against the platform renderer on a dartboard's
1.4 mm wires. This is that test, made a home of its own, with a catalog that grows.

## Running it

```bash
cd UntoldViewer
xcodegen generate      # the project is generated from project.yml
open UntoldViewer.xcodeproj
```

Run on a physical Vision Pro: the simulator has no foveation and runs the engine's camera at the
space's origin (see "Simulator" below). The window has:

- **Objects** — the catalog; the chosen one is what the space shows.
- **Placement** — *In front of me*: the object stands the chosen distance ahead of where you are
  and look when the space opens, straight ahead, as a measurement pass places it, at eye height, turned to face you (the device anchor, read right after the space
  opens). *Fixed in the room*: ahead of where you stood when the space opened, at a chosen height,
  in the room's frame. The default distance is a dartboard's regulation oche (2.37 m), the fixed
  height its bull height (1.73 m). In either case, **pinch and drag** the object to move it —
  closer, farther, up, down — in both renderers (the engine scales the hand's travel ×4 so a
  far object can be reached; RealityKit's drag follows the pinch's projected location). The tour,
  when on, plays relative to wherever the object was dragged.
- **Motion** — *Still*, or the debug *Tour*: the object replays a 24-second loop relative to its
  placement, identically in both renderers — six seconds coming in to 30 % of the distance, six
  going back out, six sweeping 0.6 m left and right, six turning ±25°. Far-away shimmer, close-up
  detail, lateral motion for the temporal filter and a turning silhouette, with no hand on the
  headset, so renders and recordings compare under the same motion. The compositor's camera cannot
  be driven from the app, so it is the object that moves; the diagnostics line shows the loop time.
- **Engine** — anti-aliasing (MSAA 4× + TAA, MSAA 4×, TAA, FXAA), render quality (platform
  default, 0.75, 1.0; needs foveation, so greyed out on the simulator), lighting (the room's
  estimated light, or the engine's studio HDR), and the temporal filter's two knobs, live.
  Settings apply when a space is (re)opened.
- **Show in engine / Show in RealityKit / Close** — one immersive space is open at a time.
- The diagnostics line. Engine: frames, anti-aliasing mode and the opaque sample count the
  engine settled on, the per-eye drawable size, with foveation the screen size behind it, and the
  GPU time per frame as a one-second moving average (debug builds) — `gpu 12.3 ms (empty 9.1,
  object +3.2)`: the frame's GPU time beyond the previous frame's (consecutive frames overlap on
  the GPU, so a command buffer's own span would count the previous frame's tail too), what the
  empty space cost in the frames before the object was placed, and the difference, which is the
  object's own cost. RealityKit: the scene
  update rate its render loop drives.

Stand on the same spot for both renderers and switch. **Per-object GPU time across the two
renderers:** the engine side is the `object` figure on the line. RealityKit renders out of
process — in the system's render server, not in the app — so no API gives the app its GPU time;
profile the app with Instruments' **RealityKit Trace** template (Product ▸ Profile), read the GPU
frame time on the RealityKit Metrics track with the object shown and with the space empty (pick
Close, then reopen without an object is not possible, so use a tiny object such as a dart as the
near-empty baseline), and take the difference. The same template profiles the engine run for a
like-for-like trace of the whole frame.

### When the engine blinks and RealityKit does not

Under **Engine diagnostics** three live switches turn off, one at a time, the engine systems
that depend on the previous frame or on screen coverage — the ones a moving object defeats:

- **Occlusion cull** — the test against the previous frame's depth pyramid. It guards against
  the *camera* moving too far between frames, not the object; the depth it reads is a frame old,
  and a surface's own depth a frame ago is within the test's bias, so an object moving on its own
  passes it (the board's vanishing face turned out to be the culling list, not this test).
- **TAA jitter** — the sub-pixel jitter; the resolve still runs. Without motion vectors the
  temporal filter reprojects a moving object as if it stood still; what the clip rejects and
  accepts frame by frame can read as a brightness flicker. Switching anti-aliasing to MSAA 4×
  alone is the other way to take the temporal filter out of the picture.
- **Hidden-surface removal** — opaque draws that never discard a fragment use a model pipeline compiled without discards, so the GPU resolves visibility before shading and hidden fragments cost nothing; off, every draw takes the general pipeline. The summary counts the draws each way.
- **GPU pass timing** — on by default: the GPU timestamps each pass (the vertex and fragment stages of a render pass, the bounds of a compute or blit pass) and the measurement summary adds a second line with each pass's milliseconds, with the object and in the empty space.
- **Foveation** — on by default; off, the engine space opens without the compositor's rate maps, at the resolution the compositor then allocates (an experiment: the render-quality picker needs foveation). Applied when the space opens; the summary says "no foveation".
> **Build the engine optimized for every measurement.** The Debug configuration compiles the engine package at `-Onone`, and the frame is then CPU-bound on the headset: encoding the board's draws took 11.8 ms of a 10 ms frame (16 µs a draw), and the GPU downclocked while it waited. The engine's statistics (the GPU and CPU lines of the summary) are compiled only when the package is built unoptimized (Xcode takes the package's debug/release from the optimization level, not from the configuration's name), so measure with the optimizer forced on and the statistics flag passed explicitly:
>
> ```
> xcodebuild -project UntoldViewer.xcodeproj -scheme UntoldViewer -configuration Debug -destination 'platform=visionOS,id=<device>' SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s 'OTHER_SWIFT_FLAGS=$(inherited) -DENGINE_STATS_ENABLED' build
> ```
>
> On the Mac the same frame's encode takes 6.1 ms in a debug build and 1.2 ms optimized. The summary's third line, `engine <object> cpu (object / empty, ms): loop, update, wait, encode`, is the check: update + encode is the CPU's work per frame, the wait is the compositor's pacing.

- **Render path** — Forward by default, the headset's path: the geometry lights itself whole once per fragment and writes one colour, the light quad stands down. Hybrid: deferred, with the image-based light and the sun's shadow done once per fragment by the geometry and the light pass adding the direct lights. Deferred: the geometry fills the G-buffer and the light pass lights it, the path for many lights and for the effects that read the G-buffer (ambient occlusion, the debug views). The engine's `setRendering(.renderPath(_))`; the summary names the path. The switches of the chosen path show under the picker:
  - **Tile light stage** (deferred and hybrid) — on by default: the light pass as a tile kernel that lights each pixel once per colour it holds; off, the quad lights every multisample (the cost MSAA 4× used to carry). The summary says "(tile light)".
- **Shadow taps** — 8 by default, the engine's headset default: the sun shadow's compares per fragment, every second point of the 16-point Poisson disk (1.5 ms less than the whole disk on an 11 ms frame; judged acceptable 2026-10-13); 16 is the whole disk, 4 every fourth point, which bought nothing more. The summary says "shadow taps N" when it is not 8.
- **Sun** — on by default: the viewer's sun over the wearer's shoulder; off, the room's estimated light alone lights the object (applied when the space next opens; the summary says "no sun").
- **Room light ×** — 1 by default: a factor on the room estimate's light, live, to calibrate the object's brightness against the passthrough. The summary prints the estimate's intensity scale and the probe's camera scale reference it comes from.
- **Tone map** — None by default: the look pass hands the compositor the scene's linear colour, as RealityKit does in a mixed space, where the passthrough sets the display's response; ACES or AgX apply the engine's filmic curves, which compress the object's whites and lift its blacks against the room (measured: whites 87 of 255 against RealityKit's 113, blacks 15 against 9). The summary says "tone map aces/agx" when one is on.
- **Wide gamut** — on by default: the look pass shows the scene with the display's P3
  primaries, as RealityKit shows a mixed-immersion scene. Measured on the calibration panel,
  RealityKit's colours are the Display P3 → sRGB matrix of the sRGB values they were given
  (its board red (0.72, 0.13, 0.11) shows as (192, 0, 8), the cream (0.93, 0.85, 0.62) as
  (231, 207, 145)), its greys unchanged; so the engine applies that matrix after the tone map
  (`setPostFX(.colorPrimaries(.displayP3))`). Off, the sRGB colour as it is; the summary
  says "sRGB primaries".
- **Texture streaming** — the texture tiers that follow camera distance; a tier swap mid-motion
  would show as a texture blink. The summary prints the streaming's counters (tier upgrades and
  downgrades, entities at their full tier, operations in flight, texture memory of the budget).

The summary names the switches that were off ("occlusion off", "jitter off", "streaming off",
"studio light") and counts the **dark frames** of the pass: the viewer reads back the mean
brightness of each frame's picture (the passthrough is not in it) and counts a frame whose mean
fell by more than a third from the frame before — an object whose face was culled for a frame,
or whose light went — with the tour's time of the first few. The board's face vanishing on the
frames its smallest parts dropped out of the culling list (the engine's culling read the frame
before's list under the new count; fixed 2026-10-14) measured 7 such frames per tour loop on
the Mac and 0 after the fix.

The **Calibration panel** object is built from code in both renderers (no model files): four
rows of swatches — greys and colours, each as RealityKit's default tone map shows them and as
exact colours (`applyPostProcessToneMap: false`; the engine's rows are emissive black metals,
so its own look pass is what shows) — over an exact mid-grey backing, and three lit spheres,
white and black diffuse and chrome. A capture of each renderer with it, still, at the same
placement, measures RealityKit's tone curve against known values and its light against the
engine's, which is how the engine's look pass and room light are matched to it.

Record what you see with Reality Composer Pro's **Developer Capture** (File ▸ Developer
Capture, device connected): it saves a video of the wearer's view at full quality, which the
device's own Control Center recording does not. Visual faults do not show in an Instruments
trace; timing does.

### Measuring with Instruments

**Measure** (the button, or `-measure`) runs the chosen object through both renderers in turn —
engine, then RealityKit — one tour loop each after a few seconds to settle. A small status
pill floats just above the object (its transparent window takes the main window's spot, with the
capsule at its top edge) and stays up across both spaces,
showing the step ("Step 1 of 2 · Engine") and a countdown; the main window hides for the whole
pass and returns to the same spot with the results. Once the engine space is open the pill
asks you to look where the object should go and counts three seconds down; the pose at the end
of the countdown places it, straight ahead at eye level, and
the placement the engine round decides is reused for the RealityKit round, so both renderers
are judged from the same spot however you moved in between. The pass marks the phases
with signposts: an `Engine` interval named `empty` before the object is placed, then one named
after the object, and a `RealityKit` interval named after the object; a `Measure` interval
spans each renderer's whole phase. Record it with Instruments and the phases line up on the
timeline under *Points of Interest*; the GPU time per phase comes from the RealityKit Metrics
track (RealityKit Trace template) or the GPU track (Metal System Trace), and the object's cost
is the phase with the object minus the empty one.

```bash
Tools/measure.sh "<device name or UDID>" board        # records ~75 s, writes Measure-board.trace, opens it
```

The engine's own figures (total, empty, object) are logged and shown on the line at the end;
they exist in Debug builds only, so the scheme's Profile action builds Debug. Over a link that
drops, record one renderer per recording: the Measure menu (or `-measure engine`, then
`-measure realityKit`) runs a single phase, and the RealityKit-only pass reuses the placement
the engine pass saved, so the two recordings still compare the same spot. The pass also
appends its lines to `Documents/viewer.log` in the app's container, which
`xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier <bundle id> --source Documents/viewer.log --destination viewer.log`
fetches.
RealityKit's GPU time is only in the trace: it renders in the system's render server, outside
the app, where no API reaches.

### Launch arguments

For automation and quick runs from the command line:

| Argument | Effect |
|---|---|
| `-show engine` / `-show realityKit` | opens that space at launch |
| `-hideWindow` | closes the Controls window once the space is open |
| `-object dart_red` | which object (`board`, `dart_red`, `dart_blue`, `dart_green`, `dart_gold`) |
| `-placement front` / `-placement fixed` | in front of the wearer, or in the room's frame |
| `-distance 1.5` / `-height 1.2` | metres; the height applies to the fixed placement |
| `-motion tour` | the debug tour (`still` is the default) |
| `-measure` | the measurement pass (engine, then RealityKit, one tour loop each) |
| `-measure engine` / `-measure realityKit` | one renderer only, for one short Instruments recording per phase; the RealityKit-only pass reuses the placement the last engine pass saved |
| `-measure sweep` | the engine alone through six settings (every anti-aliasing mode at quality 1.0, then MSAA 4× + TAA at 0.75 and the platform default), same placement, one summary line each with GPU time, draw calls and triangles |
| `-antiAliasing msaa` / `-renderQuality high` / `-lighting studio` | the engine settings |

```bash
xcrun simctl launch booted com.untoldengine.untoldviewer -show engine -hideWindow -object board -placement fixed -height 0.73
```

### Simulator

In the visionOS simulator ARKit's frame (the device anchor, and the engine's camera) has its
origin at the head, while RealityKit's has it on the floor. The head-relative placement corrects
for it (the RealityKit side lifts the object by a simulated eye height of 1.5 m), so *In front of
me* works in both; with the fixed placement the engine's object appears a head's height higher
than RealityKit's, and `-height 0.73` (or the slider) brings it into the engine's view. On the
device both frames are the same. Foveation and render quality above the platform default are
device-only.

## Adding an object

Each catalog entry is two files made from one prepared source, plus one line in
`Viewer/App/Catalog.swift`:

1. **Engine model** — `Viewer/Resources/Models/<id>/<id>.untold` (with its `Textures/`), exported
   with the engine's `Scripts/export-untold --convert-orientation` from a prepared Blender file
   (materials flattened to Principled, transforms applied, origin where you want the object's
   pivot).
2. **USDZ twin** — `Viewer/Resources/Compare/<id>.usdz`, from the *same* prepared `.blend`:

   ```bash
   /Applications/Blender.app/Contents/MacOS/Blender -b prepared.blend --python Tools/blender/export_usdz.py -- Viewer/Resources/Compare/<id>.usdz
   ```

   The script applies the same orientation convert (Blender −Y front → +z), writes metres,
   meshes any text or curve objects (the USD exporter drops them otherwise), and packs the
   textures as a `UsdPreviewSurface`. Both files then carry the same geometry, maps and pivot.
3. **Catalog line** — `ViewerObject(id:title:detail:originFromCentre:)`: where the pivot sits
   relative to the visual centre, in the model's frame (the board's is its bull, a dart's its tip).

The dartboard and the darts here come from the Oche game's asset pipeline
(`Tools/blender` there: `prep_board.py`, `prep_dart.py`, `soften_maps.py`).

## Your own team and bundle identifier

The project ships as `com.untoldengine.untoldviewer` with automatic signing and no team. To
build under your own team without touching the project, create `Config/Local.xcconfig`
(gitignored):

```
DEVELOPMENT_TEAM = ABCDE12345
BUNDLE_ID_PREFIX = com.example
```

`Config/Config.xcconfig` composes the identifier from the prefix and includes the local file
when it exists, so the app becomes `com.example.untoldviewer` signed with your team; the
Info.plist reads the identifier from the build setting.

## Engine dependency

`project.yml` points at a local engine checkout while the foveation, temporal anti-aliasing and
back-face lighting pull requests (untoldengine/UntoldEngine #1342, #1343, #1344) are in review;
once they land, switch it to the engine's `develop` branch as the comment there says and
regenerate the project.

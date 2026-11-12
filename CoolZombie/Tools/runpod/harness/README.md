# Headless chase harness (motion-matching tuning)

`ZombieClipSetScratchTest.swift` replays the CoolZombie chase loop in the engine's render-test
target without a window, with a chosen clip set, and prints one `CS SUMMARY` line per run. It
holds the way `ZombieChaseGame` holds (matcher off on the waiting clip inside the stop distance,
back on past the resume distance) so its numbers describe the demo.

Per run it reports: jump rates while moving and holding, mean heading error, backward-moving
frames, time to face after a sharp flip, speed tracking, distances, clip usage, and — since
2026-09-09 — what a transition costs on screen:

- `pop`: at each jump, how far (max joint, and the feet) the last displayed pose sits from the
  incoming clip's raw pose — the discontinuity the inertializer has to hide;
- `acc p95/max` and `snaps`: the displayed pose's max-joint acceleration per frame (95th
  percentile, max) and the frames above `POP` (150 m/s², about a 4 cm one-frame snap). Hard
  cuts (a loop wrap, a foot-lock catch-up) show here; inertialized jumps mostly do not;
- `skate`: the feet's displayed world velocity against the authored one (the database's own
  foot-velocity features for the frame playing), so transitions, the root-velocity crossfade
  and the stance lock are measured as deviations from the clip;
- `slide`: horizontal ankle/ball travel while at planted height. Unreliable for a shuffling
  zombie (dragging feet count), kept for reference;
- `SCENARIO=solo CLIP=<name>`: one clip on repeat, matcher off, plus `seam` = the distance
  between its last and first frame (a loop wrap is never inertialized);
- `warp`: rigid turning — the entity's yaw change the playing clip's own root yaw does not
  account for (the orientation warp, the root-yaw crossfade), also while slow (< 0.6 m/s);
- `hands`: the hands' own acceleration (mean, p95), the arm flapping the user sees;
- `plant`: drift of a foot the playing clip itself holds still (its authored ankle speed below
  0.15 m/s) — the slide a planted foot shows under a transition, the root-velocity crossfade or
  the heading warp — per second planted, also while moving; the only slide figure worth
  trusting on a shuffling zombie;
- `LAYER=<clip>` puts that clip's arms on the pose layer, `REACH=1 RH=<height>` points them at
  the target as the demo does, `HW` adds hand positions to the matching features, `HCS`/`PEN`
  set the warp's full-rate speed and the one-shot runway penalty, `CC=1` (with `CES`/`CXS`)
  locks feet from the clip's own contact and `FP` sets the foot-position weight; a NaN in the
  displayed pose fails the run and names the joints.

Findings (results files alongside): the standing heads of the start clips made a held zombie
twitch (trimmed); the continuous speed ramp beat the pack's two clusters; `maxTurnRate` 3 rad/s
halves a standing about-face; transition halflife 0.1 s is the sweet spot (0.06 doubles the
acceleration spikes, longer does not reduce them); `switchMinimumGain` and `searchInterval`
barely matter; `minPlayTime` 0.5 cuts jumps by a third on the Kimodo set but costs heading error
and helps nothing on 100STYLE, so 0.3 stays; the stance lock trades slide for catch-up snaps on
every data source (its thresholds are not public API, left at the defaults; no visible
difference either way in the sandbox). The hard pops were the loop wraps: no generated take is cyclic (14-68 cm
between last and first frame; 1.1 m for the 100STYLE run) and starts, stops and pivots cannot be.
The engine's one-shot clips (`ONESHOT=auto`, branch `feature/mm_oneshot_clips`) remove them —
peak acceleration down 3-5x, snap frames halved — and the idles are re-cooked with their loop
seam closed (`loop` in `cook_options.json`). Hand positions as matching features (`HW`) cut the
arm pop at jumps by a third but treadmill a standing goal on the still head of the start clip
(its arms match, the idle's do not), so the demo leaves them off and puts the arms on the pose
layer instead (`LAYER`, results_2026-09-09_layer.txt). The heading warp is what turns the
mesh on still feet: 0.3 rad/s with a 1 m/s full-rate speed lets the Kimodo arcs and pivots do
the turning (orbit warp 22 -> 15 deg/s) for a few degrees of heading lag. Feet: the old stance
lock watched the displayed foot and let go the moment a transition moved it, exactly when a
foot needs holding — planted-foot drift 12-13 cm/s in the chase, 29-38 while moving. Locking on
the clip's own contact (`CC=1`) and weighting foot position 2-2.5x in the search (so a jump
lands where the feet are) brings it to 4-5 cm/s, 4-9 while moving (results_2026-09-09_feet.txt);
above 2.5 the foot weight treadmills a standing goal like the hands did, and the 100STYLE takes
churn while holding above 0.75.

It is a scratch test, never committed to the engine. To run it:

```bash
# an engine worktree with the harness copied in and the tests built
cp ZombieClipSetScratchTest.swift ~/Projects/Untold/UntoldEngine-motionmatching/Tests/UntoldEngineRenderTests/
cd ~/Projects/Untold/UntoldEngine-motionmatching && env -u TOOLCHAINS xcrun --toolchain XcodeDefault swift build --build-tests
export ENGINE_DIR=~/Projects/Untold/UntoldEngine-motionmatching
./run1.sh CLIPSET=kimodo SCENARIO=flip PROFILE=ramp MTR=3 ONESHOT=auto     # one run, about 6 s
./sweep.sh results.txt jobs.txt 3                                           # one run per line of jobs.txt, three at a time
python3 fmt.py OS MPT < results.txt                                         # table with the named descriptor fields
```

`run1.sh` runs the built xctest bundle directly (no `swift test`, which would take 30 s a run).
Env: `CLIPSET=style100|kimodo|mixed|pack`, `SCENARIO=approach|flip|orbit|solo`,
`PROFILE=clusters|ramp`, `MAX` (ramp top), `TP TD PH HCR MPT SMG MTR TH SI` (descriptor),
`ONESHOT=none|auto|all|<list>`, `FIK FL LES LXS MLD RHL` (foot IK and stance lock), `POP`,
`SECONDS`, `VERBOSE=1` (every 15th frame, every jump and every snap, with the joint behind it).
The asset path inside the test is absolute (this repository's kit resources).

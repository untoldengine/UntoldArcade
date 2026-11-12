# Animation polish backlog (2026-09-09)

What is still visibly wrong, with the harness figure that tracks it, so the later pass starts
from numbers. Figures are the pure Kimodo set on the chase harness (approach / flip / orbit)
with the settings the demo ships: one-shot clips, runway penalty 3, warp 0.3 rad/s at 1 m/s,
foot weight 2, clip-contact stance lock, the clawing hold's arms on the pose layer.

| artefact | figure now | data floor / target | likely fix |
| --- | --- | --- | --- |
| Foot pops at jumps between unlike takes (a crouched shamble against an upright walk: `pop feet` 10-17 cm, whole-body pops up to 1 m at a jump) | `pop feet` 14 / 17 / 10 cm, `snaps` 20 / 30 / 23 | a consistent set jumps at 5-8 cm | one more generation pass with the final rig: one posture family, prompts pinned to the same stance and crouch; pick takes by `hands_v`/posture, not only path error |
| Planted foot still drifting under the crossfade | `plant` 4-5 cm/s standing, 6-14 moving | the clips themselves: 2-4 | time-warp the incoming clip so its contact meets the floor before the entity moves (the user's "speed up instead of slide"); shorten the root-velocity crossfade while a foot is locked |
| Rigid turning vs heading lag | `warp` 6 / 5 / 15 deg/s at heading error 7 / 18 / 8 deg, flips 1.1 s | 100STYLE turns entirely by warp (34-53 deg/s) | arcs at more curvatures (60° and 120° at walk and run) so the search can turn at the rate the chase asks; per-speed pivots |
| Standing goals treadmill on still heads/tails of one-shot clips when pose weights rise | hold jumps 0.3/s at foot weight 2, 1.8-2.3/s at 2.5-3; hands features unusable (1.2-3.4/s) | 0.2-0.3/s | engine: dead-end avoidance for one-shot heads (a runway penalty on the *approach* to a still segment), or trim the start clips' standing heads to a single sample |
| Arms: the grab is procedural (per-arm reach weights on a 1.1 s cycle) over a hold take whose hands barely move (`hands_v` 0.07 m/s) | `hands` p95 22-27 | — | the `clips_arms.json` takes (reach-and-grab, arms high), picked by `hands_v`; a finger/hand-open take if the grab needs it |
| Elbows too high when reaching (user, 2026-09-09): the arm goes up from the shoulder to the elbow and down again to the hand, a hill; a natural reach drops from the shoulder and keeps dropping. The two-bone solve keeps the bend plane the layer take already has, and the generated takes hold their elbows out and up; present before the new takes too | — (no metric yet: elbow height above the shoulder-hand line would be one) | elbow below the shoulder-hand line | per-chain pole direction (elbows down and slightly out) blended with the take's bend hint in reach IK; an elbow-height term in the triage so raised-elbow takes lose the pick |
| Wall contact: hands aligned to the wall plane, not placed on it | — | — | per-chain reach targets (the reach IK has one target for both arms) aimed at the two hit points, palms oriented by the hold take |
| Chase start: the idle's stance never matches the start clip's head | first jump pop 27-45 cm | — | a start take generated from the idle's stance (if the model accepts a pose prior), or a short "shuffle into stride" take; otherwise the foot weight |
| 100STYLE has no turns, Mixed pops between styles | `warp` 34-53 deg/s (100STYLE) | — | accept for the reference set; the demo's set is Kimodo |

Everything above is re-measurable in minutes (`Tools/runpod/harness/README.md`); redo the sweeps after
the final zombie rig replaces ZombieAA, since the retarget moves every foot height and arm length.

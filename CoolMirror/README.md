# CoolMirror 🪞

A virtual mirror for Apple Vision Pro on Untold Engine: a rigged, high-poly
character stands in front of you and moves as you do, and shows off the
engine's character-deformation stack while it does.

Two devices watch you. An iPhone on a stand tracks your whole body with ARKit
and sends it over the local network. It sees you from the front, so it guesses
depth: standing still, it moves your head by 5 cm and your feet by 25. The
headset knows two things far better, where your head is and where your hands
are while its cameras have them. The mirror holds the character between what
is known: its head where the headset has yours, each planted foot where it
landed, and what the phone got wrong in between spread along the body like a
lean. The hands follow the headset while it sees them and the phone while it
does not, and the change never shows.

## What's inside

| Piece | What it demonstrates |
|---|---|
| `CoolMirrorGame` | The character, its clips, the live skinning switch (vertex shader, compute linear blend, dual quaternion, Direct Delta Mush), morph sliders, pose drivers, the XPBD muscle simulation and the ML deformer trained on it. |
| `CoolMirrorMocapController` | Capture to character every rendered frame: the engine's external pose for the body, reach IK targets for both hands and both held feet, the headset's own orientation for the head. |
| `CoolMirrorMocap` (library, shared with the iPhone app) | The wire format and transport, and everything that makes the capture watchable, each piece pure and tested: `MocapPoseFilter` (medians, jump limits, a heading guard against the tracker's flips, one-euro smoothing), `MocapRetargeter` (bone directions from positions, relative to how you stood at calibration), `MocapFootAnchor` (the character stands on its planted foot), `MocapBodyAnchor` and `MocapHeadTrack` (held by the head and the planted feet), `MocapArmReach` (a hand placed on the body where yours is), `MocapHandLadder` (headset or phone, per hand). |
| `MocapRecording` | A session on file: the phone's frames, the headset's head and hands at every frame it rendered, and a marker per guided step. Recordings replay through the same code on a Mac. |
| `CoolMirrorJoltCape`, `CoolMirrorCapeColliders` | Batman's cape as a Jolt soft body on the cape's own mesh, coarsened for the solver, colliding with convex hulls fitted to the character's mesh. |
| `CoolMirrorHandSession` | Hand tracking in an ARKit session of the demo's own. |
| `Examples/CoolMirror/iOS` | The capture app: rear-camera body tracking, a preview stream so the headset can show what the phone sees. |

## Run it

You need a Vision Pro and an iPhone whose rear camera supports ARKit body
tracking, on the same Wi-Fi.

1. Open `Examples/CoolMirror/CoolMirror.xcodeproj`. Run `CoolMirrorCapture`
   on the iPhone and `CoolMirrorVisionOS` on the Vision Pro. The visionOS
   scheme runs the Release configuration: in Debug the cape and the capture
   filters are ten to thirty times slower.
2. Stand the phone sideways (body tracking is landscape only) with the back
   camera facing you, three to four metres away, so your whole body is in the
   picture, feet included.
3. In the headset, open the mirror, pick Spider-Man or Batman and turn on
   **Use iPhone body tracking**. The phone's screen faces away from you, so
   the headset walks you through the setup and shows the phone's picture.
4. Stand upright facing the phone, tap **Calibrate** and hold still for the
   countdown. The character now mirrors you.

The panel's toggles compare each stage with what it replaces: **Mirror**,
**Flip**, **Move** (root motion), **Ground** (stand on the planted foot),
**Reach** (hands by reach IK), **Head** (held by the headset's head and the
planted feet), **Hands** (the headset's hands). Allow hand tracking when
asked, or the hands stay the phone's.

## Recordings

**Record** runs a guided session of a minute (stand still, lift a foot, raise
the arms, step, turn, hands in view and out of it) and saves a `.cmr` file to
the app's Documents folder. `Tests/CoolMirrorTests/Recordings` holds four of
them, and `MocapReplayTests` replays them through the filters, the anchors
and the hand handover: what jumped on the headset once must stay steady
there.

```bash
swift test   # the capture pipeline on synthetic data and on the recorded sessions, the cape's cloth and colliders
```

## Characters

`Scripts/prep_character.py` prepares a rigged FBX in Blender (transforms,
textures, biceps shape keys), `author_flex.py` writes the flex clip, and the
engine's exporter cooks the `.untold`. `swift run CoolMirrorBake` bakes the
muscle simulation into training data for the ML deformer.

## Credits

The two characters are community models from Sketchfab, used under the
[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/)
licence their authors published them with:

- **Spider-Man**: ["Spider-Man (2017; Homecoming - Tech Suit)"](https://sketchfab.com/3d-models/spider-man-2017-homecoming-tech-suit-6f58018044e147c08b8c2d7f552f46d1) by Mr. P (mrpgremlin).
- **Batman**: ["Batman Origins Suit - Textured and Rigged"](https://sketchfab.com/3d-models/batman-origins-suit-textured-and-rigged-ce83e407d259482c9ba284bced828933) by Light.k.

Changes made for the demo: transforms applied and textures relinked in
Blender, biceps shape keys and a flex clip added (`Scripts/`), cooked to
`.untold`, shown at a human height, and Batman's cape replaced by a simulated
one. Spider-Man and Batman are trademarks of their respective owners; the
models are fan works and this demo is not affiliated with or endorsed by them.

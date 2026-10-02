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

## Integration

- `GameScene.swift` owns Jolt registration, scene construction, and the drop
  check. The engine advances physics automatically; do not call `step` again.
- `ImmersiveGolApp.swift` installs Jolt before constructing `UntoldEngineXR`.
  Scene cleanup runs after the render loop stops, allowing the space to reopen.
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

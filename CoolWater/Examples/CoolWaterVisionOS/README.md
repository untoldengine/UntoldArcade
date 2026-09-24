# CoolWater visionOS Consumer Example

This is the client WebGL Water visionOS example migrated to the `CoolWater`
Rendering Extension plugin. It depends on the original Untold Engine checkout
and the local CoolWater package; it does not require the client's engine fork.

Open the included project:

```sh
open CoolWaterVisionOS.xcodeproj
```

The application installs `CoolWater` before renderer creation, retains the
original pool placement and ball interaction, loads the original tile/cubemap
art, and uses `CoolWaterARKitOcclusionProvider` for reconstruction occlusion.

For the complete startup, interaction, simulation, and rendering walkthrough,
see the package's [`../../README.md`](../../README.md#coolwater-code-walkthrough).

The short reading path is:

1. `CoolWaterVisionOSXRApp.swift` installs the plugin, creates `UntoldEngineXR`,
   and connects the engine callbacks.
2. `WaterXRGame.start()` initializes water state, art, XR input, and ARKit
   occlusion.
3. `WaterXRGame.update(deltaTime:)` turns pinches into ball or pool motion and
   publishes the model, sphere, and environment-light state.
4. `CoolWaterRenderExtension` consumes that state in its simulation, caustics,
   and scene passes.

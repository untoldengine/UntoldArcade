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

# SceneBuilder

SceneBuilder demonstrates Untold Engine's declarative, SwiftUI-style scene API on macOS. The running project currently shows a textured PBR cube lit by three orbiting point lights. Drag over the scene to orbit the camera; when you release, the camera keeps moving with a little inertia.

The project also contains a cube-wave example and a smaller parent/child mesh example that you can enable in `ContentView.swift`.

## Run it

Open `SceneBuilder.xcodeproj`, select the `SceneBuilder` scheme, and press `Cmd+R`.

## Start here in the code

Read the files in this order:

1. `SceneBuilderApp.swift` — creates the SwiftUI window and displays `ContentView`.
2. `ContentView.swift` — chooses which example is active. It currently returns `PBRCubeDemo()`.
3. `PBRCubeDemo.swift` — owns the renderer and scene state, declares the 3D hierarchy, handles dragging, and performs per-frame animation.
4. `CubeWaveDemo.swift` — a second example showing a declarative grid, entity hierarchy, and frame-driven animation.

## Code flow

### 1. SwiftUI selects the demo

`SceneBuilderApp.body` creates `ContentView`. `ContentView.body` returns `PBRCubeDemo`, so normal SwiftUI composition is also the entry point to the 3D example.

To run the cube wave instead, change the body in `ContentView.swift` from `PBRCubeDemo()` to `CubeWaveDemo()`.

### 2. A long-lived object owns renderer state

`PBRCubeView` accesses `PBRCubeScene.shared`. The scene's initializer:

- creates an `UntoldRenderer`;
- creates stable entity IDs for the cube, light rigs, lights, and marker spheres;
- enables image-based environment lighting;
- disables the default directional light so the three point lights drive the result.

The renderer and entity IDs live in a reference type rather than SwiftUI `@State`. That keeps per-frame mutations from rebuilding the declarative scene hierarchy.

### 3. `UntoldView` declares the scene

`PBRCubeView.body` passes the renderer to `UntoldView` and describes the final hierarchy:

- `CameraNode` creates the camera.
- `MeshNode` loads `BlueTile.usdz` and applies base-color, roughness, and normal textures.
- Each `Node` is a light-rig parent containing a `PointLightNode` and an emissive `SphereNode` marker.

The child nodes inherit their parent's transform. Rotating a light-rig parent therefore moves both its light and visible marker around the cube.

### 4. The engine drives animation

`UntoldView.onUpdate` receives the engine's per-frame event and calls `PBRCubeScene.update(deltaTime:)`. That method:

1. advances elapsed time;
2. rotates every light rig at its configured speed;
3. applies drag inertia when the pointer is released;
4. converts yaw and pitch into a camera position;
5. points the camera back at the cube with `cameraLookAt`.

Using `deltaTime` keeps animation speed independent of frame rate.

### 5. SwiftUI input changes engine state

A transparent SwiftUI overlay owns the `DragGesture` because the underlying Metal view consumes pointer events. Gesture deltas update `PBRCubeScene`'s yaw, pitch, and velocity. The next engine frame reads those values and moves the camera.

The complete path is:

```text
DragGesture
  → PBRCubeScene.dragChanged
  → yaw/pitch state
  → UntoldView.onUpdate
  → PBRCubeScene.update
  → cameraLookAt
  → rendered frame
```

### Follow the actual functions

`PBRCubeScene.init` creates identities and global render configuration, but it does not attach meshes or lights:

```swift
renderer = UntoldRenderer.create()
cubeID = createEntity()
rigs = [
    LightRig(
        groupID: createEntity(),
        lightID: createEntity(),
        markerID: createEntity(),
        axis: SIMD3<Float>(1, 0, 0),
        speed: 36
    ),
    // two more rigs...
]
```

Those stable IDs are then passed into the declarative nodes in `PBRCubeView.body`:

```swift
MeshNode(resource: "BlueTile.usdz", entityID: pbrScene.cubeID)
    .materialData(
        roughness: 0.6,
        baseColorResource: "Tiles_08_basecolor_1.jpg",
        roughnessResource: "Tiles_08_roughness_1.jpg",
        normalResource: "Tiles_08_normal_1.jpg"
    )

Node(entityID: rig.groupID) {
    PointLightNode(entityID: rig.lightID)
        .translateTo(y: 1.5)
    SphereNode(radius: 0.06, entityID: rig.markerID)
        .translateTo(y: 1.5)
}
```

The builder uses the IDs to attach components and parent/child relationships to the previously created entities. The light and marker receive the same local translation and the rig node becomes their parent. `PBRCubeScene.update` therefore only needs to rotate the parent:

```swift
for rig in rigs {
    rotateTo(
        entityId: rig.groupID,
        angle: time * rig.speed,
        axis: rig.axis
    )
}
```

Compare this with `TestView` in `ContentView.swift`. It calls `createEntity`, `setEntityMesh`, material functions, transforms, and `setParent` imperatively. `SceneBuilderView` expresses the same relationship by nesting one `MeshNode` inside another. Reading those two functions side by side is the fastest way to understand what the result-builder syntax replaces—and what still uses the ordinary entity API during updates.

## The other examples

`CubeWaveDemo` follows the same ownership pattern. `CubeWaveScene.shared` creates the renderer and stable entity IDs, `CubeWaveView` declares the nodes, and `onUpdate` moves the cubes with a sine wave while orbiting the camera.

`SceneBuilderView` in `ContentView.swift` is the smallest hierarchy example: a player `MeshNode` contains a ball `MeshNode`, and its update callback rotates the parent. `TestView` shows the equivalent imperative setup, making the declarative and imperative styles easy to compare.

## Experiments

- Change a point light's color, intensity, or orbit axis.
- Add another child to one of the light rigs and observe inherited transforms.
- Switch to `CubeWaveDemo` and modify the wave equation in `CubeWaveScene.update`.
- Compare `SceneBuilderView` with `TestView` to see how node nesting replaces explicit `setParent` calls.

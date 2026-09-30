# ProceduralGeometry Demo

A visionOS demo for [`ProceduralGeometryExtension`](https://github.com/untoldengine/ProceduralGeometryExtension) — a reusable [UntoldEngine](https://github.com/untoldengine/UntoldEngine) package for generating and interactively editing pipe/duct-style geometry from a path of control points.

This app is a real integration example, not a mockup: everything you can do to the pipe in XR goes through the extension's public API. If you're evaluating the extension for your own project, this app doubles as a reference for how to wire it up.

## What this demo shows

A single procedural tube you can select and reshape live in XR:

- Extend it from either end, with 90-degree bends created automatically as you change direction.
- Reshape or remove bends you've already placed.
- Rounded corners (not sharp miter joints) throughout.

All of that editing behavior — the axis-locking, the 90-degree bend detection, the undo/removal logic — lives in `ProceduralGeometryExtension`, not in this app. This app only supplies the XR-specific glue: picking, gesture dispatch, and a couple of invisible pickable spheres marking grab points.

## Using the demo in XR

1. **Look at a wall, floor, or ceiling and pinch the preview** to place and select a pipe.
2. **Drag the selected pipe's body** to move the whole pipe.
3. **Pinch the selected pipe again** to enter editing. Its endpoint handles appear. There is no timing window.
4. **Drag an endpoint** to extend the pipe. Change the direction of your hand mid-drag and a 90-degree bend is created automatically wherever you turned.
5. **Change your mind?** Reverse back through a bend you just created in the same drag and it's undone — the pipe resumes on whatever axis it was on before that bend, and you can redirect it somewhere else.
6. **Drag an existing bend** to slide it along either of the two pipe segments it connects. Drag it far enough that one of those segments would collapse, and the bend is removed — its neighbors reconnect directly.
7. **Two-hand pinch** to deselect. This explicit action is what makes placement available again.

Only 90-degree bends are supported by design (this demo's own choice, not a hard limit of the extension — see below).

## Build & run

Open `ProceduralGeometry.xcodeproj` in Xcode, pick a visionOS simulator or device, and run. Or from the command line:

```sh
xcodebuild -project ProceduralGeometry.xcodeproj -scheme ProceduralGeometry -destination 'generic/platform=visionOS Simulator' build
```

Dependencies are resolved from real remotes — `UntoldEngine` and `ProceduralGeometryExtension` — both pinned to their `develop`/`main` branches rather than tagged releases for now (see [Requirements](#requirements) below). If you edit `project.yml`, regenerate the Xcode project before building:

```sh
xcodegen generate
```

## Incorporating ProceduralGeometryExtension into your own project

### Requirements

- Swift tools 6.0, macOS 14+ / iOS 17+ / visionOS 2+.
- `UntoldEngine` on its `develop` branch. `ProceduralGeometryExtension` uses a few APIs (`Mesh.makeMesh(positions:...)`, `boundingBox`, `markEntityPickingDirty`) added by [PR #1214](https://github.com/untoldengine/UntoldEngine/pull/1214), which merged into `develop` but hasn't shipped in a tagged release yet. Once it has, switch to a version requirement instead.
- `ProceduralGeometryExtension`'s repository is currently **private** — you'll need GitHub access granted before Xcode/SPM can resolve it.

### 1. Add the package

In Xcode: **File → Add Package Dependencies…** and paste `https://github.com/untoldengine/ProceduralGeometryExtension.git`.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
    .package(url: "https://github.com/untoldengine/ProceduralGeometryExtension.git", branch: "main"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "UntoldEngineXR", package: "UntoldEngine"), // or UntoldEngineAR
            .product(name: "ProceduralGeometryExtension", package: "ProceduralGeometryExtension"),
        ]
    ),
]
```

### 2. Install the extension once, at startup

```swift
ProceduralGeometryExtension.shared.install()
```

Registers the extension with the engine's lifecycle, and registers `TubePathComponent` (the component holding a tube's shape data) for scene save/load.

### 3. Create a tube

```swift
let tubeId = ProceduralGeometryExtension.shared.createTubeEntity(
    controlPoints: [SIMD3(0, 1, -1), SIMD3(0.5, 1, -1), SIMD3(0.5, 1, -1.5)], // path, world space, meters — min 2 points
    radius: 0.03,          // uniform cross-section radius
    radialSegments: 16,    // cross-section resolution
    capStart: true,        // close the ends with a cap
    capEnd: true,
    bendRadius: 0.08,      // optional — rounds interior corners with a tangent-arc fillet instead of a sharp miter joint
    name: "MyPipe"
)
```

Returns `nil` (and creates nothing) if the input is invalid — fewer than 2 distinct points, non-positive radius, or fewer than 3 radial segments.

### 4. Edit a tube's shape

All of these return `Bool` (`false` = no-op, e.g. invalid index) and update the mesh immediately. Same-topology edits (moving points, changing radius) write directly into the existing GPU buffers; anything that changes point/vertex count triggers a full rebuild automatically — you don't need to think about which case you're in.

| Call | What it does |
|---|---|
| `setControlPoints(entityId:_:)` | Replace the whole path |
| `insertControlPoint(entityId:at:_:)` | Insert a new point at an index |
| `removeControlPoint(entityId:at:)` | Remove a point (refuses if it would drop below 2) |
| `setRadius(entityId:_:)` | Change the uniform cross-section radius |
| `setBendRadius(entityId:_:)` | Set (or clear, with `nil`) corner rounding |
| `setRadialSegments(entityId:_:)` | Change cross-section resolution |
| `setCaps(entityId:capStart:capEnd:)` | Toggle end caps |

The underlying data lives in `TubePathComponent` (`controlPoints`, `radius`, `radialSegments`, `capStart`, `capEnd`, `bendRadius`), readable directly via `scene.get(component: TubePathComponent.self, for: tubeId)` if you need to inspect current state.

### 5. Interactive dragging

The extension ships two small, self-contained types that implement exactly the interaction this demo uses. Neither one knows anything about picking, gestures, hand tracking, or rendering — each just consumes a raw 3D position every frame, from however you obtain it, and reports back where the dragged point should now be. That's deliberate: it means you can drive them from XR pinch tracking, a mouse, a game controller, or a test — and it means *this demo's* choice of using small invisible pickable proxy spheres for grab points is just one way to feed them, not the only way.

**`TubeEndpointDrag`** — drag a tube's start or end, with automatic 90-degree bend creation on turn, and undo-by-reversal for bends created in the same drag:

```swift
var drag = TubeEndpointDrag(tubeId: tubeId, isStart: false) // nil if the tube doesn't exist

// Every frame the gesture continues:
let position = drag?.update(rawPosition: currentHandPosition)
// `position` is already axis-constrained — move whatever represents the
// dragged point there (a proxy entity, a cursor, etc.)

// On the frame the gesture ends (see the doc comment on `end` for why this
// matters — release is commonly accompanied by a small involuntary movement
// that `update`'s turn detection would otherwise treat as deliberate):
let finalPosition = drag?.end(rawPosition: currentHandPosition)
```

**`TubeInteriorBendDrag`** — reshape or remove an *existing* bend by sliding it along one of its two segments:

```swift
var bendDrag = TubeInteriorBendDrag(tubeId: tubeId, index: bendIndex)

// Every frame:
if let position = bendDrag?.update(rawPosition: currentHandPosition) {
    // still exists — move your visual representation here
} else {
    // this call removed the bend (a segment collapsed) — stop the drag,
    // there's nothing left to represent
}
```

Both types expose a `Configuration` struct for tuning sensitivity/thresholds without forking the type — see their doc comments for defaults.

For a complete, working wiring example — picking, tap-to-select, proxy entities, gesture-phase handling — see `Sources/ProceduralGeometry/GameScene.swift` and `GameScene+TubeEditing.swift` in this demo.

### Where the responsibility boundary is

- **`ProceduralGeometryExtension`** owns the geometry: path-to-mesh generation, corner rounding, and the two interactive drag types above. It has no knowledge of picking, XR, or any application concept (BIM elements, connectivity, fittings, etc.).
- **This demo app** owns everything XR/interaction-specific on top of that: which entities are pickable, what a tap means, the visual selection affordance. Your own app is free to make completely different choices here (a gizmo tool, proximity-based grabbing, a different selection UI) while reusing the extension's drag types unchanged.

## Testing

The extension's test suite (`swift test` in the `ProceduralGeometryExtension` package) covers the geometry math and both drag types independently of any UI — including the two illustrated above, driven with synthetic positions instead of real hand tracking.

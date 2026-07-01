# Building an Untold Engine Rendering Extension Plugin

This guide explains how to create and integrate a reusable Untold Engine Rendering Extension plugin. It covers the Swift package boundary, extension lifecycle, resource and pipeline registration, render-graph passes, custom scene drawing, Metal packaging, consumer installation, and validation. CoolWater is the complete reference implementation in this repository.

The examples use `CoolWater` and the namespace `com.untoldengine.coolwater`. Replace these with names and a reverse-DNS namespace owned by your organization.

## Prerequisites

- A recent Xcode installation with the SDKs for the platforms you support.
- A local checkout of Untold Engine containing the Rendering Extension API.
- Swift Package Manager.
- A globally unique plugin identifier.

For local development, this guide uses:

```text
/Users/haroldserrano/Desktop/UntoldEngineStudio/UntoldEngine
```

## 1. Initialize the Swift package

To create the package and its directory from the parent folder:

```sh
cd /Users/haroldserrano/Downloads
mkdir CoolWater
cd CoolWater
swift package init --type library --name CoolWater
```

If the destination directory already exists and is empty, enter it and run only:

```sh
swift package init --type library --name CoolWater
```

Swift Package Manager creates an initial `Package.swift`, source target, and test target. Adjust those generated files to match the configuration below.

## 2. Create the package layout

Start with this structure:

```text
CoolWater/
├── Package.swift
├── README.md
├── Scripts/
│   └── build-metallib.sh
├── Sources/
│   └── CoolWater/
│       ├── CoolWaterPlugin.swift
│       ├── CoolWaterRenderExtension.swift
│       ├── Resources/
│       │   ├── CoolWater-macos.metallib
│       │   ├── CoolWater-ios.metallib
│       │   ├── CoolWater-iossim.metallib
│       │   ├── CoolWater-xros.metallib
│       │   └── CoolWater-xrossim.metallib
│       └── Shaders/
│           └── CoolWater.metal
└── Tests/
    └── CoolWaterTests/
        └── CoolWaterPluginTests.swift
```

The Metal source remains in the repository for development, but this package workflow uses a precompiled `.metallib` at runtime. SwiftPM copies Metal source as a resource; it does not compile it into the package-owned shader library required here.

## 3. Define the Swift package

Create `Package.swift`:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoolWater",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "CoolWater",
            targets: ["CoolWater"]
        ),
    ],
    dependencies: [
        .package(
            path: "/Users/haroldserrano/Desktop/UntoldEngineStudio/UntoldEngine"
        ),
    ],
    targets: [
        .target(
            name: "CoolWater",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            exclude: ["Shaders"],
            resources: [
                .copy("Resources/CoolWater-macos.metallib"),
                .copy("Resources/CoolWater-ios.metallib"),
                .copy("Resources/CoolWater-iossim.metallib"),
                .copy("Resources/CoolWater-xros.metallib"),
                .copy("Resources/CoolWater-xrossim.metallib"),
            ]
        ),
        .testTarget(
            name: "CoolWaterTests",
            dependencies: [
                "CoolWater",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ]
        ),
    ]
)
```

The dependency path is resolved from this package's `Package.swift`, not from the consuming application. An absolute path is appropriate for local development only.

For distribution, replace it with the canonical engine repository URL and a compatible release requirement. The application and plugin must resolve the same Untold Engine source and version.

Only declare platforms for which the package provides a compatible metallib.

## 4. Add a minimal rendering extension

Create `Sources/CoolWater/CoolWaterRenderExtension.swift`:

```swift
import UntoldEngine

final class CoolWaterRenderExtension: RenderExtension, @unchecked Sendable {
    let id = "com.untoldengine.coolwater.renderer"

    func buildGraph(
        _ builder: inout RenderGraphBuilder,
        context _: RenderGraphBuildContext
    ) {
        // Rendering passes are added in later milestones.
    }
}
```

Every extension needs a stable, globally unique ID and a `buildGraph` implementation. An extension supplied by a plugin must use the plugin ID itself or a child namespace beginning with the plugin ID followed by a dot.

Apply the same namespacing rule to shader libraries, pipelines, render passes, textures, buffers, and argument-buffer layouts. Avoid generic IDs such as `water`, `simulation`, or `surface`.

## 5. Add the plugin manifest and installation entry point

Create `Sources/CoolWater/CoolWaterPlugin.swift`:

```swift
import UntoldEngine

public struct CoolWaterPlugin: RenderExtensionPlugin {
    public let manifest = RenderExtensionPluginManifest(
        id: "com.untoldengine.coolwater",
        displayName: "Cool Water",
        version: RenderExtensionPluginVersion(
            major: 1,
            minor: 0,
            patch: 0
        )
    )

    public init() {}

    public func makeRenderExtensions() -> [any RenderExtension] {
        [CoolWaterRenderExtension()]
    }
}

@discardableResult
public func registerCoolWaterPlugin()
    -> RenderExtensionPluginInstallationResult
{
    RenderExtensionPluginRegistry.shared.install(CoolWaterPlugin())
}
```

The public installation function is the consumer-facing entry point. It installs all extensions supplied by the plugin atomically. A validation failure must not leave a partially installed plugin.

Do not separately register the internal extension with `setRendering`. Plugin-owned extensions must remain under plugin lifecycle management.

## 6. Prepare the Metal library

Compile the package shaders into a `.metallib` for every platform and SDK the package supports. Keep the compilation commands in `Scripts/build-metallib.sh` so artifacts are reproducible.

Package code should register its own library using `Bundle.module`:

```swift
func registerShaderLibraries(_ registry: RenderShaderLibraryRegistry) {
    registry.registerLibrary(
        "com.untoldengine.coolwater.shaders",
        bundle: .module,
        resource: CoolWaterPlatform.metallibResourceName
    )
}
```

The exact registration arguments and compilation flags should match the current engine API and shader-support headers.

Important constraints:

- A macOS metallib is not interchangeable with a visionOS metallib.
- Store artifacts in platform-specific locations if one resource name would be ambiguous.
- Rebuild the metallib whenever shader code or shared shader declarations change.
- Do not depend on shaders compiled into the engine's default library.
- Treat a missing or invalid metallib as an installation failure.

## 7. Install from an application

Add the `CoolWater` library product to the application target. Install the plugin once during startup, before renderer creation:

```swift
import CoolWater
import UntoldEngine

func installCoolWater() -> Bool {
    switch registerCoolWaterPlugin() {
    case .installed, .replaced:
        return true

    case let .rejected(failure):
        print("CoolWater validation errors:", failure.validationErrors)
        print("CoolWater artifact conflicts:", failure.artifactConflicts)
        print("CoolWater graph errors:", failure.graphValidationErrors)
        return false
    }
}
```

Do not ignore a rejected installation. Its validation, artifact-conflict, and graph-error collections identify different package integration failures.

## 8. Add a foundation test

Create `Tests/CoolWaterTests/CoolWaterPluginTests.swift`:

```swift
import Testing
import UntoldEngine
@testable import CoolWater

@Test
func pluginOwnsItsExtensionNamespaces() {
    let plugin = CoolWaterPlugin()
    let extensions = plugin.makeRenderExtensions()

    #expect(plugin.manifest.id == "com.untoldengine.coolwater")
    #expect(!extensions.isEmpty)
    #expect(
        extensions.allSatisfy {
            $0.id == plugin.manifest.id ||
                $0.id.hasPrefix(plugin.manifest.id + ".")
        }
    )
}
```

Add registry installation tests once their test environment initializes the engine services required by the extension. Remove installed plugins during teardown so shared registry state does not leak between tests.

Run package validation from the package root:

```sh
swift package resolve
swift build
swift test
```

## Foundation completion checklist

The package foundation is complete when:

- The local Untold Engine dependency resolves.
- The `CoolWater` library builds and imports from a consumer application.
- The plugin manifest and supplied extensions use the owned namespace.
- `registerCoolWaterPlugin()` returns `.installed` or `.replaced` before renderer creation.
- Installation failures are reported rather than ignored.
- The package finds its compatible metallib through `Bundle.module`.
- No package source or shader is added directly to the Untold Engine target.
- Consumers do not separately register plugin-owned extensions.
- The engine repository remains unmodified.

At that point the package has a valid dependency, distribution, and lifecycle boundary. Rendering resources, compute pipelines, render pipelines, and graph passes can then be added incrementally.

## Rendering Extension integration guide

### Extension lifecycle

An extension separates declaration from frame encoding:

1. The application installs the plugin before creating the renderer.
2. The engine validates the manifest and extension namespaces.
3. Registration hooks declare shader libraries, resources, argument layouts, and pipelines.
4. `buildGraph` declares passes and their resource access.
5. Pass closures execute later for each rendered frame or eye.
6. Uninstalling the plugin removes every artifact owned by its extensions.

Do not allocate renderer-dependent Metal objects in the extension initializer.
The initializer can run before an engine device or render targets exist. Use the
registration hooks for declarations and the pass context for per-frame work.

### `RenderExtension` hooks

Every extension implements `id` and `buildGraph`. Implement the other hooks only
when the feature requires them:

| Hook | Purpose |
| --- | --- |
| `registerShaderLibraries` | Load a package or framework metallib. |
| `registerResources` | Declare extension-owned textures and buffers. |
| `registerArgumentBuffers` | Describe model-surface shader arguments. |
| `registerComputePipelines` | Register compute functions. |
| `registerPipelines` | Register model-surface, scene, or offscreen render pipelines. |
| `buildGraph` | Add ordered frame passes with complete resource declarations. |

A feature can use several hooks in one extension or split independent behavior
across multiple extensions returned by the same plugin. Installation remains
atomic: if any supplied extension is invalid, the plugin is rejected.

### Stable artifact IDs

All IDs occupy engine-wide registries. Namespace every artifact beneath the
plugin ID:

```swift
enum PluginContract {
    static let pluginID = "com.example.reflections"
    static let extensionID = "com.example.reflections.renderer"
    static let shaderLibraryID: RenderShaderLibraryID =
        "com.example.reflections.shaders"
    static let colorTextureID: RenderTextureResourceID =
        "com.example.reflections.color"
    static let pipelineID: RenderPipelineType =
        "com.example.reflections.scene"
    static let passID = "com.example.reflections.scene-pass"
}
```

An extension owned by a plugin must use the plugin ID itself or start with the
plugin ID followed by a dot. Use constants shared by registration and graph code
to prevent spelling mismatches.

### Declare extension-owned resources

Resources are persistent by default and are released when their owner is
unregistered. Fixed and viewport-relative textures are supported:

```swift
func registerResources(_ registry: RenderResourceRegistry) {
    registry.registerTexture(
        RenderExtensionTextureDescriptor(
            id: PluginContract.colorTextureID,
            label: "Reflection Color",
            size: .viewportScale(1),
            pixelFormat: .rgba16Float,
            usage: [.renderTarget, .shaderRead]
        )
    )

    registry.registerBuffer(
        RenderExtensionBufferDescriptor(
            id: "com.example.reflections.vertices",
            label: "Reflection Vertices",
            length: vertexBufferLength
        )
    )
}
```

Descriptor usage and graph access must agree. A pass declaring `.write` requires
`.shaderWrite`; `.renderTarget` access requires `.renderTarget`; shader reads
require `.shaderRead`.

### Register compute pipelines

Compute pipelines should reference the package-owned shader library explicitly:

```swift
func registerComputePipelines(_ registry: ComputePipelineRegistry) {
    registry.registerComputePipeline(
        RenderExtensionComputePipelineDescriptor(
            id: "com.example.reflections.generate",
            function: "exampleReflectionKernel",
            shaderLibrary: .registered(PluginContract.shaderLibraryID),
            name: "Generate Reflections"
        )
    )
}
```

Retrieve the pipeline through the executing pass context instead of a global
manager:

```swift
guard let pipeline = context.computePipelines.pipeline(
    "com.example.reflections.generate"
)?.pipelineState else {
    return
}
```

### Register custom scene pipelines

Use `registerScenePipeline` for procedural geometry drawn into the engine's
working scene color and depth targets. The helper resolves platform-specific
formats and reverse-Z configuration:

```swift
func registerPipelines(_ registry: RenderPipelineRegistry) {
    registry.registerScenePipeline(
        PluginContract.pipelineID,
        vertexShader: "exampleSceneVertex",
        fragmentShader: "exampleSceneFragment",
        vertexShaderLibrary: .registered(PluginContract.shaderLibraryID),
        fragmentShaderLibrary: .registered(PluginContract.shaderLibraryID),
        vertexDescriptor: nil,
        depthCompareFunction: .lessEqual,
        depthEnabled: true,
        reverseZCompatible: true,
        blendMode: .alphaPremultiplied,
        name: "Example Scene Geometry"
    )
}
```

Use the lower-level `RenderExtensionRenderPipelineDescriptor` for pipelines that
target extension-owned textures with known formats, such as an offscreen
caustics or reflection map. Use `registerModelSurfacePipeline` when the engine
should draw ordinary entities and only the surface shader is customized.

### Build graph passes and declare every access

Add passes at stable stage anchors, never by depending on private engine pass
names. Resource declarations let the engine validate access and infer hazards:

```swift
func buildGraph(
    _ builder: inout RenderGraphBuilder,
    context _: RenderGraphBuildContext
) {
    builder.addPass(
        id: PluginContract.passID,
        stage: .beforePostProcess,
        resources: [
            .texture(PluginContract.colorTextureID, access: .renderTarget),
            .buffer("com.example.reflections.vertices", access: .read),
        ]
    ) { context in
        // Encode this frame's work.
    }
}
```

If one pass writes a resource and a later pass reads it, the graph establishes
the ordering hazard. Undeclared access, read-before-write, incompatible usage,
duplicate pass IDs, and unordered writes are graph validation failures.

Available stable stages are:

```text
afterOpaqueLighting
beforeTransparency
afterTransparency
beforePostProcess
afterPostProcess
beforeComposite
beforeLook
beforeOutput
```

Choose the earliest stage that provides the inputs your pass needs. Custom scene
geometry with matching scene depth is supported at `afterOpaqueLighting`,
`beforeTransparency`, `afterTransparency`, and `beforePostProcess`.

### Draw custom geometry into the engine scene

Use context-scoped pipeline and scene-target access inside a compatible pass:

```swift
guard let pipeline = context.renderPipelines.pipeline(PluginContract.pipelineID),
      let pipelineState = pipeline.pipelineState,
      let encoder = context.sceneRenderTargets.makeRenderCommandEncoder(
          actions: .loadAndStore,
          label: "Example Scene Pass"
      )
else {
    return
}
defer { encoder.endEncoding() }

encoder.setRenderPipelineState(pipelineState)
encoder.setDepthStencilState(pipeline.depthState)
encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
```

The engine copies its internal render-pass descriptor before applying the
requested actions, so the extension cannot mutate engine descriptor state.
Always end the encoder before the pass closure returns.

### Camera and visionOS per-eye state

`RenderPassContext.camera` contains the transforms for the eye currently being
rendered:

```swift
let camera = context.camera
let mvp = camera.viewProjectionMatrix * modelMatrix
let eyeWorld = camera.worldPosition
```

Do not read private camera or renderer globals. On visionOS, the same graph can
execute for both eyes. Encode visible scene geometry for every eye, but advance
shared simulations and eye-independent offscreen maps only once, normally when:

```swift
guard context.currentEye == 0 else { return }
```

Scene pipelines should normally set `reverseZCompatible: true`. The engine then
adapts ordered depth comparisons to its active depth convention.

### External textures and buffers

Prefer registry-owned resources when the extension creates and controls their
lifetime. Consumer-supplied Metal resources, such as CoolWater's tile texture
and sky cubemap, cannot be represented by a fixed registry descriptor. Retain
them in a thread-safe configuration object and declare their use on the render
encoder with `useResource`.

Validate texture types before binding them. A shader expecting `texturecube`
must not receive a two-dimensional texture.

### Installation, replacement, and cleanup

Install once before renderer creation. `.replaced` means a previously installed
plugin with the same manifest ID was atomically replaced. Do not also register
its internal extensions through `setRendering`.

For diagnostics or controlled teardown:

```swift
let manifests = RenderExtensionPluginRegistry.shared.installedManifests()
let failure = RenderExtensionPluginRegistry.shared.failure(
    forPluginID: PluginContract.pluginID
)
RenderExtensionPluginRegistry.shared.uninstall(id: PluginContract.pluginID)
```

Uninstall removes plugin-owned shader libraries, pipelines, resources, argument
layouts, and graph passes. It does not remove standalone application-local
extensions.

### Integration checklist

Before distributing an extension, verify:

- Installation occurs before renderer creation and handles `.rejected`.
- Plugin, extension, pipeline, resource, layout, and pass IDs are namespaced.
- Every shader function comes from an explicitly registered library.
- A compatible metallib is bundled for every declared platform and simulator.
- CPU and Metal uniform structures have tested size, alignment, and field order.
- Every pass declares all extension-owned texture and buffer access.
- Texture descriptor usage supports the declared graph access.
- Custom scene rendering uses `registerScenePipeline` and scene target access.
- Shared simulation work runs once per XR frame while scene drawing runs per eye.
- Consumer-supplied Metal resources are retained, validated, and marked with `useResource`.
- Plugin install, replacement, uninstall, resize, reset, and resource cleanup are tested.
- The extension builds without adding source or shaders to Untold Engine itself.

### Common integration failures

| Symptom | Likely cause |
| --- | --- |
| Plugin installation is rejected | Invalid namespace, missing metallib/function, artifact collision, or invalid graph. |
| Pipeline is unavailable in a pass | Pipeline registration failed or the wrong ID was used. |
| Scene encoder is `nil` | The pass uses a stage without compatible scene color/depth targets. |
| Resource lookup returns `nil` | The resource was not registered, was not declared by the pass, or the ID differs. |
| Graph reports read-before-write | No earlier pass declares a write to the resource. |
| Rendering works on macOS but not visionOS | Wrong metallib, hard-coded formats, missing per-eye drawing, or non-reverse-Z depth setup. |
| Metal validation reports an incompatible texture | Bound texture type or usage does not match the shader declaration. |
| Shader values appear corrupted | Swift and Metal ABI layout differs. |

## CoolWater runtime configuration

After installing the plugin, configure its simulation and scene through the public API:

```swift
setCoolWaterSphere(center: SIMD3<Float>(-0.4, 0.4, 0.2), radius: 0.3)
setCoolWaterLightDirection(SIMD3<Float>(2, 2, -1))
setCoolWaterModelMatrix(matrix_identity_float4x4)
setCoolWaterTilesTexture(tilesTexture) // 2D MTLTexture
setCoolWaterSkyTexture(skyCubemap)     // cube MTLTexture
seedCoolWaterRipples(count: 8)
```

Use `addCoolWaterDrop`, `setCoolWaterSphereCenter`, `setCoolWaterPaused`, and
`resetCoolWater` for runtime interaction. CoolWater supplies neutral fallback
textures when custom art is not configured. An invalid texture type is ignored:
tiles must be `.type2D` and the sky must be `.typeCube`.

On visionOS, real-scene depth occlusion can be enabled with the optional ARKit adapter:

```swift
let occlusion = CoolWaterARKitOcclusionProvider()
occlusion.start()
```

Retain the provider for as long as reconstruction should remain active and call
`occlusion.stop()` when leaving the immersive scene. Applications that already
manage reconstruction can instead submit `[CoolWaterOcclusionMesh]` directly
through `setCoolWaterOcclusionMeshes`.

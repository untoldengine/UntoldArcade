import Foundation
import UntoldEngine

/// Stable identifiers owned by the CoolWater package.
public enum CoolWaterPluginContract {
    public static let pluginID = "com.untoldengine.coolwater"
    public static let extensionID = "com.untoldengine.coolwater.renderer"
    public static let shaderLibraryID: RenderShaderLibraryID =
        "com.untoldengine.coolwater.shaders"
    public static let simulationTextureAID: RenderTextureResourceID =
        "com.untoldengine.coolwater.simulation.a"
    public static let simulationTextureBID: RenderTextureResourceID =
        "com.untoldengine.coolwater.simulation.b"
    public static let dropPipelineID: ComputePipelineType =
        "com.untoldengine.coolwater.simulation.drop"
    public static let updatePipelineID: ComputePipelineType =
        "com.untoldengine.coolwater.simulation.update"
    public static let normalPipelineID: ComputePipelineType =
        "com.untoldengine.coolwater.simulation.normal"
    public static let spherePipelineID: ComputePipelineType =
        "com.untoldengine.coolwater.simulation.sphere"
    public static let simulationPassID =
        "com.untoldengine.coolwater.simulation.pass"
    public static let causticsTextureID: RenderTextureResourceID =
        "com.untoldengine.coolwater.caustics.texture"
    public static let waterGridVertexBufferID: RenderBufferResourceID =
        "com.untoldengine.coolwater.grid.vertices"
    public static let waterGridIndexBufferID: RenderBufferResourceID =
        "com.untoldengine.coolwater.grid.indices"
    public static let causticsPipelineID: RenderPipelineType =
        "com.untoldengine.coolwater.caustics.pipeline"
    public static let causticsPassID =
        "com.untoldengine.coolwater.caustics.pass"
    public static let poolVertexBufferID: RenderBufferResourceID =
        "com.untoldengine.coolwater.pool.vertices"
    public static let sphereVertexBufferID: RenderBufferResourceID =
        "com.untoldengine.coolwater.sphere.vertices"
    public static let poolPipelineID: RenderPipelineType =
        "com.untoldengine.coolwater.scene.pool"
    public static let sphereRenderPipelineID: RenderPipelineType =
        "com.untoldengine.coolwater.scene.sphere"
    public static let surfaceAbovePipelineID: RenderPipelineType =
        "com.untoldengine.coolwater.scene.surface-above"
    public static let surfaceBelowPipelineID: RenderPipelineType =
        "com.untoldengine.coolwater.scene.surface-below"
    public static let scenePassID = "com.untoldengine.coolwater.scene.pass"
    public static let occlusionPipelineID: RenderPipelineType =
        "com.untoldengine.coolwater.scene.occlusion"
    public static let wallCausticsPipelineID: RenderPipelineType =
        "com.untoldengine.coolwater.scene.wall-caustics"
    public static let shaderFunctionNames = [
        "coolWaterDropKernel",
        "coolWaterUpdateKernel",
        "coolWaterNormalKernel",
        "coolWaterSphereKernel",
        "coolWaterCausticsVertex",
        "coolWaterCausticsFragment",
        "coolWaterOcclusionVertex",
        "coolWaterOcclusionFragment",
        "coolWaterPoolVertex",
        "coolWaterPoolFragment",
        "coolWaterSphereVertex",
        "coolWaterSphereFragment",
        "coolWaterSurfaceVertex",
        "coolWaterSurfaceAboveFragment",
        "coolWaterSurfaceBelowFragment",
        "coolWaterWallCausticsVertex",
        "coolWaterWallCausticsFragment",
    ]
}

/// Package-level lifecycle and distribution wrapper for CoolWater extensions.
public struct CoolWaterPlugin: RenderExtensionPlugin {
    public static var bundledMetallibURL: URL? {
        Bundle.module.url(
            forResource: CoolWaterPlatform.metallibResourceName,
            withExtension: "metallib"
        )
    }

    public let manifest = RenderExtensionPluginManifest(
        id: CoolWaterPluginContract.pluginID,
        displayName: "Cool Water",
        version: RenderExtensionPluginVersion(major: 1, minor: 0, patch: 0)
    )

    public init() {}

    public func makeRenderExtensions() -> [any RenderExtension] {
        [CoolWaterRenderExtension()]
    }
}

enum CoolWaterPlatform {
    static let metallibResourceName: String = {
        #if os(macOS)
        "CoolWater-macos"
        #elseif os(visionOS) && targetEnvironment(simulator)
        "CoolWater-xrossim"
        #elseif os(visionOS)
        "CoolWater-xros"
        #elseif os(iOS) && targetEnvironment(simulator)
        "CoolWater-iossim"
        #elseif os(iOS)
        "CoolWater-ios"
        #else
        #error("CoolWater does not provide a metallib for this platform")
        #endif
    }()
}

/// Installs CoolWater atomically. Call once before renderer creation.
@discardableResult
public func registerCoolWaterPlugin() -> RenderExtensionPluginInstallationResult {
    RenderExtensionPluginRegistry.shared.install(CoolWaterPlugin())
}

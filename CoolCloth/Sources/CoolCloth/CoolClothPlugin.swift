import Foundation
import UntoldEngine

/// Stable identifiers owned by the CoolCloth package.
public enum CoolClothPluginContract {
    public static let pluginID = "com.untoldengine.coolcloth"
    public static let extensionID = "com.untoldengine.coolcloth.renderer"
    public static let shaderLibraryID: RenderShaderLibraryID =
        "com.untoldengine.coolcloth.shaders"
    public static let positionTextureAID: RenderTextureResourceID =
        "com.untoldengine.coolcloth.position.a"
    public static let positionTextureBID: RenderTextureResourceID =
        "com.untoldengine.coolcloth.position.b"
    public static let previousPositionTextureID: RenderTextureResourceID =
        "com.untoldengine.coolcloth.position.previous"
    public static let velocityTextureID: RenderTextureResourceID =
        "com.untoldengine.coolcloth.velocity"
    public static let normalTextureID: RenderTextureResourceID =
        "com.untoldengine.coolcloth.normal"
    public static let initPipelineID: ComputePipelineType =
        "com.untoldengine.coolcloth.simulation.init"
    public static let predictPipelineID: ComputePipelineType =
        "com.untoldengine.coolcloth.simulation.predict"
    public static let solvePipelineID: ComputePipelineType =
        "com.untoldengine.coolcloth.simulation.solve"
    public static let finalizePipelineID: ComputePipelineType =
        "com.untoldengine.coolcloth.simulation.finalize"
    public static let normalPipelineID: ComputePipelineType =
        "com.untoldengine.coolcloth.simulation.normal"
    public static let simulationPassID =
        "com.untoldengine.coolcloth.simulation.pass"
    public static let clothIndexBufferID: RenderBufferResourceID =
        "com.untoldengine.coolcloth.cloth.indices"
    public static let ballVertexBufferID: RenderBufferResourceID =
        "com.untoldengine.coolcloth.ball.vertices"
    public static let clothPipelineID: RenderPipelineType =
        "com.untoldengine.coolcloth.scene.cloth"
    public static let ballPipelineID: RenderPipelineType =
        "com.untoldengine.coolcloth.scene.ball"
    public static let occlusionPipelineID: RenderPipelineType =
        "com.untoldengine.coolcloth.scene.occlusion"
    public static let scenePassID = "com.untoldengine.coolcloth.scene.pass"
    public static let shaderFunctionNames = [
        "coolClothInitKernel",
        "coolClothPredictKernel",
        "coolClothSolveKernel",
        "coolClothFinalizeKernel",
        "coolClothNormalKernel",
        "coolClothVertex",
        "coolClothFragment",
        "coolClothBallVertex",
        "coolClothBallFragment",
        "coolClothOcclusionVertex",
        "coolClothOcclusionFragment",
    ]
}

/// Package-level lifecycle and distribution wrapper for CoolCloth extensions.
public struct CoolClothPlugin: RenderExtensionPlugin {
    public static var bundledMetallibURL: URL? {
        Bundle.module.url(
            forResource: CoolClothPlatform.metallibResourceName,
            withExtension: "metallib"
        )
    }

    public let manifest = RenderExtensionPluginManifest(
        id: CoolClothPluginContract.pluginID,
        displayName: "Cool Cloth",
        version: RenderExtensionPluginVersion(major: 1, minor: 0, patch: 0)
    )

    public init() {}

    public func makeRenderExtensions() -> [any RenderExtension] {
        [CoolClothRenderExtension()]
    }
}

enum CoolClothPlatform {
    static let metallibResourceName: String = {
        #if os(macOS)
        "CoolCloth-macos"
        #elseif os(visionOS) && targetEnvironment(simulator)
        "CoolCloth-xrossim"
        #elseif os(visionOS)
        "CoolCloth-xros"
        #elseif os(iOS) && targetEnvironment(simulator)
        "CoolCloth-iossim"
        #elseif os(iOS)
        "CoolCloth-ios"
        #else
        #error("CoolCloth does not provide a metallib for this platform")
        #endif
    }()
}

/// Installs CoolCloth atomically. Call once before renderer creation.
@discardableResult
public func registerCoolClothPlugin() -> RenderExtensionPluginInstallationResult {
    RenderExtensionPluginRegistry.shared.install(CoolClothPlugin())
}

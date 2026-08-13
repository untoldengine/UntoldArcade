import Foundation
import UntoldEngine

/// Stable identifiers owned by the CoolSaber package.
public enum CoolSaberPluginContract {
    public static let pluginID = "com.untoldengine.coolsaber"
    public static let extensionID = "com.untoldengine.coolsaber.renderer"
    public static let shaderLibraryID: RenderShaderLibraryID =
        "com.untoldengine.coolsaber.shaders"
    public static let bladePipelineID: RenderPipelineType =
        "com.untoldengine.coolsaber.scene.blades"
    public static let scenePassID = "com.untoldengine.coolsaber.scene.pass"
    public static let shaderFunctionNames = [
        "coolSaberBladeVertex",
        "coolSaberBladeFragment",
    ]
}

/// Package-level lifecycle and distribution wrapper for CoolSaber extensions.
public struct CoolSaberPlugin: RenderExtensionPlugin {
    public static var bundledMetallibURL: URL? {
        Bundle.module.url(
            forResource: CoolSaberPlatform.metallibResourceName,
            withExtension: "metallib"
        )
    }

    public let manifest = RenderExtensionPluginManifest(
        id: CoolSaberPluginContract.pluginID,
        displayName: "Cool Saber",
        version: RenderExtensionPluginVersion(major: 1, minor: 0, patch: 0)
    )

    public init() {}

    public func makeRenderExtensions() -> [any RenderExtension] {
        [CoolSaberRenderExtension()]
    }
}

enum CoolSaberPlatform {
    static let metallibResourceName: String = {
        #if os(macOS)
        "CoolSaber-macos"
        #elseif os(visionOS) && targetEnvironment(simulator)
        "CoolSaber-xrossim"
        #elseif os(visionOS)
        "CoolSaber-xros"
        #elseif os(iOS) && targetEnvironment(simulator)
        "CoolSaber-iossim"
        #elseif os(iOS)
        "CoolSaber-ios"
        #else
        #error("CoolSaber does not provide a metallib for this platform")
        #endif
    }()
}

/// Installs CoolSaber atomically. Call once before renderer creation.
@discardableResult
public func registerCoolSaberPlugin() -> RenderExtensionPluginInstallationResult {
    RenderExtensionPluginRegistry.shared.install(CoolSaberPlugin())
}

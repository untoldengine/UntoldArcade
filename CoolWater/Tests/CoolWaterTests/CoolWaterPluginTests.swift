import CoolWater
import Metal
import UntoldEngine
import XCTest

final class CoolWaterPluginTests: XCTestCase {
    override func tearDown() {
        RenderExtensionPluginRegistry.shared.uninstall(
            id: CoolWaterPluginContract.pluginID
        )
        super.tearDown()
    }

    func testManifestAndExtensionNamespaceAreValid() {
        let plugin = CoolWaterPlugin()

        XCTAssertEqual(plugin.manifest.id, CoolWaterPluginContract.pluginID)
        XCTAssertEqual(plugin.manifest.requiredAPIVersion, .current)
        XCTAssertTrue(RenderExtensionPluginValidator.validate(plugin).isValid)
        XCTAssertEqual(
            plugin.makeRenderExtensions().map(\.id),
            [CoolWaterPluginContract.extensionID]
        )
    }

    func testPublicRegistrationEntryPointHasInstallationSignature() {
        let entryPoint: () -> RenderExtensionPluginInstallationResult =
            registerCoolWaterPlugin
        _ = entryPoint
    }

    func testBundledMetallibContainsEveryDeclaredFunction() throws {
        let url = try XCTUnwrap(CoolWaterPlugin.bundledMetallibURL)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(URL: url)

        for functionName in CoolWaterPluginContract.shaderFunctionNames {
            XCTAssertNotNil(
                library.makeFunction(name: functionName),
                "Missing Metal function: \(functionName)"
            )
        }
    }

    func testPluginInstallsAndUninstallsThroughPublicLifecycle() {
        let result = registerCoolWaterPlugin()

        switch result {
        case .installed, .replaced:
            break
        case let .rejected(failure):
            XCTFail("Plugin installation was rejected: \(failure)")
        }

        XCTAssertTrue(
            RenderExtensionPluginRegistry.shared.installedManifests().contains {
                $0.id == CoolWaterPluginContract.pluginID
            }
        )
        RenderExtensionPluginRegistry.shared.uninstall(
            id: CoolWaterPluginContract.pluginID
        )

        XCTAssertFalse(
            RenderExtensionPluginRegistry.shared.installedManifests().contains {
                $0.id == CoolWaterPluginContract.pluginID
            }
        )
    }
}

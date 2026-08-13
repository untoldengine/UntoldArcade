@testable import CoolSaber
import Metal
import XCTest

/// Loads the committed host metallib and checks the shader contract, so a
/// renamed entry point or missing resource fails here instead of as a silent
/// black screen on device.
final class CoolSaberGPUTests: XCTestCase {
    func testMetallibContainsContractFunctions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device on this host")
        }
        let url = try XCTUnwrap(
            CoolSaberPlugin.bundledMetallibURL,
            "bundled metallib missing — run Scripts/build-metallib.sh"
        )
        let library = try device.makeLibrary(URL: url)
        for name in CoolSaberPluginContract.shaderFunctionNames {
            XCTAssertNotNil(
                library.makeFunction(name: name),
                "metallib is missing shader function \(name)"
            )
        }
    }
}

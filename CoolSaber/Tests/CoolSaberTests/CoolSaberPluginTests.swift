@testable import CoolSaber
import simd
import UntoldEngine
import XCTest

final class CoolSaberPluginTests: XCTestCase {
    func testManifestUsesContractIdentifier() {
        let plugin = CoolSaberPlugin()
        XCTAssertEqual(plugin.manifest.id, CoolSaberPluginContract.pluginID)
    }

    func testPluginProvidesTheRenderExtension() {
        let extensions = CoolSaberPlugin().makeRenderExtensions()
        XCTAssertEqual(extensions.count, 1)
        XCTAssertEqual(extensions.first?.id, CoolSaberPluginContract.extensionID)
    }

    func testContractIdentifiersAreNamespacedByPluginID() {
        let prefix = CoolSaberPluginContract.pluginID + "."
        XCTAssertTrue(CoolSaberPluginContract.extensionID.hasPrefix(prefix))
        XCTAssertTrue(CoolSaberPluginContract.shaderLibraryID.rawValue.hasPrefix(prefix))
        XCTAssertTrue(CoolSaberPluginContract.bladePipelineID.rawValue.hasPrefix(prefix))
        XCTAssertTrue(CoolSaberPluginContract.scenePassID.hasPrefix(prefix))
    }

    func testBundledMetallibExistsForCurrentPlatform() {
        XCTAssertNotNil(CoolSaberPlugin.bundledMetallibURL)
    }

    /// Guards the hand-maintained mirror of CoolSaberShaderTypes.h. If either
    /// file changes shape, this fails before the GPU reads garbage.
    func testShaderABIStrideMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<CoolSaberBladeGPU>.stride, 48)
        XCTAssertEqual(MemoryLayout<CoolSaberSparkGPU>.stride, 32)
        // 64 (viewProj) + 16 (cameraWorld) + 16 (counts) + 4*48 + 8*32
        XCTAssertEqual(MemoryLayout<CoolSaberUniforms>.stride, 544)
    }

    func testSceneStateSanitizesBladeInput() {
        let state = CoolSaberSceneState.shared
        state.clear()

        state.setBlade(
            .localLeft,
            CoolSaberBladeDesc(
                hilt: SIMD3<Float>(0, 1, 0),
                direction: SIMD3<Float>(0, 0, -3), // not unit length
                length: 0.9
            )
        )
        let blade = state.state().blades[CoolSaberBladeSlot.localLeft.rawValue]
        XCTAssertNotNil(blade)
        XCTAssertEqual(simd_length(blade!.direction), 1, accuracy: 1e-5)

        state.setBlade(
            .localRight,
            CoolSaberBladeDesc(
                hilt: SIMD3<Float>(0, 1, 0),
                direction: .zero, // degenerate → hidden
                length: 0.9
            )
        )
        XCTAssertNil(state.state().blades[CoolSaberBladeSlot.localRight.rawValue])

        state.clear()
        XCTAssertTrue(state.state().blades.allSatisfy { $0 == nil })
    }

    func testSparkRingBufferIsBounded() {
        let state = CoolSaberSceneState.shared
        state.clear()
        for i in 0 ..< 20 {
            state.spawnSpark(
                position: SIMD3<Float>(Float(i), 0, 0),
                color: SIMD3<Float>(1, 1, 1),
                intensity: 1
            )
        }
        XCTAssertLessThanOrEqual(
            state.state().sparks.count,
            CoolSaberShaderLimits.maxSparks
        )
        state.clear()
    }
}

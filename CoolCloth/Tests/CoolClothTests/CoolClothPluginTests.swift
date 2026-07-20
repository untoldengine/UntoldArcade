@testable import CoolCloth
import simd
import XCTest

final class CoolClothPluginTests: XCTestCase {
    func testManifestUsesContractIdentifier() {
        let plugin = CoolClothPlugin()
        XCTAssertEqual(plugin.manifest.id, CoolClothPluginContract.pluginID)
    }

    func testPluginProvidesTheRenderExtension() {
        let extensions = CoolClothPlugin().makeRenderExtensions()
        XCTAssertEqual(extensions.count, 1)
        XCTAssertEqual(extensions.first?.id, CoolClothPluginContract.extensionID)
    }

    func testBundledMetallibExistsForCurrentPlatform() {
        XCTAssertNotNil(CoolClothPlugin.bundledMetallibURL)
    }

    func testGridTopology() {
        let n = CoolClothGridGeometry.gridSize
        let geometry = CoolClothGridGeometry.make()

        XCTAssertEqual(geometry.indices.count, (n - 1) * (n - 1) * 6)
        XCTAssertEqual(geometry.ballVertices.count, CoolClothGridGeometry.ballVertexCount)
        XCTAssertEqual(Int(geometry.indices.max() ?? 0), n * n - 1)
    }

    func testPickingReturnsNearestParticleToRay() {
        let n = CoolClothSimulation.gridSize
        var positions = [SIMD4<Float>](repeating: .zero, count: n * n)
        for row in 0 ..< n {
            for column in 0 ..< n {
                let x = Float(column) / Float(n - 1) * 2 - 1
                let y = 1 - Float(row) / Float(n - 1) * 2
                positions[row * n + column] = SIMD4<Float>(x, y, 0, 1)
            }
        }
        CoolClothPickingStore.shared.update(
            positions: positions,
            gridSize: n,
            modelMatrix: matrix_identity_float4x4
        )
        defer { CoolClothPickingStore.shared.resetForTesting() }

        // A ray straight at the cloth center should pick the middle particle.
        let pick = pickCoolClothParticle(
            rayOriginWorld: SIMD3<Float>(0, 0, 5),
            rayDirectionWorld: SIMD3<Float>(0, 0, -1),
            maxDistanceToRay: 0.1
        )

        XCTAssertNotNil(pick)
        if let pick {
            XCTAssertLessThanOrEqual(abs(pick.column - (n - 1) / 2), 1)
            XCTAssertLessThanOrEqual(abs(pick.row - (n - 1) / 2), 1)
            XCTAssertEqual(pick.rayDistance, 5, accuracy: 0.05)
        }

        // A ray missing the cloth entirely picks nothing.
        XCTAssertNil(
            pickCoolClothParticle(
                rayOriginWorld: SIMD3<Float>(0, 0, 5),
                rayDirectionWorld: SIMD3<Float>(0, 0, 1),
                maxDistanceToRay: 0.1
            )
        )
    }
}

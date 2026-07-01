@testable import CoolWater
import Metal
import XCTest

final class CoolWaterCausticsTests: XCTestCase {
    func testGridGeometryCoversWaterDomainWithValidIndices() {
        let geometry = CoolWaterGridGeometry.make()

        XCTAssertEqual(geometry.vertices.count, CoolWaterGridGeometry.vertexCount)
        XCTAssertEqual(geometry.indices.count, CoolWaterGridGeometry.indexCount)
        XCTAssertEqual(geometry.vertices.first, SIMD3<Float>(-1, -1, 0))
        XCTAssertEqual(geometry.vertices.last, SIMD3<Float>(1, 1, 0))
        XCTAssertEqual(geometry.indices.min(), 0)
        XCTAssertLessThan(
            Int(geometry.indices.max() ?? .max),
            geometry.vertices.count
        )
    }

    func testGridBufferLengthsMatchGeneratedData() {
        let geometry = CoolWaterGridGeometry.make()

        XCTAssertEqual(
            geometry.vertices.count * MemoryLayout<SIMD3<Float>>.stride,
            CoolWaterGridGeometry.vertexBufferLength
        )
        XCTAssertEqual(
            geometry.indices.count * MemoryLayout<UInt32>.stride,
            CoolWaterGridGeometry.indexBufferLength
        )
    }

    func testCausticsPipelineCompilesForDeclaredTargetFormat() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let libraryURL = try XCTUnwrap(CoolWaterPlugin.bundledMetallibURL)
        let library = try device.makeLibrary(URL: libraryURL)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(
            name: "coolWaterCausticsVertex"
        )
        descriptor.fragmentFunction = library.makeFunction(
            name: "coolWaterCausticsFragment"
        )
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float

        XCTAssertNoThrow(try device.makeRenderPipelineState(descriptor: descriptor))
    }
}

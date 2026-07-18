@testable import CoolWater
import Metal
import simd
import XCTest

final class CoolWaterSceneTests: XCTestCase {
    override func tearDown() {
        CoolWaterAppearance.shared.resetForTesting()
        setCoolWaterOcclusionMeshes([])
        super.tearDown()
    }

    func testSceneGeometryCountsAndBufferLengths() {
        let geometry = CoolWaterSceneGeometry.make()

        XCTAssertEqual(geometry.poolVertices.count, CoolWaterSceneGeometry.poolVertexCount)
        XCTAssertEqual(geometry.sphereVertices.count, CoolWaterSceneGeometry.sphereVertexCount)
        XCTAssertEqual(
            geometry.poolVertices.count * MemoryLayout<SIMD3<Float>>.stride,
            CoolWaterSceneGeometry.poolBufferLength
        )
        XCTAssertEqual(
            geometry.sphereVertices.count * MemoryLayout<SIMD3<Float>>.stride,
            CoolWaterSceneGeometry.sphereBufferLength
        )
        XCTAssertTrue(geometry.sphereVertices.allSatisfy {
            abs(simd_length($0) - 1) < 0.0001
        })
    }

    func testSceneUniformLayoutMatchesMetalABI() {
        // 64 (mvp) + 16 (eye) + 16 (light) + 16 (sphereCenter) + 16 (sphereRadius
        // padded) + 16 (ambient) = 144.
        XCTAssertEqual(MemoryLayout<CoolWaterSceneUniforms>.stride, 144)
        XCTAssertEqual(MemoryLayout<CoolWaterSceneUniforms>.alignment, 16)
    }

    func testEveryScenePipelineCompilesForWorkingFormats() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let libraryURL = try XCTUnwrap(CoolWaterPlugin.bundledMetallibURL)
        let library = try device.makeLibrary(URL: libraryURL)
        let functions = [
            ("coolWaterPoolVertex", "coolWaterPoolFragment"),
            ("coolWaterSphereVertex", "coolWaterSphereFragment"),
            ("coolWaterSurfaceVertex", "coolWaterSurfaceAboveFragment"),
            ("coolWaterSurfaceVertex", "coolWaterSurfaceBelowFragment"),
            ("coolWaterOcclusionVertex", "coolWaterOcclusionFragment"),
        ]

        for (vertexName, fragmentName) in functions {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertexName)
            descriptor.fragmentFunction = library.makeFunction(name: fragmentName)
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            descriptor.depthAttachmentPixelFormat = .depth32Float
            XCTAssertNoThrow(
                try device.makeRenderPipelineState(descriptor: descriptor),
                "Failed pipeline: \(vertexName) / \(fragmentName)"
            )
        }
    }

    func testOcclusionMeshesAreStoredAndCleared() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let vertexBuffer = try XCTUnwrap(device.makeBuffer(length: 64))
        let indexBuffer = try XCTUnwrap(device.makeBuffer(length: 12))
        let mesh = CoolWaterOcclusionMesh(
            vertexBuffer: vertexBuffer,
            vertexOffset: 4,
            vertexStride: 16,
            indexBuffer: indexBuffer,
            indexOffset: 0,
            indexCount: 3,
            indexType: .uint32,
            transform: matrix_identity_float4x4
        )

        setCoolWaterOcclusionMeshes([mesh])
        let stored = CoolWaterOcclusionStore.shared.snapshot()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stored[0].vertexBuffer === vertexBuffer)
        XCTAssertTrue(stored[0].indexBuffer === indexBuffer)
        XCTAssertEqual(stored[0].vertexOffset, 4)
        XCTAssertEqual(stored[0].vertexStride, 16)
        XCTAssertEqual(stored[0].indexCount, 3)

        setCoolWaterOcclusionMeshes([])
        XCTAssertTrue(CoolWaterOcclusionStore.shared.snapshot().isEmpty)
    }

    func testAppearanceStoresModelAndArtTextures() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let tilesDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        let tiles = try XCTUnwrap(device.makeTexture(descriptor: tilesDescriptor))
        let skyDescriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba8Unorm,
            size: 1,
            mipmapped: false
        )
        let sky = try XCTUnwrap(device.makeTexture(descriptor: skyDescriptor))
        var model = matrix_identity_float4x4
        model.columns.3 = SIMD4<Float>(1, 2, 3, 1)

        setCoolWaterModelMatrix(model)
        setCoolWaterTilesTexture(tiles)
        setCoolWaterSkyTexture(sky)
        let state = CoolWaterAppearance.shared.state()

        XCTAssertEqual(state.modelMatrix, model)
        XCTAssertTrue(state.tilesTexture === tiles)
        XCTAssertTrue(state.skyTexture === sky)
    }
}

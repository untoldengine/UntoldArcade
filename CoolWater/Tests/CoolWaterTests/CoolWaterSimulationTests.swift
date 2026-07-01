@testable import CoolWater
import Metal
import simd
import XCTest

final class CoolWaterSimulationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CoolWaterSimulation.shared.resetForTesting()
    }

    override func tearDown() {
        CoolWaterSimulation.shared.resetForTesting()
        super.tearDown()
    }

    func testFrameStateConsumesDropsExactlyOnce() {
        setCoolWaterPaused(true)
        setCoolWaterSphere(center: SIMD3<Float>(0.1, 0.2, 0.3), radius: 0.4)
        addCoolWaterDrop(center: SIMD2<Float>(0.25, -0.5), radius: 0.08, strength: 0.2)

        let first = CoolWaterSimulation.shared.consumeFrameState()
        let second = CoolWaterSimulation.shared.consumeFrameState()

        XCTAssertTrue(first.paused)
        XCTAssertEqual(first.sphereCenter, SIMD3<Float>(0.1, 0.2, 0.3))
        XCTAssertEqual(first.sphereRadius, 0.4)
        XCTAssertEqual(first.lightDirection, simd_normalize(SIMD3<Float>(2, 2, -1)))
        XCTAssertEqual(first.drops.count, 1)
        XCTAssertEqual(first.drops[0].center, SIMD2<Float>(0.25, -0.5))
        XCTAssertEqual(first.drops[0].radius, 0.08)
        XCTAssertEqual(first.drops[0].strength, 0.2)
        XCTAssertTrue(second.drops.isEmpty)
    }

    func testLightDirectionIsNormalized() {
        setCoolWaterLightDirection(SIMD3<Float>(0, 4, 0))

        let state = CoolWaterSimulation.shared.consumeFrameState()

        XCTAssertEqual(state.lightDirection, SIMD3<Float>(0, 1, 0))
    }

    func testSeededRipplesAreDeterministic() {
        seedCoolWaterRipples(count: 8, seed: 42)
        let first = CoolWaterSimulation.shared.consumeFrameState().drops

        CoolWaterSimulation.shared.resetForTesting()
        seedCoolWaterRipples(count: 8, seed: 42)
        let second = CoolWaterSimulation.shared.consumeFrameState().drops

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 8)
        XCTAssertEqual(first.map(\.strength), [0.01, -0.01, 0.01, -0.01, 0.01, -0.01, 0.01, -0.01])
    }

    func testResetClearsPendingDropsAndAdvancesGeneration() {
        let initialGeneration = CoolWaterSimulation.shared.consumeFrameState().resetGeneration
        addCoolWaterDrop(center: .zero)

        resetCoolWater()
        let state = CoolWaterSimulation.shared.consumeFrameState()

        XCTAssertEqual(state.resetGeneration, initialGeneration + 1)
        XCTAssertTrue(state.drops.isEmpty)
    }

    func testInvalidInputsAreIgnored() {
        setCoolWaterSphere(center: .zero, radius: -1)
        addCoolWaterDrop(center: .zero, radius: 0, strength: 1)
        addCoolWaterDrop(center: SIMD2<Float>(.nan, 0))

        let state = CoolWaterSimulation.shared.consumeFrameState()

        XCTAssertEqual(state.sphereRadius, 0.25)
        XCTAssertTrue(state.drops.isEmpty)
    }

    func testDropKernelWritesDestinationWithoutMutatingSource() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let libraryURL = try XCTUnwrap(CoolWaterPlugin.bundledMetallibURL)
        let library = try device.makeLibrary(URL: libraryURL)
        let function = try XCTUnwrap(library.makeFunction(name: "coolWaterDropKernel"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: 256,
            height: 256,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let destination = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let zeros = [SIMD4<Float>](repeating: .zero, count: 256 * 256)
        zeros.withUnsafeBytes { bytes in
            for texture in [source, destination] {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, 256, 256),
                    mipmapLevel: 0,
                    withBytes: bytes.baseAddress!,
                    bytesPerRow: 256 * MemoryLayout<SIMD4<Float>>.stride
                )
            }
        }

        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        var center = SIMD2<Float>.zero
        var radius: Float = 0.1
        var strength: Float = 0.2
        encoder.setBytes(&center, length: MemoryLayout.size(ofValue: center), index: 0)
        encoder.setBytes(&radius, length: MemoryLayout.size(ofValue: radius), index: 1)
        encoder.setBytes(&strength, length: MemoryLayout.size(ofValue: strength), index: 2)
        encoder.dispatchThreads(
            MTLSize(width: 256, height: 256, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)

        func centerHeight(_ texture: MTLTexture) -> Float {
            var pixel = SIMD4<Float>.zero
            texture.getBytes(
                &pixel,
                bytesPerRow: MemoryLayout<SIMD4<Float>>.stride,
                from: MTLRegionMake2D(128, 128, 1, 1),
                mipmapLevel: 0
            )
            return pixel.x
        }

        XCTAssertEqual(centerHeight(source), 0)
        XCTAssertGreaterThan(centerHeight(destination), 0)
    }
}

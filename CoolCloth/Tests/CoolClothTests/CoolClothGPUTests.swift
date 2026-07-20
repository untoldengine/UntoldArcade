@testable import CoolCloth
import Metal
import simd
import XCTest

/// Executes the actual simulation kernels and render shaders on the GPU with the
/// same encoding sequence the render extension uses, so a cloth that would be
/// invisible or exploding in the app fails here first.
final class CoolClothGPUTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var library: MTLLibrary!

    private let n = CoolClothSimulation.gridSize

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let url = try XCTUnwrap(CoolClothPlugin.bundledMetallibURL)
        library = try device.makeLibrary(URL: url)
    }

    // MARK: - Harness

    private func makeSimTexture() throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: n, height: n, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func kernel(_ name: String) throws -> MTLComputePipelineState {
        let function = try XCTUnwrap(library.makeFunction(name: name), "missing \(name)")
        return try device.makeComputePipelineState(function: function)
    }

    private struct Sim {
        var posA: MTLTexture
        var posB: MTLTexture
        var prev: MTLTexture
        var vel: MTLTexture
        var nrm: MTLTexture
        var currentIsA = true

        var current: MTLTexture { currentIsA ? posA : posB }
        var other: MTLTexture { currentIsA ? posB : posA }
    }

    private func makeParams(
        model: simd_float4x4,
        dt: Float,
        pinMode: CoolClothPinMode,
        material: CoolClothMaterialParameters,
        floorWorldY: Float,
        time: Float,
        wind: SIMD3<Float> = .zero,
        sphere: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0.1),
        sphereActive: Bool = false
    ) -> CoolClothSimParams {
        CoolClothSimParams(
            model: model,
            invModel: simd_inverse(model),
            gravityDt: SIMD4<Float>(0, -9.81, 0, dt),
            wind: SIMD4<Float>(wind, 0.5),
            sphere: sphere,
            grabTarget: SIMD4<Float>(0, 0, 0, floorWorldY),
            compliance: SIMD4<Float>(
                material.stretchCompliance,
                material.shearCompliance,
                material.bendCompliance,
                0.5
            ),
            misc: SIMD4<Float>(material.damping, 2.0 / Float(n - 1), time, 25.0),
            flags: SIMD4<UInt32>(pinMode.rawValue, 0, sphereActive ? 1 : 0, 0),
            grab: SIMD4<UInt32>(0, 0, 0, 0)
        )
    }

    private func dispatch(
        _ pipeline: MTLComputePipelineState,
        _ commandBuffer: MTLCommandBuffer,
        params: inout CoolClothSimParams,
        textures: [MTLTexture]
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return XCTFail("no compute encoder")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(
            &params,
            length: MemoryLayout<CoolClothSimParams>.stride,
            index: CoolClothSimBufferIndex.params.rawValue
        )
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        let width = max(1, pipeline.threadExecutionWidth)
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: n, height: n, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
    }

    /// Runs init + `frames` simulated frames with the extension's exact sequence.
    private func runSimulation(
        model: simd_float4x4,
        pinMode: CoolClothPinMode,
        material: CoolClothMaterialParameters,
        floorWorldY: Float,
        frames: Int,
        substeps: Int = 8,
        wind: SIMD3<Float> = .zero,
        sphere: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0.1),
        sphereActive: Bool = false
    ) throws -> Sim {
        var sim = Sim(
            posA: try makeSimTexture(),
            posB: try makeSimTexture(),
            prev: try makeSimTexture(),
            vel: try makeSimTexture(),
            nrm: try makeSimTexture()
        )
        let initKernel = try kernel("coolClothInitKernel")
        let predictKernel = try kernel("coolClothPredictKernel")
        let solveKernel = try kernel("coolClothSolveKernel")
        let finalizeKernel = try kernel("coolClothFinalizeKernel")
        let normalKernel = try kernel("coolClothNormalKernel")

        let frameDelta: Float = 1.0 / 90.0
        let dt = frameDelta / Float(substeps)
        var time: Float = 0

        var params = makeParams(
            model: model, dt: dt, pinMode: pinMode, material: material,
            floorWorldY: floorWorldY, time: time, wind: wind,
            sphere: sphere, sphereActive: sphereActive
        )

        let initBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        dispatch(
            initKernel, initBuffer, params: &params,
            textures: [sim.current, sim.prev, sim.vel, sim.nrm]
        )
        initBuffer.commit()
        initBuffer.waitUntilCompleted()

        for _ in 0 ..< frames {
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            for _ in 0 ..< substeps {
                params.misc.z = time
                dispatch(
                    predictKernel, commandBuffer, params: &params,
                    textures: [sim.current, sim.other, sim.prev, sim.vel, sim.nrm]
                )
                sim.currentIsA.toggle()
                dispatch(
                    solveKernel, commandBuffer, params: &params,
                    textures: [sim.current, sim.other, sim.prev]
                )
                sim.currentIsA.toggle()
                dispatch(
                    finalizeKernel, commandBuffer, params: &params,
                    textures: [sim.current, sim.prev, sim.vel]
                )
                time += dt
            }
            dispatch(
                normalKernel, commandBuffer, params: &params,
                textures: [sim.current, sim.nrm]
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        return sim
    }

    private func readParticles(_ texture: MTLTexture) -> [SIMD4<Float>] {
        var data = [SIMD4<Float>](repeating: .zero, count: n * n)
        data.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: n * MemoryLayout<SIMD4<Float>>.stride,
                from: MTLRegionMake2D(0, 0, n, n),
                mipmapLevel: 0
            )
        }
        return data
    }

    private func demoModel() -> simd_float4x4 {
        // Matches ClothXRGame defaults: scale 0.75, center 1.2 m in front,
        // top edge 1.85 m above a floor at -1.2.
        let s: Float = 0.75
        var m = matrix_identity_float4x4
        m.columns.0.x = s
        m.columns.1.y = s
        m.columns.2.z = s
        m.columns.3 = SIMD4<Float>(0, -1.2 + 1.85 - s, -1.2, 1)
        return m
    }

    // MARK: - Simulation behavior

    func testCurtainSettlesFiniteAndPinned() throws {
        let sim = try runSimulation(
            model: demoModel(),
            pinMode: .topEdge,
            material: CoolClothMaterialPreset.silk.parameters,
            floorWorldY: -1.2,
            frames: 90
        )
        let particles = readParticles(sim.current)

        var minY: Float = .greatestFiniteMagnitude
        var maxY: Float = -.greatestFiniteMagnitude
        for (index, p) in particles.enumerated() {
            XCTAssertTrue(
                p.x.isFinite && p.y.isFinite && p.z.isFinite,
                "particle \(index) is not finite: \(p)"
            )
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }

        // The pinned top row must not have moved.
        for column in 0 ..< n {
            let p = particles[column]
            XCTAssertEqual(p.w, 0, "top row should be pinned")
            XCTAssertEqual(p.y, 1, accuracy: 1e-4)
            XCTAssertEqual(p.z, 0, accuracy: 1e-4)
        }

        // A silk curtain hanging for a second stays roughly a curtain: the top
        // is at +1 and the lowest particle hasn't stretched far past the
        // original 2-unit length.
        XCTAssertEqual(maxY, 1, accuracy: 1e-3)
        XCTAssertGreaterThan(minY, -1.4, "cloth stretched way past its rest length")
        XCTAssertLessThan(minY, -0.8, "cloth did not hang down under gravity")
    }

    func testFreeClothLandsOnFloor() throws {
        let model = demoModel()
        let floorWorldY: Float = -1.2
        let sim = try runSimulation(
            model: model,
            pinMode: .none,
            material: CoolClothMaterialPreset.cotton.parameters,
            floorWorldY: floorWorldY,
            frames: 240
        )
        let particles = readParticles(sim.current)

        for (index, p) in particles.enumerated() {
            XCTAssertTrue(
                p.x.isFinite && p.y.isFinite && p.z.isFinite,
                "particle \(index) is not finite: \(p)"
            )
            let world = model * SIMD4<Float>(p.x, p.y, p.z, 1)
            XCTAssertGreaterThan(
                world.y, floorWorldY - 0.01,
                "particle \(index) fell through the floor (worldY \(world.y))"
            )
        }

        // After ~2.6 s of falling everything should be resting near the floor.
        let worldYs = particles.map { (model * SIMD4<Float>($0.x, $0.y, $0.z, 1)).y }
        let maxWorldY = worldYs.max() ?? 0
        XCTAssertLessThan(maxWorldY, floorWorldY + 0.3, "cloth did not fall to the floor")
    }

    func testRubberStretchesMoreThanDenim() throws {
        func lowestY(_ material: CoolClothMaterialParameters) throws -> Float {
            let sim = try runSimulation(
                model: matrix_identity_float4x4,
                pinMode: .topEdge,
                material: material,
                floorWorldY: -100,
                frames: 120
            )
            return readParticles(sim.current).map(\.y).min() ?? 0
        }

        let denimLow = try lowestY(CoolClothMaterialPreset.denim.parameters)
        let rubberLow = try lowestY(CoolClothMaterialPreset.rubber.parameters)

        XCTAssertLessThan(
            rubberLow, denimLow - 0.05,
            "rubber (\(rubberLow)) should hang lower than denim (\(denimLow))"
        )
    }

    func testNormalsAreUnitLengthAfterSettling() throws {
        let sim = try runSimulation(
            model: demoModel(),
            pinMode: .topEdge,
            material: CoolClothMaterialPreset.silk.parameters,
            floorWorldY: -1.2,
            frames: 30
        )
        let normals = readParticles(sim.nrm)
        for (index, value) in normals.enumerated() {
            let length = simd_length(SIMD3<Float>(value.x, value.y, value.z))
            XCTAssertEqual(length, 1, accuracy: 1e-3, "normal \(index) not unit: \(value)")
            XCTAssertTrue(value.w.isFinite && value.w > 0, "stretch ratio \(index): \(value.w)")
        }
    }

    // MARK: - Rendering smoke test

    func testClothRendersVisiblePixelsOffscreen() throws {
        // Simulate a couple of frames so positions/normals are realistic.
        let model = demoModel()
        let sim = try runSimulation(
            model: model,
            pinMode: .topEdge,
            material: CoolClothMaterialPreset.silk.parameters,
            floorWorldY: -1.2,
            frames: 10
        )

        let size = 256
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        let color = try XCTUnwrap(device.makeTexture(descriptor: colorDescriptor))
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = try XCTUnwrap(
            library.makeFunction(name: "coolClothVertex")
        )
        pipelineDescriptor.fragmentFunction = try XCTUnwrap(
            library.makeFunction(name: "coolClothFragment")
        )
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = .lessEqual
        depthStateDescriptor.isDepthWriteEnabled = true
        let depthState = try XCTUnwrap(
            device.makeDepthStencilState(descriptor: depthStateDescriptor)
        )

        // Camera at the origin (the demo places the cloth 1.2 m ahead, -z).
        let viewProj = simd_mul(
            perspective(fovYRadians: .pi / 3, aspect: 1, near: 0.05, far: 20),
            lookAt(
                eye: SIMD3<Float>(0, 0.5, 0.4),
                center: SIMD3<Float>(0, 0.4, -1.2),
                up: SIMD3<Float>(0, 1, 0)
            )
        )
        var uniforms = CoolClothSceneUniforms(
            viewProj: viewProj,
            model: model,
            eyeWorld: SIMD4<Float>(0, 0.5, 0.4, 0),
            lightWorld: SIMD4<Float>(0.6, 1.4, 0.8, 0.38),
            baseColorFront: SIMD4<Float>(0.62, 0.07, 0.13, 4),
            baseColorBack: SIMD4<Float>(0.42, 0.05, 0.10, 0),
            sheen: SIMD4<Float>(1.0, 0.75, 0.72, 0.35),
            sphere: SIMD4<Float>(0, 0, 0, 0.1),
            grid: SIMD4<UInt32>(UInt32(n), 0, 0, 0)
        )

        let geometry = CoolClothGridGeometry.make()
        let indexBuffer = try XCTUnwrap(geometry.indices.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count)
        })
        // 1x1 white fabric placeholder, like the extension's default.
        let fabricDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        fabricDescriptor.usage = [.shaderRead]
        fabricDescriptor.storageMode = .shared
        let fabric = try XCTUnwrap(device.makeTexture(descriptor: fabricDescriptor))
        var white: [UInt8] = [255, 255, 255, 255]
        fabric.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: &white, bytesPerRow: 4
        )

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = color
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        passDescriptor.depthAttachment.texture = depth
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .dontCare
        passDescriptor.depthAttachment.clearDepth = 1.0

        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(
            commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<CoolClothSceneUniforms>.stride,
            index: CoolClothSceneBufferIndex.uniforms.rawValue
        )
        encoder.setVertexTexture(
            sim.current,
            index: CoolClothSceneTextureIndex.position.rawValue
        )
        encoder.setVertexTexture(sim.nrm, index: CoolClothSceneTextureIndex.normal.rawValue)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<CoolClothSceneUniforms>.stride,
            index: CoolClothSceneBufferIndex.uniforms.rawValue
        )
        encoder.setFragmentTexture(fabric, index: CoolClothSceneTextureIndex.fabric.rawValue)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: CoolClothGridGeometry.indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { bytes in
            color.getBytes(
                bytes.baseAddress!,
                bytesPerRow: size * 4,
                from: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0
            )
        }
        let covered = stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] > 0 }
        let coverage = Float(covered) / Float(size * size)
        XCTAssertGreaterThan(
            coverage, 0.05,
            "cloth covered only \(coverage * 100)% of the offscreen frame"
        )
    }
}

// MARK: - Camera helpers

private func perspective(
    fovYRadians: Float, aspect: Float, near: Float, far: Float
) -> simd_float4x4 {
    let y = 1 / tan(fovYRadians * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, z * near, 0)
    )
}

private func lookAt(
    eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>
) -> simd_float4x4 {
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(
        SIMD4<Float>(s.x, u.x, -f.x, 0),
        SIMD4<Float>(s.y, u.y, -f.y, 0),
        SIMD4<Float>(s.z, u.z, -f.z, 0),
        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    )
}

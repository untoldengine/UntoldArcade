import Metal
import simd
import UntoldEngine

/// Rendering implementation owned by `CoolWaterPlugin`.
///
/// Owns the simulation, caustics, procedural scene geometry, pipelines, and
/// render-graph passes that make up the CoolWater renderer.
final class CoolWaterRenderExtension: RenderExtension, @unchecked Sendable {
    let id = CoolWaterPluginContract.extensionID
    private let encodeLock = NSLock()
    private var currentTextureIsA = true
    private var appliedResetGeneration: UInt64 = .max
    private var lastSphereCenter = SIMD3<Float>(-0.4, -0.75, 0.2)
    private var lastSphereRadius: Float = 0.25
    private var lightDirection = simd_normalize(SIMD3<Float>(2, 2, -1))
    private var gridInitialized = false
    private var sceneGeometryInitialized = false
    private var defaultTilesTexture: MTLTexture?
    private var defaultSkyTexture: MTLTexture?

    func registerShaderLibraries(_ registry: RenderShaderLibraryRegistry) {
        registry.registerLibrary(
            CoolWaterPluginContract.shaderLibraryID,
            bundle: .module,
            resource: CoolWaterPlatform.metallibResourceName
        )
    }

    func registerResources(_ registry: RenderResourceRegistry) {
        for (id, label) in [
            (CoolWaterPluginContract.simulationTextureAID, "CoolWater Simulation A"),
            (CoolWaterPluginContract.simulationTextureBID, "CoolWater Simulation B"),
        ] {
            registry.registerTexture(
                RenderExtensionTextureDescriptor(
                    id: id,
                    label: label,
                    size: .fixed(width: 256, height: 256),
                    pixelFormat: .rgba32Float,
                    usage: [.shaderRead, .shaderWrite],
                    storageMode: .shared
                )
            )
        }
        registry.registerTexture(
            RenderExtensionTextureDescriptor(
                id: CoolWaterPluginContract.causticsTextureID,
                label: "CoolWater Caustics",
                size: .fixed(width: 1024, height: 1024),
                pixelFormat: .rgba16Float,
                usage: [.renderTarget, .shaderRead]
            )
        )
        registry.registerBuffer(
            RenderExtensionBufferDescriptor(
                id: CoolWaterPluginContract.waterGridVertexBufferID,
                label: "CoolWater Grid Vertices",
                length: CoolWaterGridGeometry.vertexBufferLength
            )
        )
        registry.registerBuffer(
            RenderExtensionBufferDescriptor(
                id: CoolWaterPluginContract.poolVertexBufferID,
                label: "CoolWater Pool Vertices",
                length: CoolWaterSceneGeometry.poolBufferLength
            )
        )
        registry.registerBuffer(
            RenderExtensionBufferDescriptor(
                id: CoolWaterPluginContract.sphereVertexBufferID,
                label: "CoolWater Sphere Vertices",
                length: CoolWaterSceneGeometry.sphereBufferLength
            )
        )
        registry.registerBuffer(
            RenderExtensionBufferDescriptor(
                id: CoolWaterPluginContract.waterGridIndexBufferID,
                label: "CoolWater Grid Indices",
                length: CoolWaterGridGeometry.indexBufferLength
            )
        )
    }

    func registerPipelines(_ registry: RenderPipelineRegistry) {
        let library = RenderShaderLibraryReference.registered(
            CoolWaterPluginContract.shaderLibraryID
        )
        registry.registerRenderPipeline(
            RenderExtensionRenderPipelineDescriptor(
                id: CoolWaterPluginContract.causticsPipelineID,
                vertexFunction: "coolWaterCausticsVertex",
                fragmentFunction: "coolWaterCausticsFragment",
                vertexShaderLibrary: library,
                fragmentShaderLibrary: library,
                vertexDescriptor: nil,
                colorFormats: [.rgba16Float],
                depthFormat: .invalid,
                depthEnabled: false,
                reverseZCompatible: false,
                name: "CoolWater Caustics"
            )
        )
        registry.registerScenePipeline(
            CoolWaterPluginContract.poolPipelineID,
            vertexShader: "coolWaterPoolVertex",
            fragmentShader: "coolWaterPoolFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthEnabled: true,
            reverseZCompatible: true,
            blendMode: .alphaPremultiplied,
            name: "CoolWater Pool"
        )
        registry.registerScenePipeline(
            CoolWaterPluginContract.sphereRenderPipelineID,
            vertexShader: "coolWaterSphereVertex",
            fragmentShader: "coolWaterSphereFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthEnabled: true,
            reverseZCompatible: true,
            blendMode: .alphaPremultiplied,
            name: "CoolWater Sphere"
        )
        registry.registerScenePipeline(
            CoolWaterPluginContract.surfaceAbovePipelineID,
            vertexShader: "coolWaterSurfaceVertex",
            fragmentShader: "coolWaterSurfaceAboveFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthEnabled: true,
            reverseZCompatible: true,
            blendMode: .alphaPremultiplied,
            name: "CoolWater Surface Above"
        )
        registry.registerScenePipeline(
            CoolWaterPluginContract.surfaceBelowPipelineID,
            vertexShader: "coolWaterSurfaceVertex",
            fragmentShader: "coolWaterSurfaceBelowFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthEnabled: true,
            reverseZCompatible: true,
            blendMode: .alphaPremultiplied,
            name: "CoolWater Surface Below"
        )
        registry.registerScenePipeline(
            CoolWaterPluginContract.occlusionPipelineID,
            vertexShader: "coolWaterOcclusionVertex",
            fragmentShader: "coolWaterOcclusionFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthEnabled: true,
            reverseZCompatible: true,
            blendMode: .none,
            name: "CoolWater Real-Scene Occlusion"
        )
    }

    func registerComputePipelines(_ registry: ComputePipelineRegistry) {
        let library = RenderShaderLibraryReference.registered(
            CoolWaterPluginContract.shaderLibraryID
        )
        registry.registerComputePipeline(
            RenderExtensionComputePipelineDescriptor(
                id: CoolWaterPluginContract.dropPipelineID,
                function: "coolWaterDropKernel",
                shaderLibrary: library,
                name: "CoolWater Drop"
            )
        )
        registry.registerComputePipeline(
            RenderExtensionComputePipelineDescriptor(
                id: CoolWaterPluginContract.updatePipelineID,
                function: "coolWaterUpdateKernel",
                shaderLibrary: library,
                name: "CoolWater Wave Update"
            )
        )
        registry.registerComputePipeline(
            RenderExtensionComputePipelineDescriptor(
                id: CoolWaterPluginContract.normalPipelineID,
                function: "coolWaterNormalKernel",
                shaderLibrary: library,
                name: "CoolWater Normal Update"
            )
        )
        registry.registerComputePipeline(
            RenderExtensionComputePipelineDescriptor(
                id: CoolWaterPluginContract.spherePipelineID,
                function: "coolWaterSphereKernel",
                shaderLibrary: library,
                name: "CoolWater Sphere Displacement"
            )
        )
    }

    func buildGraph(
        _ builder: inout RenderGraphBuilder,
        context _: RenderGraphBuildContext
    ) {
        builder.addPass(
            id: CoolWaterPluginContract.simulationPassID,
            stage: .beforePostProcess,
            resources: [
                .texture(
                    CoolWaterPluginContract.simulationTextureAID,
                    access: [.read, .write]
                ),
                .texture(
                    CoolWaterPluginContract.simulationTextureBID,
                    access: [.read, .write]
                ),
            ]
        ) { [weak self] context in
            self?.encodeSimulation(context)
        }

        builder.addPass(
            id: CoolWaterPluginContract.causticsPassID,
            stage: .beforePostProcess,
            resources: [
                .texture(CoolWaterPluginContract.simulationTextureAID, access: .read),
                .texture(CoolWaterPluginContract.simulationTextureBID, access: .read),
                .texture(CoolWaterPluginContract.causticsTextureID, access: .renderTarget),
                .buffer(CoolWaterPluginContract.waterGridVertexBufferID, access: .read),
                .buffer(CoolWaterPluginContract.waterGridIndexBufferID, access: .read),
            ]
        ) { [weak self] context in
            self?.encodeCaustics(context)
        }

        builder.addPass(
            id: CoolWaterPluginContract.scenePassID,
            stage: .beforePostProcess,
            resources: [
                .texture(CoolWaterPluginContract.simulationTextureAID, access: .read),
                .texture(CoolWaterPluginContract.simulationTextureBID, access: .read),
                .texture(CoolWaterPluginContract.causticsTextureID, access: .read),
                .buffer(CoolWaterPluginContract.waterGridVertexBufferID, access: .read),
                .buffer(CoolWaterPluginContract.waterGridIndexBufferID, access: .read),
                .buffer(CoolWaterPluginContract.poolVertexBufferID, access: .read),
                .buffer(CoolWaterPluginContract.sphereVertexBufferID, access: .read),
            ]
        ) { [weak self] context in
            self?.encodeScene(context)
        }
    }

    private func encodeSimulation(_ context: RenderPassContext) {
        guard context.currentEye == 0,
              let textureA = context.resources.texture(
                  CoolWaterPluginContract.simulationTextureAID
              ),
              let textureB = context.resources.texture(
                  CoolWaterPluginContract.simulationTextureBID
              )
        else { return }

        encodeLock.withLock {
            let state = CoolWaterSimulation.shared.consumeFrameState()
            lightDirection = state.lightDirection

            if state.resetGeneration != appliedResetGeneration {
                clear(textureA)
                clear(textureB)
                currentTextureIsA = true
                lastSphereCenter = state.sphereCenter
                lastSphereRadius = state.sphereRadius
                appliedResetGeneration = state.resetGeneration
            }

            for drop in state.drops {
                encodeDrop(drop, context: context, textureA: textureA, textureB: textureB)
            }

            if state.sphereCenter != lastSphereCenter || state.sphereRadius != lastSphereRadius {
                encodeSphere(
                    oldCenter: lastSphereCenter,
                    newCenter: state.sphereCenter,
                    radius: state.sphereRadius,
                    context: context,
                    textureA: textureA,
                    textureB: textureB
                )
                lastSphereCenter = state.sphereCenter
                lastSphereRadius = state.sphereRadius
            }

            if !state.paused {
                encodeSimplePipeline(
                    CoolWaterPluginContract.updatePipelineID,
                    context: context,
                    textureA: textureA,
                    textureB: textureB
                )
                encodeSimplePipeline(
                    CoolWaterPluginContract.updatePipelineID,
                    context: context,
                    textureA: textureA,
                    textureB: textureB
                )
            }

            encodeSimplePipeline(
                CoolWaterPluginContract.normalPipelineID,
                context: context,
                textureA: textureA,
                textureB: textureB
            )
        }
    }

    private func textures(
        _ textureA: MTLTexture,
        _ textureB: MTLTexture
    ) -> (source: MTLTexture, destination: MTLTexture) {
        currentTextureIsA ? (textureA, textureB) : (textureB, textureA)
    }

    private func makeEncoder(
        pipelineID: ComputePipelineType,
        context: RenderPassContext,
        textureA: MTLTexture,
        textureB: MTLTexture
    ) -> (MTLComputeCommandEncoder, MTLComputePipelineState)? {
        guard let pipeline = context.computePipelines.pipeline(pipelineID)?.pipelineState,
              let encoder = context.commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        let pair = textures(textureA, textureB)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(pair.source, index: 0)
        encoder.setTexture(pair.destination, index: 1)
        return (encoder, pipeline)
    }

    private func finish(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState
    ) {
        let width = max(1, pipeline.threadExecutionWidth)
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: 256, height: 256, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
        currentTextureIsA.toggle()
    }

    private func encodeSimplePipeline(
        _ pipelineID: ComputePipelineType,
        context: RenderPassContext,
        textureA: MTLTexture,
        textureB: MTLTexture
    ) {
        guard let (encoder, pipeline) = makeEncoder(
            pipelineID: pipelineID,
            context: context,
            textureA: textureA,
            textureB: textureB
        ) else { return }
        finish(encoder, pipeline: pipeline)
    }

    private func encodeDrop(
        _ drop: CoolWaterSimulation.Drop,
        context: RenderPassContext,
        textureA: MTLTexture,
        textureB: MTLTexture
    ) {
        guard let (encoder, pipeline) = makeEncoder(
            pipelineID: CoolWaterPluginContract.dropPipelineID,
            context: context,
            textureA: textureA,
            textureB: textureB
        ) else { return }
        var center = drop.center
        var radius = drop.radius
        var strength = drop.strength
        encoder.setBytes(
            &center,
            length: MemoryLayout.size(ofValue: center),
            index: CoolWaterSimulationBufferIndex.dropCenter.rawValue
        )
        encoder.setBytes(
            &radius,
            length: MemoryLayout.size(ofValue: radius),
            index: CoolWaterSimulationBufferIndex.dropRadius.rawValue
        )
        encoder.setBytes(
            &strength,
            length: MemoryLayout.size(ofValue: strength),
            index: CoolWaterSimulationBufferIndex.dropStrength.rawValue
        )
        finish(encoder, pipeline: pipeline)
    }

    private func encodeSphere(
        oldCenter: SIMD3<Float>,
        newCenter: SIMD3<Float>,
        radius: Float,
        context: RenderPassContext,
        textureA: MTLTexture,
        textureB: MTLTexture
    ) {
        guard let (encoder, pipeline) = makeEncoder(
            pipelineID: CoolWaterPluginContract.spherePipelineID,
            context: context,
            textureA: textureA,
            textureB: textureB
        ) else { return }
        var oldCenter = oldCenter
        var newCenter = newCenter
        var radius = radius
        encoder.setBytes(
            &oldCenter,
            length: MemoryLayout.size(ofValue: oldCenter),
            index: CoolWaterSimulationBufferIndex.oldCenter.rawValue
        )
        encoder.setBytes(
            &newCenter,
            length: MemoryLayout.size(ofValue: newCenter),
            index: CoolWaterSimulationBufferIndex.newCenter.rawValue
        )
        encoder.setBytes(
            &radius,
            length: MemoryLayout.size(ofValue: radius),
            index: CoolWaterSimulationBufferIndex.sphereRadius.rawValue
        )
        finish(encoder, pipeline: pipeline)
    }

    private func clear(_ texture: MTLTexture) {
        let zeros = [SIMD4<Float>](repeating: .zero, count: 256 * 256)
        zeros.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, 256, 256),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: 256 * MemoryLayout<SIMD4<Float>>.stride
            )
        }
    }

    private func encodeCaustics(_ context: RenderPassContext) {
        guard context.currentEye == 0,
              let caustics = context.resources.texture(
                  CoolWaterPluginContract.causticsTextureID
              ),
              let textureA = context.resources.texture(
                  CoolWaterPluginContract.simulationTextureAID
              ),
              let textureB = context.resources.texture(
                  CoolWaterPluginContract.simulationTextureBID
              ),
              let vertexBuffer = context.resources.buffer(
                  CoolWaterPluginContract.waterGridVertexBufferID
              ),
              let indexBuffer = context.resources.buffer(
                  CoolWaterPluginContract.waterGridIndexBufferID
              ),
              let pipeline = context.renderPipelines.pipeline(
                  CoolWaterPluginContract.causticsPipelineID
              ),
              let pipelineState = pipeline.pipelineState
        else { return }

        encodeLock.withLock {
            initializeGridIfNeeded(vertices: vertexBuffer, indices: indexBuffer)

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = caustics
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = context.commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor
            ) else { return }

            var uniforms = CoolWaterSceneUniforms(
                mvp: matrix_identity_float4x4,
                eye: .zero,
                light: lightDirection,
                sphereCenter: lastSphereCenter,
                sphereRadius: lastSphereRadius
            )
            let waterTexture = currentTextureIsA ? textureA : textureB
            encoder.label = "CoolWater Caustics Pass"
            encoder.setRenderPipelineState(pipelineState)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(
                vertexBuffer,
                offset: 0,
                index: CoolWaterSceneBufferIndex.position.rawValue
            )
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<CoolWaterSceneUniforms>.stride,
                index: CoolWaterSceneBufferIndex.uniforms.rawValue
            )
            encoder.setVertexTexture(
                waterTexture,
                index: CoolWaterSceneTextureIndex.water.rawValue
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<CoolWaterSceneUniforms>.stride,
                index: CoolWaterSceneBufferIndex.uniforms.rawValue
            )
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: CoolWaterGridGeometry.indexCount,
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )
            encoder.endEncoding()
        }
    }

    private func initializeGridIfNeeded(vertices: MTLBuffer, indices: MTLBuffer) {
        guard !gridInitialized else { return }
        let geometry = CoolWaterGridGeometry.make()
        geometry.vertices.withUnsafeBytes { bytes in
            vertices.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        geometry.indices.withUnsafeBytes { bytes in
            indices.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        gridInitialized = true
    }

    private func encodeScene(_ context: RenderPassContext) {
        guard let textureA = context.resources.texture(CoolWaterPluginContract.simulationTextureAID),
              let textureB = context.resources.texture(CoolWaterPluginContract.simulationTextureBID),
              let caustics = context.resources.texture(CoolWaterPluginContract.causticsTextureID),
              let gridVertices = context.resources.buffer(CoolWaterPluginContract.waterGridVertexBufferID),
              let gridIndices = context.resources.buffer(CoolWaterPluginContract.waterGridIndexBufferID),
              let poolVertices = context.resources.buffer(CoolWaterPluginContract.poolVertexBufferID),
              let sphereVertices = context.resources.buffer(CoolWaterPluginContract.sphereVertexBufferID),
              let poolPipeline = context.renderPipelines.pipeline(CoolWaterPluginContract.poolPipelineID),
              let spherePipeline = context.renderPipelines.pipeline(CoolWaterPluginContract.sphereRenderPipelineID),
              let abovePipeline = context.renderPipelines.pipeline(CoolWaterPluginContract.surfaceAbovePipelineID),
              let belowPipeline = context.renderPipelines.pipeline(CoolWaterPluginContract.surfaceBelowPipelineID),
              let poolState = poolPipeline.pipelineState,
              let sphereState = spherePipeline.pipelineState,
              let aboveState = abovePipeline.pipelineState,
              let belowState = belowPipeline.pipelineState
        else { return }

        encodeLock.withLock {
            initializeGridIfNeeded(vertices: gridVertices, indices: gridIndices)
            initializeSceneGeometryIfNeeded(poolVertices: poolVertices, sphereVertices: sphereVertices)
            let appearance = CoolWaterAppearance.shared.state()
            ensureDefaultArt(device: context.device)
            guard let tiles = validTilesTexture(appearance.tilesTexture) ?? defaultTilesTexture,
                  let sky = validSkyTexture(appearance.skyTexture) ?? defaultSkyTexture,
                  let encoder = context.sceneRenderTargets.makeRenderCommandEncoder(
                      actions: .loadAndStore,
                      label: "CoolWater Scene Pass"
                  )
            else { return }
            defer { encoder.endEncoding() }

            let water = currentTextureIsA ? textureA : textureB
            let model = appearance.modelMatrix
            let localEye4 = simd_inverse(model) * SIMD4<Float>(context.camera.worldPosition, 1)
            var uniforms = CoolWaterSceneUniforms(
                mvp: context.camera.viewProjectionMatrix * model,
                eye: SIMD3<Float>(localEye4.x, localEye4.y, localEye4.z),
                light: lightDirection,
                sphereCenter: lastSphereCenter,
                sphereRadius: lastSphereRadius
            )

            encoder.pushDebugGroup("CoolWater Scene")
            defer { encoder.popDebugGroup() }
            encoder.useResource(tiles, usage: .read, stages: .fragment)
            encoder.useResource(sky, usage: .read, stages: .fragment)

            drawOcclusion(
                encoder,
                context: context,
                poolModelMatrix: model
            )

            func bindCommonFragmentTextures() {
                encoder.setFragmentBytes(
                    &uniforms,
                    length: MemoryLayout<CoolWaterSceneUniforms>.stride,
                    index: CoolWaterSceneBufferIndex.uniforms.rawValue
                )
                encoder.setFragmentTexture(water, index: CoolWaterSceneTextureIndex.water.rawValue)
                encoder.setFragmentTexture(tiles, index: CoolWaterSceneTextureIndex.tiles.rawValue)
                encoder.setFragmentTexture(caustics, index: CoolWaterSceneTextureIndex.caustics.rawValue)
                encoder.setFragmentTexture(sky, index: CoolWaterSceneTextureIndex.sky.rawValue)
            }

            encoder.setRenderPipelineState(poolState)
            encoder.setDepthStencilState(poolPipeline.depthState)
            encoder.setCullMode(.back)
            bindVertexState(encoder, buffer: poolVertices, uniforms: &uniforms)
            bindCommonFragmentTextures()
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: CoolWaterSceneGeometry.poolVertexCount
            )

            encoder.setRenderPipelineState(sphereState)
            encoder.setDepthStencilState(spherePipeline.depthState)
            encoder.setCullMode(.none)
            bindVertexState(encoder, buffer: sphereVertices, uniforms: &uniforms)
            bindCommonFragmentTextures()
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: CoolWaterSceneGeometry.sphereVertexCount
            )

            bindVertexState(encoder, buffer: gridVertices, uniforms: &uniforms)
            encoder.setVertexTexture(water, index: CoolWaterSceneTextureIndex.water.rawValue)
            bindCommonFragmentTextures()

            encoder.setRenderPipelineState(belowState)
            encoder.setDepthStencilState(belowPipeline.depthState)
            encoder.setCullMode(.back)
            drawGrid(encoder, indexBuffer: gridIndices)

            encoder.setRenderPipelineState(aboveState)
            encoder.setDepthStencilState(abovePipeline.depthState)
            encoder.setCullMode(.front)
            drawGrid(encoder, indexBuffer: gridIndices)
        }
    }

    private func bindVertexState(
        _ encoder: MTLRenderCommandEncoder,
        buffer: MTLBuffer,
        uniforms: inout CoolWaterSceneUniforms
    ) {
        encoder.setVertexBuffer(
            buffer,
            offset: 0,
            index: CoolWaterSceneBufferIndex.position.rawValue
        )
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<CoolWaterSceneUniforms>.stride,
            index: CoolWaterSceneBufferIndex.uniforms.rawValue
        )
    }

    private func drawOcclusion(
        _ encoder: MTLRenderCommandEncoder,
        context: RenderPassContext,
        poolModelMatrix: simd_float4x4
    ) {
        let meshes = CoolWaterOcclusionStore.shared.snapshot()
        guard !meshes.isEmpty,
              let pipeline = context.renderPipelines.pipeline(
                  CoolWaterPluginContract.occlusionPipelineID
              ),
              let pipelineState = pipeline.pipelineState
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(pipeline.depthState)
        encoder.setCullMode(.none)
        var inversePoolModel = simd_inverse(poolModelMatrix)
        encoder.setFragmentBytes(
            &inversePoolModel,
            length: MemoryLayout<simd_float4x4>.stride,
            index: 0
        )

        for mesh in meshes where mesh.indexCount > 0 && mesh.vertexStride > 0 {
            encoder.useResource(mesh.vertexBuffer, usage: .read, stages: .vertex)
            encoder.useResource(mesh.indexBuffer, usage: .read, stages: .vertex)
            var stride = UInt32(mesh.vertexStride)
            var offset = UInt32(max(0, mesh.vertexOffset))
            var mvp = context.camera.viewProjectionMatrix * mesh.transform
            var meshToWorld = mesh.transform
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&stride, length: MemoryLayout<UInt32>.stride, index: 1)
            encoder.setVertexBytes(&offset, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 3)
            encoder.setVertexBytes(
                &meshToWorld,
                length: MemoryLayout<simd_float4x4>.stride,
                index: 4
            )
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indexCount,
                indexType: mesh.indexType,
                indexBuffer: mesh.indexBuffer,
                indexBufferOffset: max(0, mesh.indexOffset)
            )
        }
    }

    private func drawGrid(_ encoder: MTLRenderCommandEncoder, indexBuffer: MTLBuffer) {
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: CoolWaterGridGeometry.indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }

    private func initializeSceneGeometryIfNeeded(
        poolVertices: MTLBuffer,
        sphereVertices: MTLBuffer
    ) {
        guard !sceneGeometryInitialized else { return }
        let geometry = CoolWaterSceneGeometry.make()
        geometry.poolVertices.withUnsafeBytes { bytes in
            poolVertices.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        geometry.sphereVertices.withUnsafeBytes { bytes in
            sphereVertices.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        sceneGeometryInitialized = true
    }

    private func ensureDefaultArt(device: MTLDevice) {
        if defaultTilesTexture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 1,
                height: 1,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            defaultTilesTexture = device.makeTexture(descriptor: descriptor)
            var color: [UInt8] = [220, 220, 225, 255]
            defaultTilesTexture?.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: &color,
                bytesPerRow: 4
            )
        }
        if defaultSkyTexture == nil {
            let descriptor = MTLTextureDescriptor.textureCubeDescriptor(
                pixelFormat: .rgba8Unorm,
                size: 1,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            defaultSkyTexture = device.makeTexture(descriptor: descriptor)
            var color: [UInt8] = [140, 190, 235, 255]
            for slice in 0 ..< 6 {
                defaultSkyTexture?.replace(
                    region: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0,
                    slice: slice,
                    withBytes: &color,
                    bytesPerRow: 4,
                    bytesPerImage: 4
                )
            }
        }
    }

    private func validTilesTexture(_ texture: MTLTexture?) -> MTLTexture? {
        texture?.textureType == .type2D ? texture : nil
    }

    private func validSkyTexture(_ texture: MTLTexture?) -> MTLTexture? {
        texture?.textureType == .typeCube ? texture : nil
    }
}

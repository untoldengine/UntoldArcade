import Metal
import simd
import UntoldEngine

/// Rendering implementation owned by `CoolClothPlugin`.
///
/// Owns the XPBD simulation dispatch, the cloth/ball/occlusion pipelines, and
/// the render-graph passes that make up the CoolCloth renderer.
final class CoolClothRenderExtension: RenderExtension, @unchecked Sendable {
    let id = CoolClothPluginContract.extensionID

    private static let gridSize = CoolClothSimulation.gridSize
    /// Rest distance between grid neighbors in cloth-local units (grid spans [-1,1]).
    private static let restSpacing = 2.0 / Float(gridSize - 1)

    private let encodeLock = NSLock()
    private var currentTextureIsA = true
    private var appliedResetGeneration: UInt64 = .max
    private var simulationTime: Float = 0
    private var geometryInitialized = false
    private var defaultFabricTexture: MTLTexture?
    private var lastLightDirection = simd_normalize(SIMD3<Float>(0.6, 1.4, 0.8))
    private var lastSphere = SIMD4<Float>(0, 0, 0, 0.12)
    private var pickingBuffer = [SIMD4<Float>](
        repeating: .zero,
        count: gridSize * gridSize
    )

    // One-shot diagnostics so a silently skipped pass is visible in the log.
    private var loggedSimulationPass = false
    private var loggedSimulationFailure = false
    private var loggedScenePass = false
    private var loggedSceneFailure = false
    private var loggedOcclusionMeshes = false

    private func logOnce(_ flag: inout Bool, _ message: String) {
        guard !flag else { return }
        flag = true
        print("CoolCloth: \(message)")
    }

    func registerShaderLibraries(_ registry: RenderShaderLibraryRegistry) {
        registry.registerLibrary(
            CoolClothPluginContract.shaderLibraryID,
            bundle: .module,
            resource: CoolClothPlatform.metallibResourceName
        )
    }

    func registerResources(_ registry: RenderResourceRegistry) {
        for (id, label) in [
            (CoolClothPluginContract.positionTextureAID, "CoolCloth Position A"),
            (CoolClothPluginContract.positionTextureBID, "CoolCloth Position B"),
            (CoolClothPluginContract.previousPositionTextureID, "CoolCloth Previous Position"),
            (CoolClothPluginContract.velocityTextureID, "CoolCloth Velocity"),
            (CoolClothPluginContract.normalTextureID, "CoolCloth Normal"),
        ] {
            registry.registerTexture(
                RenderExtensionTextureDescriptor(
                    id: id,
                    label: label,
                    size: .fixed(width: Self.gridSize, height: Self.gridSize),
                    pixelFormat: .rgba32Float,
                    usage: [.shaderRead, .shaderWrite],
                    storageMode: .shared
                )
            )
        }
        registry.registerBuffer(
            RenderExtensionBufferDescriptor(
                id: CoolClothPluginContract.clothIndexBufferID,
                label: "CoolCloth Grid Indices",
                length: CoolClothGridGeometry.indexBufferLength
            )
        )
        registry.registerBuffer(
            RenderExtensionBufferDescriptor(
                id: CoolClothPluginContract.ballVertexBufferID,
                label: "CoolCloth Ball Vertices",
                length: CoolClothGridGeometry.ballBufferLength
            )
        )
    }

    func registerPipelines(_ registry: RenderPipelineRegistry) {
        let library = RenderShaderLibraryReference.registered(
            CoolClothPluginContract.shaderLibraryID
        )
        registry.registerScenePipeline(
            CoolClothPluginContract.clothPipelineID,
            vertexShader: "coolClothVertex",
            fragmentShader: "coolClothFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthEnabled: true,
            reverseZCompatible: true,
            blendMode: .none,
            name: "CoolCloth Fabric"
        )
        registry.registerScenePipeline(
            CoolClothPluginContract.ballPipelineID,
            vertexShader: "coolClothBallVertex",
            fragmentShader: "coolClothBallFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthEnabled: true,
            reverseZCompatible: true,
            blendMode: .none,
            name: "CoolCloth Ball"
        )
        registry.registerScenePipeline(
            CoolClothPluginContract.occlusionPipelineID,
            vertexShader: "coolClothOcclusionVertex",
            fragmentShader: "coolClothOcclusionFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthEnabled: true,
            reverseZCompatible: true,
            blendMode: .none,
            name: "CoolCloth Real-Scene Occlusion"
        )
    }

    func registerComputePipelines(_ registry: ComputePipelineRegistry) {
        let library = RenderShaderLibraryReference.registered(
            CoolClothPluginContract.shaderLibraryID
        )
        for (id, function, name) in [
            (CoolClothPluginContract.initPipelineID, "coolClothInitKernel", "CoolCloth Init"),
            (CoolClothPluginContract.predictPipelineID, "coolClothPredictKernel", "CoolCloth Predict"),
            (CoolClothPluginContract.solvePipelineID, "coolClothSolveKernel", "CoolCloth Solve"),
            (CoolClothPluginContract.finalizePipelineID, "coolClothFinalizeKernel", "CoolCloth Finalize"),
            (CoolClothPluginContract.normalPipelineID, "coolClothNormalKernel", "CoolCloth Normals"),
        ] {
            registry.registerComputePipeline(
                RenderExtensionComputePipelineDescriptor(
                    id: id,
                    function: function,
                    shaderLibrary: library,
                    name: name
                )
            )
        }
    }

    func buildGraph(
        _ builder: inout RenderGraphBuilder,
        context _: RenderGraphBuildContext
    ) {
        builder.addPass(
            id: CoolClothPluginContract.simulationPassID,
            stage: .beforePostProcess,
            resources: [
                .texture(CoolClothPluginContract.positionTextureAID, access: [.read, .write]),
                .texture(CoolClothPluginContract.positionTextureBID, access: [.read, .write]),
                .texture(CoolClothPluginContract.previousPositionTextureID, access: [.read, .write]),
                .texture(CoolClothPluginContract.velocityTextureID, access: [.read, .write]),
                .texture(CoolClothPluginContract.normalTextureID, access: [.read, .write]),
            ]
        ) { [weak self] context in
            self?.encodeSimulation(context)
        }

        builder.addPass(
            id: CoolClothPluginContract.scenePassID,
            stage: .beforePostProcess,
            resources: [
                .texture(CoolClothPluginContract.positionTextureAID, access: .read),
                .texture(CoolClothPluginContract.positionTextureBID, access: .read),
                .texture(CoolClothPluginContract.normalTextureID, access: .read),
                .buffer(CoolClothPluginContract.clothIndexBufferID, access: .read),
                .buffer(CoolClothPluginContract.ballVertexBufferID, access: .read),
            ]
        ) { [weak self] context in
            self?.encodeScene(context)
        }
    }

    // MARK: - Simulation

    private struct SimTextures {
        let positionA: MTLTexture
        let positionB: MTLTexture
        let previous: MTLTexture
        let velocity: MTLTexture
        let normal: MTLTexture
    }

    private func simTextures(_ context: RenderPassContext) -> SimTextures? {
        guard let a = context.resources.texture(CoolClothPluginContract.positionTextureAID),
              let b = context.resources.texture(CoolClothPluginContract.positionTextureBID),
              let previous = context.resources.texture(
                  CoolClothPluginContract.previousPositionTextureID
              ),
              let velocity = context.resources.texture(CoolClothPluginContract.velocityTextureID),
              let normal = context.resources.texture(CoolClothPluginContract.normalTextureID)
        else { return nil }
        return SimTextures(
            positionA: a,
            positionB: b,
            previous: previous,
            velocity: velocity,
            normal: normal
        )
    }

    private func encodeSimulation(_ context: RenderPassContext) {
        guard context.currentEye == 0 else { return }
        guard let textures = simTextures(context) else {
            logOnce(&loggedSimulationFailure, "simulation pass: missing textures — NOT simulating")
            return
        }
        logOnce(&loggedSimulationPass, "simulation pass encoding (grid \(Self.gridSize)²)")

        encodeLock.withLock {
            let state = CoolClothSimulation.shared.consumeFrameState()
            let appearance = CoolClothAppearance.shared.state()
            lastLightDirection = state.lightDirection
            lastSphere = SIMD4<Float>(state.sphereCenterWorld, state.sphereRadius)

            let model = appearance.modelMatrix
            let invModel = simd_inverse(model)

            // Refresh the CPU picking snapshot from the last completed frame.
            snapshotPositions(from: currentSource(textures), model: model)

            var params = makeParams(state: state, model: model, invModel: invModel, dt: 0)

            if state.resetGeneration != appliedResetGeneration {
                encodeInit(context, textures: textures, params: params)
                appliedResetGeneration = state.resetGeneration
                simulationTime = 0
            }

            guard !state.paused else { return }

            let frameDelta = min(max(state.deltaTime, 1.0 / 240.0), 1.0 / 30.0)
            let substepDelta = frameDelta / Float(state.substeps)
            params.gravityDt.w = substepDelta

            for _ in 0 ..< state.substeps {
                params.misc.z = simulationTime
                encodePredict(context, textures: textures, params: params)
                for _ in 0 ..< state.iterations {
                    encodeSolve(context, textures: textures, params: params)
                }
                encodeFinalize(context, textures: textures, params: params)
                simulationTime += substepDelta
            }
            encodeNormals(context, textures: textures, params: params)
        }
    }

    private func makeParams(
        state: CoolClothSimulation.FrameState,
        model: simd_float4x4,
        invModel: simd_float4x4,
        dt: Float
    ) -> CoolClothSimParams {
        let grabTargetLocal: SIMD3<Float>
        if let grab = state.grab {
            let local = invModel * SIMD4<Float>(grab.targetWorld, 1)
            grabTargetLocal = SIMD3<Float>(local.x, local.y, local.z)
        } else {
            grabTargetLocal = .zero
        }
        return CoolClothSimParams(
            model: model,
            invModel: invModel,
            gravityDt: SIMD4<Float>(state.gravityWorld, dt),
            wind: SIMD4<Float>(state.windWorld, state.gustiness),
            sphere: SIMD4<Float>(state.sphereCenterWorld, state.sphereRadius),
            grabTarget: SIMD4<Float>(grabTargetLocal, state.floorWorldY),
            compliance: SIMD4<Float>(
                state.material.stretchCompliance,
                state.material.shearCompliance,
                state.material.bendCompliance,
                state.relaxation
            ),
            misc: SIMD4<Float>(
                state.material.damping,
                Self.restSpacing,
                simulationTime,
                state.maxSpeed
            ),
            flags: SIMD4<UInt32>(
                state.pinMode.rawValue,
                state.grab != nil ? 1 : 0,
                state.sphereActive ? 1 : 0,
                0
            ),
            grab: SIMD4<UInt32>(
                UInt32(state.grab?.column ?? 0),
                UInt32(state.grab?.row ?? 0),
                grabRadiusInParticles(state.grabRadiusWorld, model: model),
                0
            )
        )
    }

    /// Converts the world-space grab radius into simulation-grid units using
    /// the cloth's current uniform scale.
    private func grabRadiusInParticles(_ worldRadius: Float, model: simd_float4x4) -> UInt32 {
        let scale = simd_length(
            SIMD3<Float>(model.columns.0.x, model.columns.0.y, model.columns.0.z)
        )
        let localRadius = worldRadius / max(scale, 1e-4)
        let particles = (localRadius / Self.restSpacing).rounded()
        return UInt32(min(max(particles, 1), 32))
    }

    private func currentSource(_ textures: SimTextures) -> MTLTexture {
        currentTextureIsA ? textures.positionA : textures.positionB
    }

    private func currentDestination(_ textures: SimTextures) -> MTLTexture {
        currentTextureIsA ? textures.positionB : textures.positionA
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState
    ) {
        let width = max(1, pipeline.threadExecutionWidth)
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: Self.gridSize, height: Self.gridSize, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
    }

    private func makeEncoder(
        _ pipelineID: ComputePipelineType,
        context: RenderPassContext,
        params: inout CoolClothSimParams
    ) -> (MTLComputeCommandEncoder, MTLComputePipelineState)? {
        guard let pipeline = context.computePipelines.pipeline(pipelineID)?.pipelineState,
              let encoder = context.commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(
            &params,
            length: MemoryLayout<CoolClothSimParams>.stride,
            index: CoolClothSimBufferIndex.params.rawValue
        )
        return (encoder, pipeline)
    }

    private func encodeInit(
        _ context: RenderPassContext,
        textures: SimTextures,
        params: CoolClothSimParams
    ) {
        var params = params
        currentTextureIsA = true
        guard let (encoder, pipeline) = makeEncoder(
            CoolClothPluginContract.initPipelineID,
            context: context,
            params: &params
        ) else { return }
        encoder.setTexture(currentSource(textures), index: 0)
        encoder.setTexture(textures.previous, index: 1)
        encoder.setTexture(textures.velocity, index: 2)
        encoder.setTexture(textures.normal, index: 3)
        dispatch(encoder, pipeline: pipeline)
    }

    private func encodePredict(
        _ context: RenderPassContext,
        textures: SimTextures,
        params: CoolClothSimParams
    ) {
        var params = params
        guard let (encoder, pipeline) = makeEncoder(
            CoolClothPluginContract.predictPipelineID,
            context: context,
            params: &params
        ) else { return }
        encoder.setTexture(currentSource(textures), index: 0)
        encoder.setTexture(currentDestination(textures), index: 1)
        encoder.setTexture(textures.previous, index: 2)
        encoder.setTexture(textures.velocity, index: 3)
        encoder.setTexture(textures.normal, index: 4)
        dispatch(encoder, pipeline: pipeline)
        currentTextureIsA.toggle()
    }

    private func encodeSolve(
        _ context: RenderPassContext,
        textures: SimTextures,
        params: CoolClothSimParams
    ) {
        var params = params
        guard let (encoder, pipeline) = makeEncoder(
            CoolClothPluginContract.solvePipelineID,
            context: context,
            params: &params
        ) else { return }
        encoder.setTexture(currentSource(textures), index: 0)
        encoder.setTexture(currentDestination(textures), index: 1)
        encoder.setTexture(textures.previous, index: 2)
        dispatch(encoder, pipeline: pipeline)
        currentTextureIsA.toggle()
    }

    private func encodeFinalize(
        _ context: RenderPassContext,
        textures: SimTextures,
        params: CoolClothSimParams
    ) {
        var params = params
        guard let (encoder, pipeline) = makeEncoder(
            CoolClothPluginContract.finalizePipelineID,
            context: context,
            params: &params
        ) else { return }
        encoder.setTexture(currentSource(textures), index: 0)
        encoder.setTexture(textures.previous, index: 1)
        encoder.setTexture(textures.velocity, index: 2)
        dispatch(encoder, pipeline: pipeline)
    }

    private func encodeNormals(
        _ context: RenderPassContext,
        textures: SimTextures,
        params: CoolClothSimParams
    ) {
        var params = params
        guard let (encoder, pipeline) = makeEncoder(
            CoolClothPluginContract.normalPipelineID,
            context: context,
            params: &params
        ) else { return }
        encoder.setTexture(currentSource(textures), index: 0)
        encoder.setTexture(textures.normal, index: 1)
        dispatch(encoder, pipeline: pipeline)
    }

    /// Copies the latest particle positions (shared storage) into the CPU-side
    /// picking store. Reads the previous frame's result, which is complete by
    /// the time the next frame is encoded.
    private func snapshotPositions(from texture: MTLTexture, model: simd_float4x4) {
        let n = Self.gridSize
        pickingBuffer.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: n * MemoryLayout<SIMD4<Float>>.stride,
                from: MTLRegionMake2D(0, 0, n, n),
                mipmapLevel: 0
            )
        }
        CoolClothPickingStore.shared.update(
            positions: pickingBuffer,
            gridSize: n,
            modelMatrix: model
        )
    }

    // MARK: - Scene

    private func encodeScene(_ context: RenderPassContext) {
        // Only the resources DECLARED for this pass resolve here — the scene pass
        // declares positions A/B and normals, not the whole simulation set.
        guard let positionA = context.resources.texture(
                  CoolClothPluginContract.positionTextureAID
              ),
              let positionB = context.resources.texture(
                  CoolClothPluginContract.positionTextureBID
              ),
              let normalTexture = context.resources.texture(
                  CoolClothPluginContract.normalTextureID
              ),
              let indexBuffer = context.resources.buffer(
                  CoolClothPluginContract.clothIndexBufferID
              ),
              let ballVertices = context.resources.buffer(
                  CoolClothPluginContract.ballVertexBufferID
              ),
              let clothPipeline = context.renderPipelines.pipeline(
                  CoolClothPluginContract.clothPipelineID
              ),
              let ballPipeline = context.renderPipelines.pipeline(
                  CoolClothPluginContract.ballPipelineID
              ),
              let clothState = clothPipeline.pipelineState,
              let ballState = ballPipeline.pipelineState
        else {
            logOnce(
                &loggedSceneFailure,
                "scene pass: missing resource or pipeline — NOT drawing. "
                    + "posA=\(context.resources.texture(CoolClothPluginContract.positionTextureAID) != nil) "
                    + "posB=\(context.resources.texture(CoolClothPluginContract.positionTextureBID) != nil) "
                    + "normal=\(context.resources.texture(CoolClothPluginContract.normalTextureID) != nil) "
                    + "indexBuffer=\(context.resources.buffer(CoolClothPluginContract.clothIndexBufferID) != nil) "
                    + "ballBuffer=\(context.resources.buffer(CoolClothPluginContract.ballVertexBufferID) != nil) "
                    + "clothPipeline=\(context.renderPipelines.pipeline(CoolClothPluginContract.clothPipelineID)?.pipelineState != nil) "
                    + "ballPipeline=\(context.renderPipelines.pipeline(CoolClothPluginContract.ballPipelineID)?.pipelineState != nil)"
            )
            return
        }

        encodeLock.withLock {
            initializeGeometryIfNeeded(indexBuffer: indexBuffer, ballBuffer: ballVertices)
            ensureDefaultFabric(device: context.device)
            let appearance = CoolClothAppearance.shared.state()
            guard let fabric = appearance.fabricTexture ?? defaultFabricTexture,
                  let encoder = context.sceneRenderTargets.makeRenderCommandEncoder(
                      actions: .loadAndStore,
                      label: "CoolCloth Scene Pass"
                  )
            else {
                logOnce(&loggedSceneFailure, "scene pass: no fabric texture or scene encoder — NOT drawing")
                return
            }
            defer { encoder.endEncoding() }

            let eye = context.camera.worldPosition
            let cloth = appearance.modelMatrix.columns.3
            logOnce(
                &loggedScenePass,
                String(
                    format: "scene pass drawing — camera (%.2f, %.2f, %.2f), cloth center (%.2f, %.2f, %.2f)",
                    eye.x, eye.y, eye.z, cloth.x, cloth.y, cloth.z
                )
            )

            let positions = currentTextureIsA ? positionA : positionB
            var uniforms = CoolClothSceneUniforms(
                viewProj: context.camera.viewProjectionMatrix,
                model: appearance.modelMatrix,
                eyeWorld: SIMD4<Float>(context.camera.worldPosition, 0),
                lightWorld: SIMD4<Float>(lastLightDirection, appearance.ambient),
                baseColorFront: SIMD4<Float>(appearance.frontColor, appearance.fabricTiling),
                baseColorBack: SIMD4<Float>(appearance.backColor, 0),
                sheen: SIMD4<Float>(appearance.sheenColor, appearance.sheenIntensity),
                sphere: lastSphere,
                grid: SIMD4<UInt32>(
                    UInt32(Self.gridSize),
                    appearance.ballVisible ? 1 : 0,
                    appearance.fabricTexture != nil ? 1 : 0,
                    0
                )
            )

            encoder.pushDebugGroup("CoolCloth Scene")
            defer { encoder.popDebugGroup() }

            drawOcclusion(encoder, context: context)

            encoder.setRenderPipelineState(clothState)
            encoder.setDepthStencilState(clothPipeline.depthState)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<CoolClothSceneUniforms>.stride,
                index: CoolClothSceneBufferIndex.uniforms.rawValue
            )
            encoder.setVertexTexture(
                positions,
                index: CoolClothSceneTextureIndex.position.rawValue
            )
            encoder.setVertexTexture(
                normalTexture,
                index: CoolClothSceneTextureIndex.normal.rawValue
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<CoolClothSceneUniforms>.stride,
                index: CoolClothSceneBufferIndex.uniforms.rawValue
            )
            encoder.setFragmentTexture(
                fabric,
                index: CoolClothSceneTextureIndex.fabric.rawValue
            )
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: CoolClothGridGeometry.indexCount,
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )

            if appearance.ballVisible {
                encoder.setRenderPipelineState(ballState)
                encoder.setDepthStencilState(ballPipeline.depthState)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(
                    ballVertices,
                    offset: 0,
                    index: CoolClothSceneBufferIndex.position.rawValue
                )
                encoder.setVertexBytes(
                    &uniforms,
                    length: MemoryLayout<CoolClothSceneUniforms>.stride,
                    index: CoolClothSceneBufferIndex.uniforms.rawValue
                )
                encoder.setFragmentBytes(
                    &uniforms,
                    length: MemoryLayout<CoolClothSceneUniforms>.stride,
                    index: CoolClothSceneBufferIndex.uniforms.rawValue
                )
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: CoolClothGridGeometry.ballVertexCount
                )
            }
        }
    }

    private func drawOcclusion(
        _ encoder: MTLRenderCommandEncoder,
        context: RenderPassContext
    ) {
        let meshes = CoolClothOcclusionStore.shared.snapshot()
        guard !meshes.isEmpty,
              let pipeline = context.renderPipelines.pipeline(
                  CoolClothPluginContract.occlusionPipelineID
              ),
              let pipelineState = pipeline.pipelineState
        else { return }
        logOnce(&loggedOcclusionMeshes, "drawing \(meshes.count) real-scene occlusion meshes")

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(pipeline.depthState)
        encoder.setCullMode(.none)

        for mesh in meshes where mesh.indexCount > 0 && mesh.vertexStride > 0 {
            encoder.useResource(mesh.vertexBuffer, usage: .read, stages: .vertex)
            encoder.useResource(mesh.indexBuffer, usage: .read, stages: .vertex)
            var stride = UInt32(mesh.vertexStride)
            var offset = UInt32(max(0, mesh.vertexOffset))
            var mvp = context.camera.viewProjectionMatrix * mesh.transform
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&stride, length: MemoryLayout<UInt32>.stride, index: 1)
            encoder.setVertexBytes(&offset, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 3)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indexCount,
                indexType: mesh.indexType,
                indexBuffer: mesh.indexBuffer,
                indexBufferOffset: max(0, mesh.indexOffset)
            )
        }
    }

    private func initializeGeometryIfNeeded(indexBuffer: MTLBuffer, ballBuffer: MTLBuffer) {
        guard !geometryInitialized else { return }
        let geometry = CoolClothGridGeometry.make()
        geometry.indices.withUnsafeBytes { bytes in
            indexBuffer.contents().copyMemory(
                from: bytes.baseAddress!,
                byteCount: bytes.count
            )
        }
        geometry.ballVertices.withUnsafeBytes { bytes in
            ballBuffer.contents().copyMemory(
                from: bytes.baseAddress!,
                byteCount: bytes.count
            )
        }
        geometryInitialized = true
    }

    private func ensureDefaultFabric(device: MTLDevice) {
        guard defaultFabricTexture == nil else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        defaultFabricTexture = device.makeTexture(descriptor: descriptor)
        var color: [UInt8] = [255, 255, 255, 255]
        defaultFabricTexture?.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &color,
            bytesPerRow: 4
        )
    }
}

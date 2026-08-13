import Foundation
import Metal
import simd
import UntoldEngine

/// Rendering implementation owned by `CoolSaberPlugin`.
///
/// Render-only: one scene pass at `.beforePostProcess` draws every blade and
/// spark in a single additive draw call over the engine's HDR scene targets.
/// The engine executes the graph once per eye, so nothing here is eye-aware.
final class CoolSaberRenderExtension: RenderExtension, @unchecked Sendable {
    let id = CoolSaberPluginContract.extensionID

    private let encodeLock = NSLock()

    // One-shot diagnostics so a silently skipped pass is visible in the log.
    private var loggedScenePass = false
    private var loggedSceneFailure = false

    private func logOnce(_ flag: inout Bool, _ message: String) {
        guard !flag else { return }
        flag = true
        print("CoolSaber: \(message)")
    }

    func registerShaderLibraries(_ registry: RenderShaderLibraryRegistry) {
        registry.registerLibrary(
            CoolSaberPluginContract.shaderLibraryID,
            bundle: .module,
            resource: CoolSaberPlatform.metallibResourceName
        )
    }

    func registerPipelines(_ registry: RenderPipelineRegistry) {
        let library = RenderShaderLibraryReference.registered(
            CoolSaberPluginContract.shaderLibraryID
        )
        // depthEnabled false = no depth WRITE (glow must not occlude); depth
        // testing stays on so engine geometry still hides the blade correctly.
        registry.registerScenePipeline(
            CoolSaberPluginContract.bladePipelineID,
            vertexShader: "coolSaberBladeVertex",
            fragmentShader: "coolSaberBladeFragment",
            vertexShaderLibrary: library,
            fragmentShaderLibrary: library,
            depthCompareFunction: .lessEqual,
            depthEnabled: false,
            reverseZCompatible: true,
            blendMode: .additive,
            name: "CoolSaber Blades"
        )
    }

    func buildGraph(
        _ builder: inout RenderGraphBuilder,
        context _: RenderGraphBuildContext
    ) {
        builder.addPass(
            id: CoolSaberPluginContract.scenePassID,
            stage: .beforePostProcess,
            resources: []
        ) { [weak self] context in
            self?.encodeScene(context)
        }
    }

    private func encodeScene(_ context: RenderPassContext) {
        guard let pipeline = context.renderPipelines.pipeline(
                  CoolSaberPluginContract.bladePipelineID
              ),
              let pipelineState = pipeline.pipelineState
        else {
            logOnce(&loggedSceneFailure, "scene pass: blade pipeline missing — NOT drawing")
            return
        }

        encodeLock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            CoolSaberSceneState.shared.pruneSparks(now: now)
            let state = CoolSaberSceneState.shared.state()

            var uniforms = CoolSaberUniforms()
            uniforms.viewProj = context.camera.viewProjectionMatrix
            uniforms.cameraWorld = SIMD4<Float>(
                context.camera.worldPosition,
                Float(now.truncatingRemainder(dividingBy: 3600))
            )

            var visibleBlades = 0
            for (index, blade) in state.blades.enumerated() {
                guard let blade, blade.length >= 0.005 else { continue }
                var gpu = CoolSaberBladeGPU()
                gpu.hilt = SIMD4<Float>(blade.hilt, blade.radius)
                gpu.direction = SIMD4<Float>(blade.direction, blade.length)
                gpu.color = SIMD4<Float>(blade.color, blade.glowIntensity)
                uniforms.setBlade(index, gpu)
                visibleBlades += 1
            }

            var sparkCount = 0
            for spark in state.sparks.prefix(CoolSaberShaderLimits.maxSparks) {
                let age = Float(now - spark.spawnUptime)
                let life = Float(CoolSaberSceneState.sparkLifetime)
                let t = simd_clamp(age / life, 0, 1)
                var gpu = CoolSaberSparkGPU()
                // Expands while it dims: r 4→14 cm, intensity quadratic falloff.
                gpu.position = SIMD4<Float>(spark.position, 0.04 + 0.10 * t)
                gpu.color = SIMD4<Float>(spark.color, spark.intensity * (1 - t) * (1 - t))
                uniforms.setSpark(sparkCount, gpu)
                sparkCount += 1
            }

            guard visibleBlades > 0 || sparkCount > 0 else { return }
            uniforms.counts = SIMD4<UInt32>(
                UInt32(CoolSaberShaderLimits.maxBlades),
                UInt32(sparkCount),
                0, 0
            )

            guard let encoder = context.sceneRenderTargets.makeRenderCommandEncoder(
                actions: .loadAndStore,
                label: "CoolSaber Scene Pass"
            ) else {
                logOnce(&loggedSceneFailure, "scene pass: no scene encoder — NOT drawing")
                return
            }
            defer { encoder.endEncoding() }

            logOnce(
                &loggedScenePass,
                String(
                    format: "scene pass drawing — %d blade(s), camera (%.2f, %.2f, %.2f)",
                    visibleBlades,
                    context.camera.worldPosition.x,
                    context.camera.worldPosition.y,
                    context.camera.worldPosition.z
                )
            )

            encoder.pushDebugGroup("CoolSaber Blades")
            defer { encoder.popDebugGroup() }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setDepthStencilState(pipeline.depthState)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<CoolSaberUniforms>.stride,
                index: CoolSaberBufferIndex.uniforms.rawValue
            )

            let quadCount = CoolSaberShaderLimits.maxBlades + CoolSaberShaderLimits.maxSparks
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: quadCount * 6
            )
        }
    }
}

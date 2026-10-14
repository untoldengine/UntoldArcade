//
//  EngineSession.swift
//  Untold Viewer
//
//  The engine side: owns the XR runtime and its render thread for the
//  "Engine" immersive space, builds the catalog's selected objects at the
//  shared layout, and publishes per-frame diagnostics for the Controls window.
//

import CompositorServices
import Foundation
import MetalPerformanceShaders
import os
import UntoldEngine
import UntoldEngineXR

/// A pass's GPU milliseconds: a render pass's vertex and fragment stages; a compute or blit
/// pass has only the fragment part.
/// The CPU side of a frame, in milliseconds: the render loop's period and its three phases.
struct CPUMilliseconds: Equatable {
    var loop = 0.0
    var update = 0.0
    var wait = 0.0
    var encode = 0.0

    /// This average moved towards `sample` by a `window`th of the difference (the first sample
    /// taken whole).
    func averaged(with sample: CPUMilliseconds, window: Double) -> CPUMilliseconds {
        func move(_ average: Double, _ value: Double) -> Double { average == 0 ? value : average + (value - average) / window }
        return CPUMilliseconds(loop: move(loop, sample.loop), update: move(update, sample.update), wait: move(wait, sample.wait), encode: move(encode, sample.encode))
    }
}

struct PassMilliseconds: Equatable {
    var vertex = 0.0
    var fragment = 0.0
    var total: Double { vertex + fragment }
}

struct EngineDiagnostics: Sendable, Equatable {
    var frames: UInt64 = 0
    var object = ""
    /// The engine's anti-aliasing mode and the opaque sample count it settled on.
    var antiAliasing = ""
    var opaqueSampleCount = 0
    /// Per-eye drawable size, and with foveation the screen size behind it.
    var viewport = SIMD2<Int>(0, 0)
    var screenSize = SIMD2<Int>(0, 0)
    /// GPU time per frame, a moving average over about a second (debug
    /// builds; 0 in release).
    var gpuMilliseconds: Double = 0
    /// The same for the frames before the object was placed: the cost of the
    /// empty space (passes, resolves, the compositor's work), so that the
    /// difference is the object's own cost. 0 until the object is placed.
    var emptyGpuMilliseconds: Double = 0
    /// The interval between the GPU's frame completions, the same two averages: the frame
    /// period the compositor paces the engine at (11.1 ms at 90 fps, 22.2 at 45, 33.3 at 30).
    var cadenceMilliseconds: Double = 0
    var emptyCadenceMilliseconds: Double = 0
    /// The CPU side of the frame, the same two averages: the render loop's period, and its
    /// update phase, its wait for the compositor's optimal input time (pacing, not work) and
    /// its submission phase (the eyes encoded and committed).
    var cpu = CPUMilliseconds()
    var emptyCpu = CPUMilliseconds()
    /// Whether the engine was compiled optimized. An unoptimized engine (the Debug
    /// configuration's default for the package) is CPU-bound on the headset, and its
    /// numbers measure the compiler, not the renderer.
    var engineOptimized = true
    /// The sun shadow's taps per fragment, as set in the viewer (the engine has no getter).
    var shadowTaps = 8
    /// Whether the viewer's sun was placed when the space opened.
    var sun = true
    /// The room estimate's light as the engine applies it: its intensity scale (the probe's
    /// camera scale reference over the engine's white point), that reference, and the factor
    /// the viewer puts on it. Zero when the room estimate is off.
    var roomLightScale: Float = 0
    var roomLightCameraReference: Float = 0
    var roomLightFactor: Float = 1
    /// The scale as published to the renderer (smoothed), the probe texture ARKit hands over
    /// (format, size, mips) and how many prefiltered probes have been published.
    var roomLightPublished: Float = 0
    var probe = ""
    var probePublishes = 0
    /// How many probe updates ARKit delivered that the engine accepted and skipped, and how
    /// long ago the last accepted one arrived: whether the room light follows the room.
    var probeAccepted = 0
    var probeSkipped = 0
    var probeAge: Double = 0
    /// The mean luminance of the probe's six faces (+x, −x, +y, −y, +z, −z): where the room's
    /// light is in the probe's frame.
    var probeFaces: [Float] = []
    /// Whether the scene is shown with the display's P3 primaries, as set in the viewer.
    var wideGamut = true
    /// The look pass's tone map, as set in the viewer.
    var toneMap = "none"
    /// The texture streaming's counters: tier upgrades and downgrades so far, the entities at
    /// their full tier, the operations in flight; and the texture memory used of the budget.
    var textureUpgrades = 0
    var textureDowngrades = 0
    var textureEntitiesAtFull = 0
    var textureOpsInFlight = 0
    var textureMemoryUsedMB = 0
    var textureBudgetMB = 0
    /// Seconds into the debug tour's loop, or nil when the object stands still.
    var tourTime: Double?
    /// Refreshes at which the display showed the previous frame again because the engine's
    /// next was not ready, over all frames: the fps shortfall. And the frames whose final
    /// presentation time differed from the one predicted at the update, which the tour's
    /// pose was taken at.
    var skippedFrames = 0
    var presentationRevisions = 0
    /// The frame's draw calls and triangles, from the engine's own counters.
    var drawCalls = 0
    var triangles = 0
    /// Over the frames with the object: the fewest and the most opaque draws a frame made, and
    /// the most batched draws. A frame that skips a part shows as a dip in the first.
    var opaqueDrawsLeast = 0
    var opaqueDrawsMost = 0
    var batchedDrawsMost = 0
    /// The depth buffer's format (the layer's) and the camera's near plane: what the depth
    /// test can tell apart at a distance.
    var depthFormat = ""
    var nearPlane: Float = 0
    /// Whether the engine skipped the pre-composite pass this frame (a passthrough frame with
    /// no layer to join: the look pass reads the lit scene directly).
    var compositeSkipped = false
    /// Whether the engine lit the frame through the tile light stage (false: the quad, once
    /// per sample — the stage is off, or Metal refused its imageblock at this sample count).
    var tileLightStage = false
    /// The last pass's opaque draws through the plain model pipeline (no discards: hidden
    /// fragments never shaded) and through the general one.
    var plainDraws = 0
    var discardingDraws = 0
    /// Whether the open space renders through the compositor's rate maps.
    var foveation = true
    /// The mesh entities the frame's culling put to the occlusion test: with fewer than the
    /// engine's minimum (two), no depth pyramid is built.
    var cullCandidates = 0
    /// The render path the pipelines were built for: "forward" (the geometry lights itself
    /// whole per fragment), "hybrid" (the indirect light per fragment, the light pass for the
    /// direct) or "deferred" (the light pass lights everything).
    var renderPath = "forward"
    /// The diagnostic switches and the lighting mode the pass ran with, as set in the viewer.
    var occlusionCull = true
    var taaJitter = true
    var textureStreaming = true
    var lighting = "room"
    /// The frames with the object whose picture's mean brightness fell by more than a third
    /// from the frame before (the object's face culled, its light gone), and the tour's time
    /// of the first few.
    var darkFrames = 0
    var darkFrameTimes: [Double] = []
    /// GPU milliseconds per pass, averaged like `gpuMilliseconds`, with the object and in the
    /// empty space: label → (vertex, fragment) for render passes; compute and blit passes have
    /// only the fragment part. Empty when the engine's pass timing is off.
    var passMilliseconds: [String: PassMilliseconds] = [:]
    var emptyPassMilliseconds: [String: PassMilliseconds] = [:]

    /// What the object adds on top of the empty space, when both are known.
    var objectGpuMilliseconds: Double? {
        emptyGpuMilliseconds > 0 && gpuMilliseconds > 0 ? gpuMilliseconds - emptyGpuMilliseconds : nil
    }
}

final class EngineSession: @unchecked Sendable {
    static let shared = EngineSession()
    static let log = Logger(subsystem: "com.untoldengine.untoldviewer", category: "engine")

    var xr: UntoldEngineXR?
    var renderThread: Thread?
    var isOpen = false
    var lastOpenResult = "—"

    private let lock = NSLock()
    private var diagnosticsStorage = EngineDiagnostics()
    private var frames: UInt64 = 0
    /// Refreshes the display skipped over those frames (the previous frame shown again).
    private var skippedFrames = 0
    private var objectName = ""
    private var phase: OSSignpostIntervalState?
    /// Exponential moving averages of the GPU time: all frames, and the frames before the object.
    private var gpuAverage = 0.0
    private var emptyGpuAverage = 0.0
    private var passAverages: [String: PassMilliseconds] = [:]
    private var emptyPassAverages: [String: PassMilliseconds] = [:]
    private var lastPassFrame = 0
    private var cadenceAverage = 0.0
    private var emptyCadenceAverage = 0.0
    private var cpuAverage = CPUMilliseconds()
    private var emptyCpuAverage = CPUMilliseconds()
    private var opaqueDrawsLeast = Int.max
    private var opaqueDrawsMost = 0
    private var batchedDrawsMost = 0
    private var emptyFrames = 0
    /// The brightness probe: the mean of the last frame's resolved picture, read back a frame
    /// later, and the drops it found.
    private var probe: (mean: MPSImageStatisticsMean, destination: MTLTexture)?
    private var probeInFlight = false
    private var lastLuminance = 0.0
    private var darkFrames = 0
    private var darkFrameTimes: [Double] = []
    /// The placed object: its entity, its (draggable) placement, and when it was placed.
    private var object: (entity: EntityID, placement: Catalog.Placement, placed: TimeInterval)?
    /// A pinch-drag in progress: the hand, the object's centre and its distance
    /// along the pinch ray when it began (0 when the ray was not available).
    private var drag: (hand: SIMD3<Float>, centre: SIMD3<Float>)?

    var diagnostics: EngineDiagnostics { lock.withLock { diagnosticsStorage } }

    /// Inside the CompositorLayer closure: creates the runtime, the scene and
    /// the render thread.
    @MainActor
    func start(layerRenderer: LayerRenderer) {
        if xr != nil {
            // Reopened before the last session's release ran.
            releaseSession()
        }
        RenderSettings.applyBeforeRendererCreation()
        guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else {
            Self.log.error("the XR runtime could not be created")
            return
        }
        self.xr = xr
        isOpen = true
        xr.setImmersionMode(xrImmersionMode: .mixed)
        RenderSettings.applyAfterRendererCreation(xr)
        RenderSettings.applyRenderQuality(to: layerRenderer)
        assetBasePath = Bundle.main.resourceURL
        // One sun over the wearer's shoulder; the image-based light comes from
        // RenderSettings (the room's estimate or the studio HDR).
        _ = DirectionalLightNode(name: "Viewer.sun")
            .color(1.0, 0.98, 0.92)
            .intensity(RenderSettings.sunWanted ? 2.0 : 0.0)
            .rotateBy(angle: -50, axis: [.x])
            .rotateBy(angle: 30, axis: [.y])
        frames = 0
        skippedFrames = 0
        phase = MeasurementRun.signposter.beginInterval("Engine", id: MeasurementRun.signposter.makeSignpostID(), "empty")
        // A pinch-drag moves the object (closer, farther, up, down): the engine
        // reports the pinching hand's position from the layer's spatial events.
        InputSystem.shared.registerXREvents()
        setInput(.xr(.sceneReady(true)))
        // The frame's time: the instant the compositor predicts the frame will be shown, which
        // the head pose is predicted for too, so the tour's pose for it keeps step with the head.
        xr.setupCallbacks(
            frameUpdate: { [weak self] frame in self?.update(frame: frame) },
            handleInput: { [weak self] in self?.handleInput() }
        )
        let thread = Thread { [self] in
            xr.start()
            xr.runLoop()
            Task { @MainActor in
                self.releaseSession()
            }
        }
        thread.name = "XR Render Thread"
        thread.qualityOfService = .userInteractive
        renderThread = thread
        thread.start()
        // The object goes where the wearer stands and looks. The runtime tracks
        // the headset itself (no second ARKit session beside its own), and
        // the pose is in a few frames after the space opens: wait for it, and
        // for a second of empty frames, so the space's own GPU cost is on
        // record and the object's can be read as the difference.
        Task { @MainActor in
            var waited = 0
            while self.xr === xr, self.lock.withLock({ self.frames }) < 120 || (xr.currentDevicePose == nil && waited < 60) {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 1
            }
            if Catalog.isPassActive {
                // The wearer aims where the object should go while the pill
                // counts down; the pose is taken when the count ends.
                MeasurementRun.shared.beginAiming(seconds: Catalog.passPlacementDelay)
                try? await Task.sleep(for: .seconds(Catalog.passPlacementDelay))
            }
            guard self.xr === xr else { return }
            // A later round of a pass: the spot is pinned by a world anchor,
            // which the system re-resolves in this session's frame (the frame
            // moved between sessions and the stored numbers did not).
            if Catalog.isPassActive, let anchorID = Catalog.storedPassAnchorID, Catalog.currentPassPlacement != nil {
                if let anchor = await HeadPose.shared.resolve(anchorID) {
                    Catalog.refreshStoredPlacement(from: anchor)
                    consoleLine("engine: placement resolved from the world anchor")
                }
            }
            guard self.xr === xr else { return }
            let head = xr.currentDevicePose
            if let head {
                Self.log.log("head at (\(head.columns.3.x, format: .fixed(precision: 2)), \(head.columns.3.y, format: .fixed(precision: 2)), \(head.columns.3.z, format: .fixed(precision: 2))), from the runtime")
            } else {
                Self.log.log("no device pose from the runtime: room frame")
            }
            let firstOfPass = Catalog.isPassActive && Catalog.currentPassPlacement == nil
            withWorldAccessGate { self.placeObject(head: head) }
            if firstOfPass, let placement = Catalog.currentPassPlacement {
                // The deciding round pins the spot for the rounds after it.
                let id = await HeadPose.shared.anchor(Catalog.anchorTransform(of: placement))
                Catalog.storePassAnchorID(id)
                await HeadPose.shared.removeAnchors(except: id)
            }
        }
    }

    @MainActor
    private func placeObject(head: simd_float4x4?) {
        guard let placement = Catalog.placement(head: head) else { return }
        let entity = createEntity()
        setEntityName(entityId: entity, name: "Viewer.\(placement.object.id)")
        if placement.object.id == CalibrationObject.id {
            CalibrationObject.buildEngine(parent: entity)
        } else {
            setEntityMesh(entityId: entity, filename: placement.object.id, withExtension: "untold")
        }
        translateTo(entityId: entity, position: placement.position)
        rotateTo(entityId: entity, rotation: placement.orientation)
        objectName = placement.object.id
        lock.withLock { object = (entity, placement, ProcessInfo.processInfo.systemUptime) }
        if let phase { MeasurementRun.signposter.endInterval("Engine", phase) }
        phase = MeasurementRun.signposter.beginInterval("Engine", id: MeasurementRun.signposter.makeSignpostID(), "\(placement.object.id, privacy: .public)")
        Self.log.log("engine: empty space \(self.emptyGpuAverage, format: .fixed(precision: 2)) ms GPU over \(self.emptyFrames) frames before the object")
        consoleLine("engine: \(placement.object.id) centred at (\(placement.centre.x), \(placement.centre.y), \(placement.centre.z)), head \(head == nil ? "nil" : "ok")")
        // The look state at this moment, for a capture to be read against: what the look pass
        // was told to show and how the frame is encoded for the layer.
        consoleLine("engine: look state: render path \(getRenderPath().rawValue), primaries \(TonemapParams.shared.primaries.rawValue) (wide gamut \(RenderSettings.diagnosticOn(RenderSettings.wideGamutKey) ? "on" : "off")), tone map \(TonemapParams.shared.operator.rawValue), encode \(renderInfo.colorPipeline.present.encodingMode)")
        // The room light as the engine has it a few seconds in, for a capture taken then to be
        // read against: the probe's scale, how many estimates arrived and the light per face.
        for delay in [5.0, 25.0] {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, let d = self.xr?.xrEnvironmentLightingDiagnostics() else { return }
                let faces = d.latestProbeFaceLuminance.map { String(format: "%.3f", $0) }.joined(separator: " ")
                consoleLine(String(format: "engine: light state +%.0f s: scale %.2f (camera ref %.0f, published %.2f), %d publishes (%d accepted, %d skipped), faces +x −x +y −y +z −z %@%@", delay, d.latestIntensityScale, d.latestCameraScaleReference ?? 0, d.publishedIntensityScale ?? 0, d.publishCount, d.acceptedProbeUpdateCount, d.skippedProbeUpdateCount, faces, d.fallbackReason.map { ", fallback: " + $0 } ?? ""))
            }
        }
        Self.log.log("engine: \(placement.object.id, privacy: .public) centred at (\(placement.centre.x, format: .fixed(precision: 2)), \(placement.centre.y, format: .fixed(precision: 2)), \(placement.centre.z, format: .fixed(precision: 2))), \(head == nil ? "room frame" : "in front of the wearer", privacy: .public)")
    }

    /// Once per frame on the render thread, with the frame's time: the instant the compositor
    /// predicts the frame will be shown.
    private func update(frame: FrameTime) {
        lock.withLock {
            frames &+= 1
            skippedFrames += frame.skippedFrames
        }
        // About a second's window at 90 Hz; the first frames after a mode change are noisy.
        let timing = EngineStatsMonitor.shared.snapshot().timing
        let gpu = timing.gpuExecutionMs
        let cadence = timing.gpuFrameCadenceMs
        let cpu = CPUMilliseconds(loop: timing.frameTotalMs, update: timing.updateMs, wait: timing.xrWaitMs, encode: timing.encodeMs)
        let render = EngineStatsMonitor.shared.snapshot().render
        if lock.withLock({ object }) != nil, render.drawCallsOpaque > 0 {
            opaqueDrawsLeast = min(opaqueDrawsLeast, render.drawCallsOpaque)
            opaqueDrawsMost = max(opaqueDrawsMost, render.drawCallsOpaque)
            batchedDrawsMost = max(batchedDrawsMost, render.drawCallsBatched)
        }
        if gpu > 0 {
            gpuAverage = gpuAverage == 0 ? gpu : gpuAverage + (gpu - gpuAverage) / 90
            cadenceAverage = cadenceAverage == 0 ? cadence : cadenceAverage + (cadence - cadenceAverage) / 90
            cpuAverage = cpuAverage.averaged(with: cpu, window: 90)
            if lock.withLock({ object }) == nil, frames > 30 {
                emptyFrames += 1
                let window = Double(min(emptyFrames, 90))
                emptyGpuAverage = emptyGpuAverage == 0 ? gpu : emptyGpuAverage + (gpu - emptyGpuAverage) / window
                emptyCadenceAverage = emptyCadenceAverage == 0 ? cadence : emptyCadenceAverage + (cadence - emptyCadenceAverage) / window
                emptyCpuAverage = emptyCpuAverage.averaged(with: cpu, window: window)
            }
        }
        // The GPU's own time per pass, the last resolved frame, averaged the same way.
        let (passFrame, passes) = GPUPassTiming.shared.lastFrame()
        if passFrame != lastPassFrame, !passes.isEmpty {
            lastPassFrame = passFrame
            let empty = lock.withLock { object } == nil && frames > 30
            let window = empty ? Double(min(max(emptyFrames, 1), 90)) : 90
            var averages = empty ? emptyPassAverages : passAverages
            for label in Set(averages.keys).union(passes.map(\.label)) {
                let pass = passes.first { $0.label == label }
                let now = PassMilliseconds(vertex: pass?.vertexMs ?? 0, fragment: pass?.fragmentMs ?? 0)
                if let old = averages[label] {
                    averages[label] = PassMilliseconds(vertex: old.vertex + (now.vertex - old.vertex) / window,
                                                       fragment: old.fragment + (now.fragment - old.fragment) / window)
                } else {
                    averages[label] = now
                }
            }
            if empty { emptyPassAverages = averages } else { passAverages = averages }
        }
        var tourTime: Double?
        if let object = lock.withLock({ object }) {
            if Catalog.motionIsTour {
                // The tour's time at the instant the frame will be shown, not at this update:
                // the pose then steps by the display's period from one frame to the next, and by
                // two after a skipped one, instead of by the varying lag of the update behind
                // the presentation. `placed` is in the same clock base (the system uptime).
                tourTime = (frame.presentationTime - object.placed).truncatingRemainder(dividingBy: Catalog.Tour.period)
            }
            let pose = object.placement.pose(tourTime: tourTime)
            translateTo(entityId: object.entity, position: pose.position)
            rotateTo(entityId: object.entity, rotation: pose.orientation)
            probeFrameLuminance(tourTime: tourTime)
        }
        if frames == 90 {
            let foveation = renderInfo.xrFoveation.map { "on, screen \(Int($0.screenSize.x))×\(Int($0.screenSize.y))" } ?? "off"
            Self.log.log("render: anti-aliasing \(String(describing: antiAliasingMode), privacy: .public), opaque samples \(renderInfo.opaqueSampleCount), drawable \(Int(renderInfo.viewPort.x))×\(Int(renderInfo.viewPort.y)) per eye, foveation \(foveation, privacy: .public)")
        }
        let screen = renderInfo.xrFoveation?.screenSize ?? .zero
        let stats = EngineStatsMonitor.shared.snapshot()
        let snapshot = EngineDiagnostics(
            frames: frames,
            object: objectName,
            antiAliasing: String(describing: antiAliasingMode),
            opaqueSampleCount: renderInfo.opaqueSampleCount,
            viewport: SIMD2<Int>(Int(renderInfo.viewPort.x), Int(renderInfo.viewPort.y)),
            screenSize: SIMD2<Int>(Int(screen.x), Int(screen.y)),
            gpuMilliseconds: gpuAverage,
            emptyGpuMilliseconds: lock.withLock({ object }) == nil ? 0 : emptyGpuAverage,
            cadenceMilliseconds: cadenceAverage,
            emptyCadenceMilliseconds: lock.withLock({ object }) == nil ? 0 : emptyCadenceAverage,
            cpu: cpuAverage,
            emptyCpu: lock.withLock({ object }) == nil ? CPUMilliseconds() : emptyCpuAverage,
            engineOptimized: EngineBuild.isOptimized,
            shadowTaps: RenderSettings.shadowTaps,
            sun: RenderSettings.sunWanted,
            roomLightScale: xr?.xrEnvironmentLightingDiagnostics().latestIntensityScale ?? 0,
            roomLightCameraReference: xr?.xrEnvironmentLightingDiagnostics().latestCameraScaleReference ?? 0,
            roomLightFactor: xr?.xrEnvironmentLightingDiagnostics().realWorldLightingContribution ?? 1,
            roomLightPublished: xr?.xrEnvironmentLightingDiagnostics().publishedIntensityScale ?? 0,
            probe: xr?.xrEnvironmentLightingDiagnostics().latestProbeDescription ?? "",
            probePublishes: xr?.xrEnvironmentLightingDiagnostics().publishCount ?? 0,
            probeAccepted: xr?.xrEnvironmentLightingDiagnostics().acceptedProbeUpdateCount ?? 0,
            probeSkipped: xr?.xrEnvironmentLightingDiagnostics().skippedProbeUpdateCount ?? 0,
            probeAge: (xr?.xrEnvironmentLightingDiagnostics().latestProbeTimestamp).map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0,
            probeFaces: xr?.xrEnvironmentLightingDiagnostics().latestProbeFaceLuminance ?? [],
            wideGamut: RenderSettings.diagnosticOn(RenderSettings.wideGamutKey),
            toneMap: RenderSettings.toneMap,
            textureUpgrades: TextureStreamingSystem.shared.getStats().totalUpgrades,
            textureDowngrades: TextureStreamingSystem.shared.getStats().totalDowngrades,
            textureEntitiesAtFull: TextureStreamingSystem.shared.getStats().upgradedEntityCount,
            textureOpsInFlight: TextureStreamingSystem.shared.getStats().activeOps,
            textureMemoryUsedMB: MemoryBudgetManager.shared.getStats().textureMemoryUsed / (1024 * 1024),
            textureBudgetMB: MemoryBudgetManager.shared.textureBudget / (1024 * 1024),
            tourTime: tourTime,
            skippedFrames: lock.withLock { skippedFrames },
            presentationRevisions: xr?.presentationTimeRevisions ?? 0,
            drawCalls: stats.render.drawCallsTotal,
            triangles: stats.render.trianglesTotal,
            opaqueDrawsLeast: opaqueDrawsLeast == Int.max ? 0 : opaqueDrawsLeast,
            opaqueDrawsMost: opaqueDrawsMost,
            batchedDrawsMost: batchedDrawsMost,
            depthFormat: xr?.depthSetupDescription ?? "",
            nearPlane: near,
            compositeSkipped: renderInfo.preCompositeBypassSource != nil,
            tileLightStage: renderInfo.tileLightStageUsed,
            plainDraws: renderInfo.opaqueDrawsPlain,
            discardingDraws: renderInfo.opaqueDrawsDiscarding,
            foveation: UserDefaults.standard.object(forKey: RenderSettings.foveationAvailableKey) == nil ? true : UserDefaults.standard.bool(forKey: RenderSettings.foveationAvailableKey),
            cullCandidates: renderInfo.hzbCandidateCount,
            renderPath: renderInfo.perFragmentLightingBuilt ? "forward" : renderInfo.perFragmentIndirectLightingBuilt ? "hybrid" : "deferred",
            occlusionCull: RenderSettings.diagnosticOn(RenderSettings.occlusionCullKey),
            taaJitter: RenderSettings.diagnosticOn(RenderSettings.taaJitterKey),
            textureStreaming: RenderSettings.diagnosticOn(RenderSettings.textureStreamingKey),
            lighting: RenderSettings.lighting,
            darkFrames: lock.withLock { darkFrames },
            darkFrameTimes: lock.withLock { darkFrameTimes },
            passMilliseconds: passAverages,
            emptyPassMilliseconds: lock.withLock({ object }) == nil ? [:] : emptyPassAverages
        )
        lock.withLock { diagnosticsStorage = snapshot }
    }

    /// The mean colour of the last frame's resolved picture (the lit scene when there is no
    /// temporal resolve), read back a frame later: the engine's frame and this read run in
    /// order on the one queue, and the frame after writes the other history texture. A frame
    /// whose object went dark — its face culled, its light gone — shows as a drop of the mean
    /// against the frame before, since the passthrough is not in the picture; the drop and
    /// the tour's time go to the log and the summary.
    private func probeFrameLuminance(tourTime: Double?) {
        guard !lock.withLock({ probeInFlight }),
              let source = TemporalAntiAliasing.shared.resolvedTexture ?? textureResources.deferredColorMap,
              let device = renderInfo.device,
              let queue = renderInfo.commandQueue
        else { return }
        if probe == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .shared
            guard let destination = device.makeTexture(descriptor: descriptor) else { return }
            probe = (MPSImageStatisticsMean(device: device), destination)
        }
        guard let probe, let commandBuffer = queue.makeCommandBuffer() else { return }
        commandBuffer.label = "Viewer brightness probe"
        probe.mean.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: probe.destination)
        lock.withLock { probeInFlight = true }
        let frame = lock.withLock { frames }
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            var mean = [Float](repeating: 0, count: 4)
            probe.destination.getBytes(&mean, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            let luminance = Double(0.2126 * mean[0] + 0.7152 * mean[1] + 0.0722 * mean[2])
            let dark: Double? = self.lock.withLock {
                defer {
                    self.lastLuminance = luminance
                    self.probeInFlight = false
                }
                guard self.lastLuminance > 1e-5, luminance < self.lastLuminance * 2 / 3 else { return nil }
                self.darkFrames += 1
                if self.darkFrameTimes.count < 8, let tourTime { self.darkFrameTimes.append(tourTime) }
                return self.lastLuminance
            }
            if let dark {
                Self.log.log("dark frame \(frame): mean brightness \(luminance, format: .fixed(precision: 5)) after \(dark, format: .fixed(precision: 5)), tour \(tourTime ?? -1, format: .fixed(precision: 2)) s")
            }
        }
        commandBuffer.commit()
    }

    /// A pinch anywhere drags the object by what the hand moves, one to one on every axis, as
    /// RealityKit's drag does: the pinch ray follows the gaze, not the hand, so riding it gave
    /// no sideways motion, and a gain on the hand's travel made the object outrun the hand.
    private func handleInput() {
        let state = getXRSpatialInputState()
        let pinching = state.spatialPinchActive && state.currentPhase != .ended && state.currentPhase != .cancelled
        guard pinching, let hand = state.inputDevicePositionWorld, hand.x.isFinite, hand.y.isFinite, hand.z.isFinite else {
            drag = nil
            return
        }
        lock.withLock {
            guard let current = object else { return }
            if drag == nil {
                drag = (hand, current.placement.centre)
                return
            }
            guard let drag else { return }
            object?.placement.centre = drag.centre + (hand - drag.hand)
        }
    }

    /// Releases a session the system closed. Once `runLoop()` has returned no
    /// frame runs again, so release here and now.
    @MainActor
    func releaseSession() {
        if let xr {
            setRendering(.extensions(.removeAll))
            xr.clearSpatialInput()
            xr.stop()
        }
        if let phase { MeasurementRun.signposter.endInterval("Engine", phase) }
        phase = nil
        setInput(.xr(.sceneReady(false)))
        InputSystem.shared.unregisterXREvents()
        destroyAllEntities()
        xr = nil
        renderThread = nil
        isOpen = false
        objectName = ""
        gpuAverage = 0
        emptyGpuAverage = 0
        emptyFrames = 0
        passAverages = [:]
        emptyPassAverages = [:]
        lastPassFrame = 0
        lock.withLock {
            object = nil
            drag = nil
            probeInFlight = false
            lastLuminance = 0
            darkFrames = 0
            darkFrameTimes = []
        }
        probe = nil
        lock.withLock { diagnosticsStorage = EngineDiagnostics() }
    }
}

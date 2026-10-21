//
//  MeasurementRun.swift
//  Untold Viewer
//
//  A scripted measurement: the chosen object through both renderers, on the
//  same tour, each phase marked with a signpost interval so an Instruments
//  recording (RealityKit Trace, Metal System Trace) shows "engine empty",
//  "engine <object>" and "realitykit <object>" on its timeline and the GPU
//  time can be read per phase — the only way to put a number on RealityKit,
//  which renders out of process. `Tools/measure.sh` records one.
//

import Foundation
import os

/// What the pass needs from the app's windows.
struct MeasurementWindows {
    var hideControls: () -> Void = {}
    var showControls: () -> Void = {}
    var showStatus: () -> Void = {}
    var hideStatus: () -> Void = {}
}

@MainActor
@Observable
final class MeasurementRun {
    static let shared = MeasurementRun()
    static let signposter = OSSignposter(subsystem: "com.untoldengine.untoldviewer", category: .pointsOfInterest)
    private static let log = Logger(subsystem: "com.untoldengine.untoldviewer", category: "measure")

    /// Seconds each renderer gets to settle before its tour loop is counted.
    static let settle = 4.0

    private(set) var running = false
    /// The step shown on the status pill ("Step 1 of 2 · Engine") and its line.
    private(set) var step = ""
    private(set) var status = ""
    private var phaseEnd: Date?
    private var placementEnd: Date?
    /// The launch arguments act once: the window reappears at the end of a
    /// pass and must not start another.
    var launchArgumentsHandled = false

    /// The engine round calls this when it is about to take the head pose:
    /// the pill counts the seconds down for the wearer to aim.
    func beginAiming(seconds: Double) {
        placementEnd = Date(timeIntervalSinceNow: seconds)
        status = "look where the object should go"
    }

    /// The pill's second line: a countdown while a loop is measured, else the status.
    func detail(at date: Date) -> String {
        if let placementEnd, running {
            let left = max(Int(placementEnd.timeIntervalSince(date).rounded()), 0)
            return "look where the object should go · \(left) s"
        }
        if let phaseEnd, running {
            let left = max(Int(phaseEnd.timeIntervalSince(date).rounded()), 0)
            return "measuring · \(left) s left"
        }
        return status
    }

    /// One engine configuration of the sweep.
    struct EngineConfig: Equatable {
        let antiAliasing: String
        let renderQuality: String
        var title: String {
            let aa = ["msaaTaa": "MSAA 4× + TAA", "msaa": "MSAA 4×", "taa": "TAA", "fxaa": "FXAA"][antiAliasing] ?? antiAliasing
            let q = ["max": "quality 1.0", "high": "quality 0.75", "default": "platform quality"][renderQuality] ?? renderQuality
            return "\(aa) · \(q)"
        }
    }

    /// The sweep: every anti-aliasing mode at quality 1.0, then MSAA 4× + TAA
    /// at the two lower qualities. Six engine rounds, about four minutes.
    static let sweepConfigs: [EngineConfig] = [
        EngineConfig(antiAliasing: "msaaTaa", renderQuality: "max"),
        EngineConfig(antiAliasing: "msaa", renderQuality: "max"),
        EngineConfig(antiAliasing: "taa", renderQuality: "max"),
        EngineConfig(antiAliasing: "fxaa", renderQuality: "max"),
        EngineConfig(antiAliasing: "msaaTaa", renderQuality: "high"),
        EngineConfig(antiAliasing: "msaaTaa", renderQuality: "default"),
    ]

    /// One pass over `phases` — by default the engine, then RealityKit, one
    /// tour loop each; a single renderer for one short Instruments recording
    /// per phase (a RealityKit-only pass reuses the placement the last engine
    /// pass saved). `show` opens and closes the spaces (the app's own switch).
    /// The status pill goes up first and stays across the spaces; the main
    /// window hides for the whole pass and returns with the results.
    func run(phases: [Renderer] = [.engine, .realityKit], show: @escaping (Renderer?) async -> Void, windows: MeasurementWindows = MeasurementWindows()) async {
        guard !running, !phases.isEmpty else { return }
        running = true
        defer { running = false }
        let object = Catalog.selectedID
        step = "Measuring \(object)"
        status = "starting…"
        windows.showStatus()
        try? await Task.sleep(for: .seconds(1))
        windows.hideControls()
        let summary = await performPass(phases: phases, reusePlacement: !phases.contains(.engine), stepPrefix: nil, show: show)
        step = "Done"
        status = summary.joined(separator: " · ")
        Self.log.log("measure: done")
        consoleLine("measure: done")
        running = false
        windows.showControls()
        try? await Task.sleep(for: .seconds(3))
        windows.hideStatus()
    }

    /// The engine alone through `Self.sweepConfigs`: the first round decides
    /// the placement, the rest reuse it, so the figures differ only by the
    /// settings. The wearer's settings are restored at the end.
    func sweep(show: @escaping (Renderer?) async -> Void, windows: MeasurementWindows = MeasurementWindows()) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let defaults = UserDefaults.standard
        let savedAA = defaults.string(forKey: RenderSettings.antiAliasingKey)
        let savedQuality = defaults.string(forKey: RenderSettings.renderQualityKey)
        let object = Catalog.selectedID
        step = "Sweep · \(object)"
        status = "starting…"
        windows.showStatus()
        try? await Task.sleep(for: .seconds(1))
        windows.hideControls()
        var summary: [String] = []
        for (index, config) in Self.sweepConfigs.enumerated() {
            defaults.set(config.antiAliasing, forKey: RenderSettings.antiAliasingKey)
            defaults.set(config.renderQuality, forKey: RenderSettings.renderQualityKey)
            let lines = await performPass(phases: [.engine], reusePlacement: index > 0, stepPrefix: "Sweep \(index + 1) of \(Self.sweepConfigs.count) · \(config.title)", show: show)
            summary.append(contentsOf: lines.map { "[\(config.title)] " + $0 })
        }
        if let savedAA { defaults.set(savedAA, forKey: RenderSettings.antiAliasingKey) } else { defaults.removeObject(forKey: RenderSettings.antiAliasingKey) }
        if let savedQuality { defaults.set(savedQuality, forKey: RenderSettings.renderQualityKey) } else { defaults.removeObject(forKey: RenderSettings.renderQualityKey) }
        step = "Sweep done"
        status = summary.joined(separator: " · ")
        Self.log.log("measure: sweep done")
        consoleLine("measure: sweep done")
        running = false
        windows.showControls()
        try? await Task.sleep(for: .seconds(3))
        windows.hideStatus()
    }

    /// The rounds of one pass; returns one summary line per round.
    private func performPass(phases: [Renderer], reusePlacement: Bool, stepPrefix: String?, show: @escaping (Renderer?) async -> Void) async -> [String] {
        let object = Catalog.selectedID
        let previousMotion = UserDefaults.standard.string(forKey: Catalog.motionKey)
        UserDefaults.standard.set("tour", forKey: Catalog.motionKey)
        Catalog.beginPass(reusingStored: reusePlacement)
        defer {
            Catalog.endPass()
            if let previousMotion {
                UserDefaults.standard.set(previousMotion, forKey: Catalog.motionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Catalog.motionKey)
            }
        }
        var summary: [String] = []
        let renderers: [(Renderer, String)] = phases.map { ($0, $0 == .engine ? "Engine" : "RealityKit") }
        for (index, (renderer, title)) in renderers.enumerated() {
            step = stepPrefix ?? "Step \(index + 1) of \(renderers.count) · \(title) · \(object)"
            status = "opening the \(title) space…"
            phaseEnd = nil
            let id = Self.signposter.makeSignpostID()
            let interval = Self.signposter.beginInterval("Measure", id: id, "\(renderer.rawValue, privacy: .public) \(object, privacy: .public)")
            consoleLine("measure: \(renderer.rawValue) \(object) begins\(stepPrefix.map { " (" + $0 + ")" } ?? "")")
            Self.log.log("measure: \(renderer.rawValue, privacy: .public) \(object, privacy: .public) begins")
            await show(renderer)
            let opened = EngineSession.shared.lastOpenResult == "opened"
            if !opened {
                // The system refused the space (the pill says what it answered);
                // nothing to measure in this round.
                let line = "\(title) space did not open: \(EngineSession.shared.lastOpenResult)"
                status = line
                summary.append(line)
                consoleLine("measure: " + line)
                Self.log.error("measure: \(line, privacy: .public)")
                Self.signposter.endInterval("Measure", interval)
                try? await Task.sleep(for: .seconds(4))
                continue
            }
            // Until the object is in: the engine warms up, asks the wearer to
            // aim (beginAiming) and places; RealityKit loads and places.
            status = "warming up…"
            var waited = 0
            let placed = { renderer == .engine ? !EngineSession.shared.diagnostics.object.isEmpty : RealityKitSpaceState.shared.objectPlaced }
            while waited < 600, !placed() {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 1
            }
            placementEnd = nil
            if !placed() {
                let line = "\(title): the object was not placed within 30 s"
                status = line
                summary.append(line)
                consoleLine("measure: " + line)
                Self.log.error("measure: \(line, privacy: .public)")
            }
            status = "settling…"
            try? await Task.sleep(for: .seconds(Self.settle))
            phaseEnd = Date(timeIntervalSinceNow: Catalog.Tour.period)
            try? await Task.sleep(for: .seconds(Catalog.Tour.period))
            phaseEnd = nil
            if renderer == .engine {
                let d = EngineSession.shared.diagnostics
                let fps = d.cadenceMilliseconds > 0 ? 1000 / d.cadenceMilliseconds : 0
                let emptyFps = d.emptyCadenceMilliseconds > 0 ? 1000 / d.emptyCadenceMilliseconds : 0
                let line = String(format: "engine %@: gpu %.2f ms, empty %.2f, object %+.2f, %.0f fps (empty %.0f) (%@ ×%d, %d×%d%@, %d draws, %d tris%@)",
                                  object, d.gpuMilliseconds, d.emptyGpuMilliseconds, d.objectGpuMilliseconds ?? 0, fps, emptyFps,
                                  d.antiAliasing, d.opaqueSampleCount, d.viewport.x, d.viewport.y,
                                  d.screenSize.x > 0 ? String(format: " fov %d×%d", d.screenSize.x, d.screenSize.y) : "",
                                  d.drawCalls, d.triangles, (d.compositeSkipped ? ", composite skipped" : "") + ", " + d.renderPath + (d.tileLightStage ? " (tile light)" : "") + String(format: ", draws %d plain / %d discarding", d.plainDraws, d.discardingDraws) + (d.foveation ? "" : ", no foveation") + String(format: ", cull set %d", d.cullCandidates) + (d.shadowTaps == 8 ? "" : String(format: ", shadow taps %d", d.shadowTaps)) + (d.opaqueDrawsMost > 0 ? String(format: ", opaque draws %d–%d%@", d.opaqueDrawsLeast, d.opaqueDrawsMost, d.batchedDrawsMost > 0 ? String(format: " + %d batched", d.batchedDrawsMost) : "") : "") + (d.depthFormat.isEmpty ? "" : String(format: ", depth %@ (engine near %.3f)", d.depthFormat, d.nearPlane)) + (d.toneMap == "none" ? "" : ", tone map " + d.toneMap) + String(format: ", textures %d up / %d down, %d at full, %d in flight, %d of %d MB", d.textureUpgrades, d.textureDowngrades, d.textureEntitiesAtFull, d.textureOpsInFlight, d.textureMemoryUsedMB, d.textureBudgetMB) + (d.sun ? "" : ", no sun") + (d.roomLightScale > 0 ? String(format: ", room light scale %.2f (camera ref %.0f, published %.2f) × %.0f", d.roomLightScale, d.roomLightCameraReference, d.roomLightPublished, d.roomLightFactor) : "") + (d.probe.isEmpty ? "" : String(format: ", probe %@, %d publishes (%d updates accepted, %d skipped, last %.0f s ago)", d.probe, d.probePublishes, d.probeAccepted, d.probeSkipped, d.probeAge)) + (d.probeFaces.count == 6 ? String(format: ", probe faces +x %.3f −x %.3f +y %.3f −y %.3f +z %.3f −z %.3f", d.probeFaces[0], d.probeFaces[1], d.probeFaces[2], d.probeFaces[3], d.probeFaces[4], d.probeFaces[5]) : "") + (d.wideGamut ? "" : ", sRGB primaries") + (d.occlusionCull ? "" : ", occlusion off") + (d.taaJitter ? "" : ", jitter off") + (d.textureStreaming ? "" : ", streaming off") + (d.lighting == "room" ? "" : ", studio light") + String(format: ", %d dark frames%@", d.darkFrames, d.darkFrameTimes.isEmpty ? "" : " (tour " + d.darkFrameTimes.map { String(format: "%.1f", $0) }.joined(separator: " ") + " s)") + String(format: ", %d skipped refreshes, %d presentation revisions", d.skippedFrames, d.presentationRevisions) + (d.engineOptimized ? "" : ", UNOPTIMIZED ENGINE") + (d.drawCalls == 0 && d.gpuMilliseconds == 0 ? ", NO ENGINE STATS (build with -DENGINE_STATS_ENABLED)" : ""))
                summary.append(line)
                consoleLine("measure: " + line)
                Self.log.log("measure: \(line, privacy: .public)")
                if d.cpu.loop > 0 {
                    // The CPU side, with the object and in the empty space: the loop's period and
                    // its phases; update + encode is the CPU's work, the wait is the pacing.
                    let cpuLine = String(format: "engine %@ cpu (object / empty, ms): loop %.2f / %.2f, update %.2f / %.2f, wait %.2f / %.2f, encode %.2f / %.2f",
                                         object, d.cpu.loop, d.emptyCpu.loop, d.cpu.update, d.emptyCpu.update, d.cpu.wait, d.emptyCpu.wait, d.cpu.encode, d.emptyCpu.encode)
                    summary.append(cpuLine)
                    consoleLine("measure: " + cpuLine)
                    Self.log.log("measure: \(cpuLine, privacy: .public)")
                }
                if !d.passMilliseconds.isEmpty {
                    // Each pass with the object and in the empty space: "label total (v+f) / empty".
                    let order = d.passMilliseconds.sorted { $0.value.total > $1.value.total }
                    let parts = order.map { label, t -> String in
                        let e = d.emptyPassMilliseconds[label] ?? PassMilliseconds()
                        return t.vertex > 0.005
                            ? String(format: "%@ %.2f (v%.2f+f%.2f) / %.2f", label, t.total, t.vertex, t.fragment, e.total)
                            : String(format: "%@ %.2f / %.2f", label, t.fragment, e.fragment)
                    }
                    let passLine = "engine \(object) passes (object / empty, ms): " + parts.joined(separator: ", ")
                    summary.append(passLine)
                    consoleLine("measure: " + passLine)
                    Self.log.log("measure: \(passLine, privacy: .public)")
                }
            } else {
                let line = String(format: "realitykit %@: updates %.0f Hz; gpu from the trace", object, RealityKitSpaceState.shared.updatesPerSecond)
                summary.append(line)
                consoleLine("measure: " + line)
                Self.log.log("measure: \(line, privacy: .public)")
            }
            Self.signposter.endInterval("Measure", interval)
            status = "closing the \(title) space…"
            await show(nil)
            try? await Task.sleep(for: .seconds(2))
        }
        return summary
    }
}

//
//  ControlsView.swift
//  Untold Viewer
//
//  The one window: the two renderers' buttons across the top, the catalog
//  down the left (it grows), the placement and engine options on the right,
//  and the engine's frame diagnostics along the bottom.
//

import SwiftUI
import UntoldEngine

struct ControlsView: View {
    let show: (Renderer?) async -> Void
    let hideWindow: () -> Void
    let measurementWindows: MeasurementWindows

    @AppStorage(Catalog.objectKey) private var object = Catalog.defaultObject
    @AppStorage(Catalog.placementModeKey) private var placementMode = "front"
    @AppStorage(Catalog.motionKey) private var motion = "still"
    @AppStorage(Catalog.distanceKey) private var distance = Double(Catalog.defaultDistance)
    @AppStorage(Catalog.heightKey) private var height = Double(Catalog.defaultHeight)
    @AppStorage(RenderSettings.antiAliasingKey) private var antiAliasing = "msaaTaa"
    @AppStorage(RenderSettings.msaaSamplesKey) private var msaaSamples = "4"
    @AppStorage(RenderSettings.renderQualityKey) private var renderQuality = "max"
    @AppStorage(RenderSettings.lightingKey) private var lighting = "room"
    @AppStorage(RenderSettings.foveationAvailableKey) private var foveationAvailable = false
    @AppStorage(RenderSettings.taaHistoryWeightKey) private var taaHistoryWeight = 0.9
    @AppStorage(RenderSettings.taaClipGammaKey) private var taaClipGamma = 1.25
    @AppStorage(RenderSettings.occlusionCullKey) private var occlusionCull = true
    @AppStorage(RenderSettings.taaJitterKey) private var taaJitter = true
    @AppStorage(RenderSettings.textureStreamingKey) private var textureStreaming = true
    @AppStorage(RenderSettings.tileLightStageKey) private var tileLightStage = true
    @AppStorage(RenderSettings.hiddenSurfaceRemovalKey) private var hiddenSurfaceRemoval = true
    @AppStorage(RenderSettings.gpuPassTimingKey) private var gpuPassTiming = true
    @AppStorage(RenderSettings.renderPathKey) private var renderPath = "forward"
    @AppStorage(RenderSettings.shadowTapsKey) private var shadowTaps = 8
    @AppStorage(RenderSettings.sunKey) private var sun = true
    @AppStorage(RenderSettings.roomLightFactorKey) private var roomLightFactor = 1.0
    @AppStorage(RenderSettings.toneMapKey) private var toneMap = "none"
    @AppStorage(RenderSettings.wideGamutKey) private var wideGamut = true
    @AppStorage(RenderSettings.foveationKey) private var foveation = true
    private var measurement: MeasurementRun { MeasurementRun.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                objectList
                    .frame(width: 340)
                Divider()
                ScrollView {
                    options
                        .padding(24)
                }
            }
            Divider()
            diagnostics
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassBackgroundEffect()
        .onAppear(perform: handleLaunchArguments)
    }

    // MARK: Header: the two renderers

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Untold Viewer")
                    .font(.system(size: 34, weight: .bold))
                Text("The same objects at the same spot, drawn by the engine or by RealityKit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button {
                Task { await show(.engine) }
            } label: {
                Label("Engine", systemImage: "cube.transparent")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            Button {
                Task { await show(.realityKit) }
            } label: {
                Label("RealityKit", systemImage: "arkit")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            Button("Close") { Task { await show(nil) } }
                .buttonStyle(.bordered)
            Menu {
                Button("Both renderers") { Task { await measurement.run(show: show, windows: measurementWindows) } }
                Button("Engine only") { Task { await measurement.run(phases: [.engine], show: show, windows: measurementWindows) } }
                Button("RealityKit only, at the engine's last placement") { Task { await measurement.run(phases: [.realityKit], show: show, windows: measurementWindows) } }
                Divider()
                Button("Engine sweep: anti-aliasing × quality (6 rounds)") { Task { await measurement.sweep(show: show, windows: measurementWindows) } }
            } label: {
                Label("Measure", systemImage: "stopwatch")
            }
            .buttonStyle(.bordered)
            .disabled(measurement.running)
            .help("One tour loop per renderer, signposted for Instruments; one renderer at a time for short recordings")
        }
        .controlSize(.large)
    }

    // MARK: Left: the catalog, one object chosen

    private var objectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Objects")
                    .font(.headline)
                Spacer()
                Text("\(Catalog.all.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            List(Catalog.all, selection: selection) { object in
                VStack(alignment: .leading, spacing: 2) {
                    Text(object.title)
                    Text(object.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .tag(object.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    /// The list's single selection, kept in the same default the spaces read.
    private var selection: Binding<String?> {
        Binding(get: { object }, set: { if let id = $0 { object = id } })
    }

    // MARK: Right: placement and the engine's settings

    private var options: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Placement").font(.headline)
                Text(placementMode == "front"
                    ? "Ahead of where you stand and look when the space opens, 30° to the right so the window does not cover it, at eye height, facing you. Pinch and drag the object to move it."
                    : "In the room's frame: ahead of where you stood when the space opened, at the height below, facing +z. Pinch and drag the object to move it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                pickerRow("Where") {
                    Picker("Where", selection: $placementMode) {
                        Text("In front of me").tag("front")
                        Text("Fixed in the room").tag("fixed")
                    }
                }
                sliderRow("Distance", value: $distance, range: 0.3 ... 4.0, step: 0.05, unit: "m")
                if placementMode == "fixed" {
                    sliderRow("Height", value: $height, range: 0.5 ... 2.2, step: 0.01, unit: "m")
                }
                pickerRow("Motion", note: motion == "tour" ? "debug: in to 30 %, out, sweep, turn; 24 s loop, same path in both" : nil) {
                    Picker("Motion", selection: $motion) {
                        Text("Still").tag("still")
                        Text("Tour").tag("tour")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Engine").font(.headline)
                Text("Applied when the engine space is (re)opened; the TAA knobs are live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                pickerRow("Anti-aliasing") {
                    Picker("Anti-aliasing", selection: $antiAliasing) {
                        Text("MSAA \(msaaSamples)× + TAA").tag("msaaTaa")
                        Text("MSAA \(msaaSamples)×").tag("msaa")
                        Text("TAA").tag("taa")
                        Text("FXAA").tag("fxaa")
                    }
                }
                pickerRow("MSAA samples", note: "live; 2× lets the tile light stage light each pixel once") {
                    Picker("MSAA samples", selection: $msaaSamples) {
                        Text("2×").tag("2")
                        Text("4×").tag("4")
                    }
                    .onChange(of: msaaSamples) { RenderSettings.applyMultisampleCount() }
                }
                pickerRow("Render quality", note: foveationAvailable ? nil : "needs foveation (device)") {
                    Picker("Render quality", selection: $renderQuality) {
                        Text("Platform default").tag("default")
                        Text("High (0.75)").tag("high")
                        Text("Max (1.0)").tag("max")
                    }
                    .disabled(!foveationAvailable)
                }
                HStack(spacing: 16) {
                    Text("Foveation")
                        .frame(width: 170, alignment: .leading)
                    Toggle("Foveation", isOn: $foveation)
                        .labelsHidden()
                        .toggleStyle(.switch)
                    Text("applied when the space opens; off, the compositor picks its own resolution")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                pickerRow("Lighting") {
                    Picker("Lighting", selection: $lighting) {
                        Text("Room (estimated)").tag("room")
                        Text("Studio HDR").tag("studio")
                    }
                }
                sliderRow("TAA history", value: $taaHistoryWeight, range: 0.5 ... 0.97, step: 0.01, unit: "")
                    .onChange(of: taaHistoryWeight) { RenderSettings.applyTAAParams() }
                sliderRow("TAA clip γ", value: $taaClipGamma, range: 0.5 ... 3.0, step: 0.05, unit: "")
                    .onChange(of: taaClipGamma) { RenderSettings.applyTAAParams() }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Engine diagnostics").font(.headline)
                if !EngineBuild.isOptimized {
                    Text("The engine is compiled without optimization: the frame is CPU-bound and a measurement times the compiler, not the renderer. Build with SWIFT_OPTIMIZATION_LEVEL=-O (see the README).")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Live. Which system blinks a moving object: the occlusion test against the previous frame's depth, the temporal jitter, or the texture tiers that follow camera distance. Hidden-surface removal: opaque draws that never discard use a model pipeline without discards, so hidden fragments are never shaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Toggle("Occlusion cull", isOn: $occlusionCull)
                    Toggle("TAA jitter", isOn: $taaJitter)
                    Toggle("Texture streaming", isOn: $textureStreaming)
                    Toggle("Hidden-surface removal", isOn: $hiddenSurfaceRemoval)
                    Toggle("GPU pass timing", isOn: $gpuPassTiming)
                }
                .toggleStyle(.switch)
                .onChange(of: gpuPassTiming) { RenderSettings.applyDiagnostics() }
                HStack(spacing: 16) {
                    Text("Render path").font(.subheadline)
                    Picker("Render path", selection: $renderPath) {
                        Text("Deferred").tag("deferred")
                        Text("Hybrid").tag("hybrid")
                        Text("Forward").tag("forward")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    Text(renderPathNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: renderPath) { RenderSettings.applyDiagnostics() }
                // The switches of the chosen path, for a debug session or an experiment on it.
                if renderPath != "forward" {
                    HStack(spacing: 16) {
                        Toggle("Tile light stage", isOn: $tileLightStage)
                            .toggleStyle(.switch)
                        Text("The light pass as a tile stage that lights each pixel once per colour it holds; off, a quad that lights every multisample. Deferred and hybrid only: forward has no light pass.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .onChange(of: tileLightStage) { RenderSettings.applyDiagnostics() }
                }
                HStack(spacing: 16) {
                    Text("Shadow taps").font(.subheadline)
                    Picker("Shadow taps", selection: $shadowTaps) {
                        Text("16").tag(16)
                        Text("8").tag(8)
                        Text("4").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    Text("The sun shadow's compares per fragment: the whole Poisson disk, or every second (the headset's default) or fourth point of it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: shadowTaps) { RenderSettings.applyDiagnostics() }
                HStack(spacing: 16) {
                    Toggle("Sun", isOn: $sun)
                        .toggleStyle(.switch)
                    Text("Room light ×").font(.subheadline)
                    Picker("Room light factor", selection: $roomLightFactor) {
                        Text("1").tag(1.0)
                        Text("2").tag(2.0)
                        Text("4").tag(4.0)
                        Text("8").tag(8.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    Text("The sun applies when the space next opens; the factor on the room estimate's light applies at once. The summary prints the estimate's scale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: roomLightFactor) { RenderSettings.applyDiagnostics() }
                HStack(spacing: 16) {
                    Text("Tone map").font(.subheadline)
                    Picker("Tone map", selection: $toneMap) {
                        Text("None").tag("none")
                        Text("ACES").tag("aces")
                        Text("AgX").tag("agx")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    Text("None hands the compositor the scene's linear colour, as RealityKit does in a mixed space; a filmic curve compresses the object's whites and lifts its blacks against the room.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: toneMap) { RenderSettings.applyDiagnostics() }
                HStack(spacing: 16) {
                    Toggle("Wide gamut", isOn: $wideGamut)
                        .toggleStyle(.switch)
                    Text("The scene shown with the display's P3 primaries, as RealityKit shows it: measured on the calibration panel, its colours are the P3→sRGB matrix of the sRGB values, so every saturated colour is wider and what leaves the gamut clips. Off, the sRGB colour as it is.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: wideGamut) { RenderSettings.applyDiagnostics() }
                .onChange(of: occlusionCull) { RenderSettings.applyDiagnostics() }
                .onChange(of: taaJitter) { RenderSettings.applyDiagnostics() }
                .onChange(of: textureStreaming) { RenderSettings.applyDiagnostics() }
                .onChange(of: hiddenSurfaceRemoval) { RenderSettings.applyDiagnostics() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// What the chosen render path does, for the picker's caption.
    private var renderPathNote: String {
        switch renderPath {
        case "deferred": return "The geometry fills the G-buffer and the light pass lights it: the path for many lights and for the effects that read the G-buffer (ambient occlusion, the debug views)."
        case "hybrid": return "Deferred, with the image-based light and the sun's shadow done once per fragment by the geometry; the light pass adds the direct lights."
        default: return "The geometry lights itself whole once per fragment and writes one colour; the light quad stands down. The headset's path."
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        HStack(spacing: 16) {
            Text("\(title) \(value.wrappedValue, specifier: "%.2f")\(unit.isEmpty ? "" : " \(unit)")")
                .frame(width: 170, alignment: .leading)
            Slider(value: value, in: range, step: step)
        }
    }

    private func pickerRow(_ title: String, note: String? = nil, @ViewBuilder picker: () -> some View) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .frame(width: 170, alignment: .leading)
            picker()
                .labelsHidden()
                .pickerStyle(.menu)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Bottom: the engine's frame

    private var diagnostics: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let d = EngineSession.shared.diagnostics
            let engineOpen = EngineSession.shared.isOpen
            let rkOpen = RealityKitSpaceState.shared.isOpen
            let gpu = d.objectGpuMilliseconds.map { String(format: "gpu %.1f ms (empty %.1f, object %+.1f)", d.gpuMilliseconds, d.emptyGpuMilliseconds, $0) }
                ?? String(format: "gpu %.1f ms", d.gpuMilliseconds)
            let fps = d.cadenceMilliseconds > 0 ? String(format: " · %.0f fps", 1000 / d.cadenceMilliseconds) : ""
            let rkRate = RealityKitSpaceState.shared.updatesPerSecond
            if !measurement.status.isEmpty {
                Text("measure · \(measurement.step) · \(measurement.status)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(engineOpen
                ? "engine · \(d.object.isEmpty ? "placing…" : d.object)\(d.tourTime.map { String(format: " · tour %.1f s", $0) } ?? "") · frames \(d.frames)\(d.skippedFrames > 0 ? " (\(d.skippedFrames) skipped)" : "") · AA \(d.antiAliasing) ×\(d.opaqueSampleCount) · \(d.viewport.x)×\(d.viewport.y)\(d.screenSize.x > 0 ? " fov \(d.screenSize.x)×\(d.screenSize.y)" : "") · \(gpu)\(fps)\(d.compositeSkipped ? " · composite skipped" : "") · \(d.renderPath)\(d.tileLightStage ? " (tile light)" : "")"
                : (rkOpen ? "realitykit · \(Catalog.selectedID) · updates \(String(format: "%.0f", rkRate)) Hz · gpu: out of process — Instruments ▸ RealityKit Trace, with and without the object" : "no space open · \(EngineSession.shared.lastOpenResult)"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Plumbing

    /// Test hooks: `-show engine|realityKit` opens that space at launch,
    /// `-hideWindow` closes this window once it is open, `-measure` runs the
    /// measurement pass (`-measure engine` or `-measure realityKit` for one
    /// renderer). Settings take launch arguments too
    /// (`-object dart_red -placement fixed -distance 1.5 -motion tour`).
    private func handleLaunchArguments() {
        guard !measurement.launchArgumentsHandled else { return }
        measurement.launchArgumentsHandled = true
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-measure") {
            if index + 1 < arguments.count, arguments[index + 1] == "sweep" {
                Task { await measurement.sweep(show: show, windows: measurementWindows) }
                return
            }
            var phases: [Renderer] = [.engine, .realityKit]
            if index + 1 < arguments.count, let one = Renderer(rawValue: arguments[index + 1]) {
                phases = [one]
            }
            Task { await measurement.run(phases: phases, show: show, windows: measurementWindows) }
            return
        }
        guard let index = arguments.firstIndex(of: "-show"), index + 1 < arguments.count,
              let renderer = Renderer(rawValue: arguments[index + 1]) else { return }
        Task {
            await show(renderer)
            if arguments.contains("-hideWindow") { hideWindow() }
        }
    }
}

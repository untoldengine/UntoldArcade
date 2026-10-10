//
//  CoolMirrorVisionOSXRApp.swift  (visionOS)
//  CoolMirror
//
//  Virtual-mirror demo host: a rigged character stands in front of the user
//  playing animation clips, with the engine's deformation stack switchable
//  live from the control window. Later phases add live iPhone mocap so the
//  character mirrors the user's own movements.
//

import CompositorServices
import CoolMirror
import CoolMirrorMocap
import SwiftUI
import UntoldEngine
import UntoldEngineXR
import UntoldJoltPhysics

// Retains the XR system + game so they aren't deallocated.
final class XRHolder {
    static let shared = XRHolder()
    var xr: UntoldEngineXR?
    var game: CoolMirrorGame?
    var hands: CoolMirrorHandSession?
    var renderThread: Thread?
}

struct MirrorLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities _: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration)
    {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

/// UI-facing knobs; every change is pushed straight into the demo game.
@Observable
@MainActor
final class MirrorControls {
    var character: CoolMirrorCharacter = .spiderman {
        didSet {
            morphNames = []
            morphWeights = [:]
            muscleNames = []
            muscleEnabled = [:]
            muscleActivation = [:]
            hasMLDeformer = false
            if muscleMode == .mlDeformer { muscleMode = .off }
            clips = []
            clip = ""
            XRHolder.shared.game?.setCharacter(character)
        }
    }
    var skinningPath: CoolMirrorSkinningPath = .vertexShader {
        didSet { XRHolder.shared.game?.setSkinningPath(skinningPath) }
    }
    var clip: String = "" {
        didSet {
            guard !clip.isEmpty else { return }
            XRHolder.shared.game?.setClip(clip)
        }
    }
    var paused = false {
        didSet { XRHolder.shared.game?.setPaused(paused) }
    }
    var poseDrivers = true {
        didSet { XRHolder.shared.game?.setPoseDrivers(enabled: poseDrivers) }
    }
    var muscleMode: CoolMirrorMuscleMode = .off {
        didSet { XRHolder.shared.game?.setMuscleMode(muscleMode) }
    }
    var hasMLDeformer = false
    var mlWeight: Double = 1 {
        didSet { XRHolder.shared.game?.setMLDeformerWeight(Float(mlWeight)) }
    }
    var flex: Double = 0 {
        didSet { XRHolder.shared.game?.setMuscleFlex(Float(flex)) }
    }
    var showCages = false {
        didSet { XRHolder.shared.game?.setMuscleCagesVisible(showCages) }
    }
    var showMuscleList = false
    var hasCape = false
    var capeMode: CoolMirrorCapeMode = .jolt {
        didSet {
            XRHolder.shared.game?.setCapeMode(capeMode)
            // The cloth writes into the deformation pass: no vertex-shader skinning.
            if capeMode == .jolt, skinningPath == .vertexShader {
                skinningPath = .computeLBS
            }
        }
    }

    // iPhone motion capture
    var mocapEnabled = false {
        didSet {
            XRHolder.shared.game?.setMocapEnabled(mocapEnabled)
            refreshMocapStatus()
        }
    }
    var mocapMirror = true { didSet { pushMocapOptions() } }
    var mocapFlipFacing = false { didSet { pushMocapOptions() } }
    var mocapRootMotion = true { didSet { pushMocapOptions() } }
    var mocapGroundLock = true { didSet { pushMocapOptions() } }
    var mocapPlantFeet = false { didSet { pushMocapOptions() } }
    var mocapArmReach = true { didSet { pushMocapOptions() } }
    var mocapHeadAnchor = true { didSet { pushMocapOptions() } }
    var mocapHeadsetHands = true { didSet { pushMocapOptions() } }
    var mocapWeight: Double = 1 { didSet { pushMocapOptions() } }
    var mocapBodySmoothing: Double = 0.4 { didSet { pushMocapOptions() } }
    var mocapLegSmoothing: Double = 0.6 { didSet { pushMocapOptions() } }
    var mocapDebugOverlay = false {
        didSet { XRHolder.shared.game?.setMocapDebugOverlay(mocapDebugOverlay) }
    }
    var mocapStatus = "off"
    var mocapCalibrated = false
    var mocapFramed = false
    var mocapConnection = ""
    /// An iPhone is connected: the preview window is open while this holds.
    var mocapConnected = false
    var calibrationCountdown: Int?

    func pushMocapOptions() {
        XRHolder.shared.game?.setMocapOptions(
            mirror: mocapMirror, flipFacing: mocapFlipFacing, weight: Float(mocapWeight), rootMotion: mocapRootMotion,
            bodySmoothing: Float(mocapBodySmoothing), legSmoothing: Float(mocapLegSmoothing), groundLock: mocapGroundLock,
            plantFeet: mocapPlantFeet, armReach: mocapArmReach,
            headAnchor: mocapHeadAnchor, headsetHands: mocapHeadsetHands
        )
    }

    func refreshMocapStatus() {
        guard let game = XRHolder.shared.game else {
            // The mirror, and the iPhone link with it, run inside the
            // immersive space.
            mocapConnection = "○ Tap Enter Mixed Reality first: the mirror and the iPhone link run inside it."
            mocapStatus = "Waiting for the mirror to open."
            mocapFramed = false
            mocapConnected = false
            return
        }
        mocapStatus = game.mocapStatus()
        mocapCalibrated = game.mocapIsCalibrated()
        mocapFramed = game.mocapIsFramed()
        mocapConnection = game.mocapConnectionSummary()
        mocapConnected = mocapEnabled && game.mocapIsConnected()
    }


    /// Three-second countdown so the user can settle into the character's
    /// rest pose, then the next tracked frame becomes the calibration.
    func startCalibration() {
        guard calibrationCountdown == nil else { return }
        calibrationCountdown = 3
        Task { @MainActor in
            while let remaining = calibrationCountdown, remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                calibrationCountdown = remaining - 1
            }
            XRHolder.shared.game?.calibrateMocap()
            calibrationCountdown = nil
            refreshMocapStatus()
        }
    }
    // MARK: Recording a session

    /// The guided recording: what the wearer is asked to do, for how long.
    /// Each step is marked in the file, so a stretch can be replayed alone.
    static let recordingSteps: [(label: String, seconds: Int)] = [
        ("Stand still, arms down", 8),
        ("Lift your LEFT foot and hold it up", 5),
        ("Put it down. Lift your RIGHT foot and hold it up", 5),
        ("Raise both arms slowly over your head, then lower them", 8),
        ("Take two steps forward, then two steps back", 8),
        ("Turn to your left, then back to the phone", 6),
        ("Hold your hands in front of you and look at them", 5),
        ("Put your hands behind your back, then bring them in front again", 8),
        ("Look straight ahead and drop your hands to your sides, then raise them into view", 8),
        ("Stand still", 4),
    ]
    var recordingStep: String?
    var recordingCountdown = 0
    var recordingFrames = 0
    /// The last finished recording, to share.
    var recordingFile: URL?
    var recordingNote = ""
    private var recordingTask: Task<Void, Never>?

    var isRecording: Bool { recordingStep != nil }

    func startRecordingSession() {
        guard !isRecording, let game = XRHolder.shared.game else { return }
        guard let url = game.startMocapRecording() else {
            recordingNote = "Could not start the recording."
            return
        }
        recordingFile = nil
        recordingNote = "Recording to \(url.lastPathComponent)"
        recordingTask = Task { @MainActor in
            for step in Self.recordingSteps {
                guard !Task.isCancelled else { break }
                recordingStep = step.label
                game.markMocapRecording(step.label)
                for remaining in stride(from: step.seconds, to: 0, by: -1) {
                    guard !Task.isCancelled else { break }
                    recordingCountdown = remaining
                    recordingFrames = game.mocapRecordingFrameCount() ?? 0
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            finishRecording()
        }
    }

    func stopRecordingSession() {
        recordingTask?.cancel()
        recordingTask = nil
        finishRecording()
    }

    private func finishRecording() {
        guard isRecording else { return }
        recordingStep = nil
        recordingCountdown = 0
        if let result = XRHolder.shared.game?.stopMocapRecording() {
            recordingFile = result.url
            recordingFrames = result.frames
            recordingNote = "Saved \(result.frames) frames and \(result.headsetSamples) headset samples to \(result.url.lastPathComponent). Share it (AirDrop to the Mac), or find it in Files → On My Apple Vision Pro → CoolMirror."
        } else {
            recordingNote = "Nothing recorded."
        }
    }

    var muscleNames: [String] = []
    var muscleEnabled: [String: Bool] = [:]
    var muscleActivation: [String: Double] = [:]

    func setMuscleEnabled(_ name: String, _ enabled: Bool) {
        muscleEnabled[name] = enabled
        XRHolder.shared.game?.setMuscleEnabled(name: name, enabled: enabled)
    }

    func setMuscleActivation(_ name: String, _ value: Double) {
        muscleActivation[name] = value
        XRHolder.shared.game?.setMuscleActivation(name: name, value: Float(value))
    }
    var clips: [String] = []
    var morphNames: [String] = []
    var morphWeights: [String: Double] = [:]

    func setMorphWeight(_ name: String, _ weight: Double) {
        morphWeights[name] = weight
        XRHolder.shared.game?.setMorphWeight(name: name, weight: Float(weight))
    }

    func characterReady() {
        guard let game = XRHolder.shared.game else { return }
        pushMocapOptions()
        game.setMocapEnabled(mocapEnabled)
        game.setMocapDebugOverlay(mocapDebugOverlay)
        morphNames = game.morphTargetNames()
        muscleNames = game.muscleNames()
        hasMLDeformer = game.hasMLDeformer()
        hasCape = game.hasCape()
        game.setCapeMode(capeMode)
        if hasCape, capeMode == .jolt, skinningPath == .vertexShader {
            skinningPath = .computeLBS
        }
        clips = game.clipNames()
        clip = clips.first ?? ""
        paused = false
    }
}

@main
struct CoolMirrorVisionOSXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var immersionStyle: ImmersionStyle = .mixed
    @State private var controls = MirrorControls()

    var body: some SwiftUI.Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("Cool Mirror").font(.extraLargeTitle).fontWeight(.bold)
                Text("A character stands in front of you like a mirror.\nSwitch the skinning path live and compare.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)

                Button {
                    Task { await openImmersiveSpace(id: "Mirror") }
                } label: {
                    Label("Enter Mixed Reality", systemImage: "person.and.background.dotted").frame(minWidth: 260)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                #if targetEnvironment(simulator)
                // The simulator has no hands: enter the immersive space directly.
                .task { await openImmersiveSpace(id: "Mirror") }
                #endif

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        Text("Character")
                        Picker("Character", selection: $controls.character) {
                            Text("Spider-Man").tag(CoolMirrorCharacter.spiderman)
                            Text("Batman").tag(CoolMirrorCharacter.batman)
                            Text("Player").tag(CoolMirrorCharacter.redplayer)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    GridRow {
                        Text("PSD morphs")
                        Toggle(controls.poseDrivers ? "Auto (pose drivers)" : "Manual sliders", isOn: $controls.poseDrivers)
                            .toggleStyle(.button)
                            .disabled(controls.skinningPath == .vertexShader)
                    }
                    GridRow {
                        Text("Muscles")
                        Picker("Muscles", selection: $controls.muscleMode) {
                            Text("Off").tag(CoolMirrorMuscleMode.off)
                            Text("XPBD sim").tag(CoolMirrorMuscleMode.simulation)
                            Text("ML deformer").tag(CoolMirrorMuscleMode.mlDeformer)
                                .selectionDisabled(!controls.hasMLDeformer)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .disabled(controls.skinningPath == .vertexShader || controls.character == .redplayer)
                    }
                    if controls.muscleMode == .mlDeformer {
                        GridRow {
                            Text("ML blend")
                            Slider(value: $controls.mlWeight, in: 0 ... 1)
                        }
                    }
                    if controls.muscleMode == .simulation {
                        GridRow {
                            Text("Flex all")
                            Slider(value: $controls.flex, in: 0 ... 1)
                        }
                        GridRow {
                            Text("Cages")
                            HStack {
                                Toggle(controls.showCages ? "Wireframe shown" : "Hidden", isOn: $controls.showCages)
                                    .toggleStyle(.button)
                                Toggle(controls.showMuscleList ? "Hide muscle list" : "Per muscle…", isOn: $controls.showMuscleList)
                                    .toggleStyle(.button)
                            }
                        }
                    }
                    GridRow {
                        Text("Playback")
                        Toggle(controls.paused ? "Paused — compare skinning now" : "Playing", isOn: $controls.paused)
                            .toggleStyle(.button)
                            .disabled(controls.mocapEnabled)
                    }
                    if controls.hasCape {
                        GridRow {
                            Text("Cape")
                            Picker("Cape", selection: $controls.capeMode) {
                                Text("Rigid").tag(CoolMirrorCapeMode.rigid)
                                Text("Sheet").tag(CoolMirrorCapeMode.sheet)
                                Text("Jolt cloth").tag(CoolMirrorCapeMode.jolt)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    GridRow {
                        Text("iPhone")
                        Toggle(controls.mocapEnabled ? "Mirroring your body" : "Use iPhone body tracking", isOn: $controls.mocapEnabled)
                            .toggleStyle(.button)
                    }
                    if controls.mocapEnabled {
                        GridRow {
                            Text("Calibrate")
                            HStack {
                                Button {
                                    controls.startCalibration()
                                } label: {
                                    if let remaining = controls.calibrationCountdown {
                                        Text("Hold the pose… \(remaining)")
                                    } else {
                                        Text(controls.mocapCalibrated ? "Recalibrate" : "Stand upright facing the phone, then tap")
                                    }
                                }
                                .disabled(controls.calibrationCountdown != nil || !controls.mocapFramed)
                                Toggle("Mirror", isOn: $controls.mocapMirror).toggleStyle(.button)
                                Toggle("Flip", isOn: $controls.mocapFlipFacing).toggleStyle(.button)
                                Toggle("Move", isOn: $controls.mocapRootMotion).toggleStyle(.button)
                                Toggle("Ground", isOn: $controls.mocapGroundLock).toggleStyle(.button)
                                Toggle("Plant", isOn: $controls.mocapPlantFeet).toggleStyle(.button)
                                Toggle("Reach", isOn: $controls.mocapArmReach).toggleStyle(.button)
                                Toggle("Head", isOn: $controls.mocapHeadAnchor).toggleStyle(.button)
                                Toggle("Hands", isOn: $controls.mocapHeadsetHands).toggleStyle(.button)
                            }
                        }
                        GridRow {
                            Text("Record")
                            VStack(alignment: .leading, spacing: 6) {
                                if let step = controls.recordingStep {
                                    Text(step)
                                        .font(.title2.bold())
                                    HStack {
                                        Text("\(controls.recordingCountdown) s · \(controls.recordingFrames) frames")
                                            .monospacedDigit()
                                        Button("Stop") { controls.stopRecordingSession() }
                                    }
                                } else {
                                    HStack {
                                        Button("Record a guided session (~45 s)") { controls.startRecordingSession() }
                                            .disabled(!controls.mocapConnected)
                                        if let file = controls.recordingFile {
                                            ShareLink(item: file) {
                                                Label("Share recording", systemImage: "square.and.arrow.up")
                                            }
                                        }
                                    }
                                }
                                if !controls.recordingNote.isEmpty {
                                    Text(controls.recordingNote)
                                        .font(.footnote)
                                }
                            }
                        }
                        GridRow {
                            Text("Mocap blend")
                            Slider(value: $controls.mocapWeight, in: 0 ... 1)
                        }
                        GridRow {
                            Text("Smooth body")
                            Slider(value: $controls.mocapBodySmoothing, in: 0 ... 1)
                        }
                        GridRow {
                            Text("Smooth legs")
                            HStack {
                                Slider(value: $controls.mocapLegSmoothing, in: 0 ... 1)
                                Toggle("Skeleton", isOn: $controls.mocapDebugOverlay).toggleStyle(.button)
                            }
                        }
                    }
                    GridRow {
                        Text("Skinning")
                        Picker("Skinning", selection: $controls.skinningPath) {
                            Text("Vertex").tag(CoolMirrorSkinningPath.vertexShader)
                            Text("LBS").tag(CoolMirrorSkinningPath.computeLBS)
                            Text("DQS").tag(CoolMirrorSkinningPath.computeDQS)
                            Text("DDM").tag(CoolMirrorSkinningPath.computeDDM)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    if controls.clips.count > 1 {
                        GridRow {
                            Text("Clip")
                            Picker("Clip", selection: $controls.clip) {
                                ForEach(controls.clips, id: \.self) { name in
                                    Text(name.capitalized).tag(name)
                                }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                    }
                    ForEach(controls.morphNames, id: \.self) { name in
                        GridRow {
                            Text(name)
                            Slider(
                                value: Binding(
                                    get: { controls.morphWeights[name] ?? 0 },
                                    set: { controls.setMorphWeight(name, $0) }
                                ),
                                in: 0 ... 1
                            )
                            .disabled(controls.skinningPath == .vertexShader)
                        }
                    }
                }

                if controls.muscleMode == .simulation, controls.showMuscleList {
                    // Placement tuning: isolate one muscle and drive it by hand.
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(controls.muscleNames, id: \.self) { name in
                                HStack(spacing: 12) {
                                    Toggle(name, isOn: Binding(
                                        get: { controls.muscleEnabled[name] ?? true },
                                        set: { controls.setMuscleEnabled(name, $0) }
                                    ))
                                    .toggleStyle(.switch)
                                    .frame(width: 220, alignment: .leading)
                                    Slider(
                                        value: Binding(
                                            get: { controls.muscleActivation[name] ?? 0 },
                                            set: { controls.setMuscleActivation(name, $0) }
                                        ),
                                        in: 0 ... 1
                                    )
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    Text("Slider = manual activation (0 = pose driver). Switch off a muscle to take it out of the skin.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if controls.mocapEnabled {
                    Text(controls.mocapConnection)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(controls.mocapConnection.hasPrefix("●") ? Color.green : Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(controls.mocapStatus)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .task {
                            while !Task.isCancelled {
                                controls.refreshMocapStatus()
                                try? await Task.sleep(for: .milliseconds(500))
                            }
                        }
                }

                if controls.skinningPath == .vertexShader {
                    Text("Morphs need a compute skinning path (LBS/DQS/DDM).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(48)
            // The phone's picture lives in its own window, open while an
            // iPhone is connected, so the controls and the picture move
            // independently.
            .onChange(of: controls.mocapConnected) { _, connected in
                if connected {
                    openWindow(id: "MocapPreview")
                } else {
                    dismissWindow(id: "MocapPreview")
                }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 600)

        WindowGroup(id: "MocapPreview") {
            MocapPreviewWindow()
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 300)

        ImmersiveSpace(id: "Mirror") {
            CompositorLayer(configuration: MirrorLayerConfiguration()) { layerRenderer in
                guard XRHolder.shared.xr == nil else {
                    print("CoolMirror: immersive space reopened before teardown finished")
                    return
                }

                CoolMirrorGame.registerRenderPlugins()
                // The cape cloth holds with two sub-steps of a 33 ms frame
                // (the headless cape scenario checks it).
                var joltSettings = JoltWorldSettings()
                joltSettings.collisionSteps = 2
                let joltBackend = registerJoltPhysics(settings: joltSettings)
                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                XRHolder.shared.xr = xr
                xr.setImmersionMode(xrImmersionMode: .mixed)

                // The CompositorLayer renderer closure is @MainActor, so set up directly
                // here (matches the engine's XR template). The blocking render loop runs
                // on its own plain Thread — NOT the main actor.
                let game = CoolMirrorGame()
                game.setJoltBackend(joltBackend)
                XRHolder.shared.game = game
                game.onCharacterReady = { controls.characterReady() }
                game.start()
                xr.setupCallbacks(
                    gameUpdate: { dt in game.update(deltaTime: dt) },
                    handleInput: { game.handleInput() }
                )
                // The wearer's head comes from the headset itself.
                game.setMocapHeadPoseProvider { [weak xr] in
                    xr?.currentDevicePose
                }
                // Its hands too: the character's follow them.
                let hands = CoolMirrorHandSession()
                XRHolder.shared.hands = hands
                hands.start()
                game.setMocapHandProvider { [weak hands] in
                    hands?.hands ?? [:]
                }

                let t = Thread {
                    xr.start()
                    xr.runLoop()
                    // The run loop returns when the space is dismissed. Tear the
                    // engine down on the main actor so nothing keeps submitting
                    // GPU work from the background, and allow a clean reopen.
                    Task { @MainActor in
                        XRHolder.shared.hands?.stop()
                        XRHolder.shared.hands = nil
                        XRHolder.shared.game?.prepareForShutdown()
                        shutdownUntoldEngineXR(xr) {
                            XRHolder.shared.xr = nil
                            XRHolder.shared.game = nil
                            XRHolder.shared.renderThread = nil
                            print("CoolMirror: immersive space torn down, ready to reopen")
                        }
                    }
                }
                t.name = "XR Render Thread"
                t.qualityOfService = .userInteractive
                XRHolder.shared.renderThread = t
                t.start()
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}

/// The phone's picture in its own window: polls the mirror for the newest
/// picture and the framing state; shows a hint when the link goes quiet.
struct MocapPreviewWindow: View {
    @State private var preview: MocapPreviewFrame?
    @State private var framed = false

    var body: some View {
        VStack(spacing: 8) {
            Text("What the iPhone sees")
                .font(.headline)
            MocapPreviewView(preview: preview, framed: framed)
                .frame(width: 432, height: 243)
            Text(framed ? "Whole body in the picture" : "Get head, hands and feet inside the green frame")
                .font(.footnote)
                .foregroundStyle(framed ? Color.green : Color.orange)
        }
        .padding(16)
        .frame(width: 480, height: 300)
        .glassBackgroundEffect()
        .task {
            while !Task.isCancelled {
                if let game = XRHolder.shared.game {
                    let newest = game.mocapPreview()
                    if newest?.id != preview?.id {
                        preview = newest
                    }
                    framed = game.mocapIsFramed()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// What the phone sees: its camera picture with the tracked skeleton, a
/// green border when the whole body is inside, red when not.
struct MocapPreviewView: View {
    let preview: MocapPreviewFrame?
    let framed: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let preview, let image = UIImage(data: preview.jpeg) {
                    let scale = min(geometry.size.width / CGFloat(preview.width), geometry.size.height / CGFloat(preview.height))
                    let size = CGSize(width: CGFloat(preview.width) * scale, height: CGFloat(preview.height) * scale)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .overlay {
                            Canvas { context, _ in
                                for joint in MocapJoint.allCases {
                                    guard let parent = joint.parent, let a = preview.keypoints[parent], let b = preview.keypoints[joint] else { continue }
                                    var path = Path()
                                    path.move(to: CGPoint(x: CGFloat(a.x) * scale, y: CGFloat(a.y) * scale))
                                    path.addLine(to: CGPoint(x: CGFloat(b.x) * scale, y: CGFloat(b.y) * scale))
                                    context.stroke(path, with: .color(.orange), lineWidth: 2)
                                }
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(framed ? Color.green : Color.red, lineWidth: 3)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ContentUnavailableView("No picture from the iPhone yet", systemImage: "iphone.slash")
                        .font(.footnote)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

//
//  CoolZombieVisionOSXRApp.swift  (visionOS)
//  CoolZombie
//
//  Mixed-reality zombie. It waits a few meters in front of you, shambling.
//  Walk toward it — cross the trigger radius and it comes for you, stopping
//  an arm's length away. Motion matching picks every clip; nothing is
//  scripted.
//

import CompositorServices
import CoolZombieKit
import simd
import SwiftUI
import UntoldEngine
import UntoldEngineXR

// Retains the XR system + game so they aren't deallocated, and carries
// control-window actions and live diagnostics between the main actor and the
// game thread.
final class ZombieXRHolder: @unchecked Sendable {
    static let shared = ZombieXRHolder()
    var xr: UntoldEngineXR?
    var game: ZombieXRGame?
    var renderThread: Thread?
    /// Main-actor flag: the immersive space is currently open and rendering.
    var spaceOpen = false
    var lastOpenResult = "—"

    private let lock = NSLock()
    private var phaseStorage = "loading"
    private var distanceStorage: Float = .infinity
    private var trackedStorage = false
    private var floorStorage: Float = 0
    private var floorMeasuredStorage = false
    private var clipSetStorage = ""
    private var roomStorage = "—"
    private var roomSavedStorage = ""
    /// Draw the room's boxes: on by default in the simulator, where the
    /// sample room is otherwise invisible; off on the device, where the
    /// real walls are in view.
    private var showRoomStorage: Bool = {
        #if targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }()
    private var provokePending = false
    private var throwPending = false
    private var throwHard = false
    private var roomSavePending = false
    private var resetPending = false
    private var inspectionPending: ZombieChaseGame.InspectionMode?
    private var clipSetPending: ZombieResources.ClipSet?

    // MARK: Game-thread writers

    func setDiagnostics(phase: String, distance: Float, tracked: Bool, floor: Float, floorMeasured: Bool, clipSet: String, position: simd_float3, meshFloor: Float?, planeFloor: Float?, floorSource: String) {
        lock.withLock {
            phaseStorage = phase
            distanceStorage = distance
            trackedStorage = tracked
            floorStorage = floor
            floorMeasuredStorage = floorMeasured
            clipSetStorage = clipSet
            positionStorage = position
            meshFloorStorage = meshFloor
            planeFloorStorage = planeFloor
            floorSourceStorage = floorSource
        }
    }

    /// Which estimate the floor in use came from ("mesh", "plane" or "assumed").
    var floorSource: String { lock.withLock { floorSourceStorage } }
    private var floorSourceStorage = "assumed"
    /// The plane detector's height, next to the mesh's.
    var planeFloor: Float? { lock.withLock { planeFloorStorage } }
    private var planeFloorStorage: Float?

    /// The floor height the scene mesh gives, next to the plane's.
    var meshFloor: Float? { lock.withLock { meshFloorStorage } }
    private var meshFloorStorage: Float?

    /// A manual offset on the detected floor, metres, from the window's
    /// stepper: the trim that puts the soles on the real floor is the
    /// plane's bias.
    var floorTrim: Float { lock.withLock { floorTrimStorage } }
    /// Zero by default and never remembered: the plane's bias is a property
    /// of each floor (a centimetre either way between rooms), so the game
    /// calibrates at run time from the scene mesh instead (`ZombieXRGame`),
    /// and the stepper is for checking that.
    private var floorTrimStorage: Float = 0
    func setFloorTrim(_ trim: Float) { lock.withLock { floorTrimStorage = trim } }

    /// The zombie's world position, for telling a body that moves from a
    /// world that moves under it: if it drifts on screen while these
    /// numbers hold, the tracking corrected the world, not the game.
    var position: simd_float3 { lock.withLock { positionStorage } }
    private var positionStorage = simd_float3.zero

    func setRoomDiagnostics(room: String, saved: String) {
        lock.withLock {
            roomStorage = room
            roomSavedStorage = saved
        }
    }

    // MARK: Control-window API

    var phase: String { lock.withLock { phaseStorage } }
    var room: String { lock.withLock { roomStorage } }
    var roomSaved: String { lock.withLock { roomSavedStorage } }
    var showRoom: Bool { lock.withLock { showRoomStorage } }
    /// The floor plane the headset detected, drawn as a thin green slab at
    /// the height the zombie stands on: whether the feet float because of
    /// the floor estimate, the model or the clips is then a matter of
    /// looking.
    var showFloor: Bool { lock.withLock { showFloorStorage } }
    private var showFloorStorage = false

    func setShowRoom(_ show: Bool) { lock.withLock { showRoomStorage = show } }
    func setShowFloor(_ show: Bool) { lock.withLock { showFloorStorage = show } }
    func requestRoomSave() { lock.withLock { roomSavePending = true } }

    func takeRoomSaveRequest() -> Bool {
        lock.withLock {
            let pending = roomSavePending
            roomSavePending = false
            return pending
        }
    }

    var distance: Float { lock.withLock { distanceStorage } }
    var headTracked: Bool { lock.withLock { trackedStorage } }
    var floor: Float { lock.withLock { floorStorage } }
    var floorMeasured: Bool { lock.withLock { floorMeasuredStorage } }
    var clipSet: String { lock.withLock { clipSetStorage } }

    func requestProvoke() { lock.withLock { provokePending = true } }
    func requestReset() { lock.withLock { resetPending = true } }
    /// A ball from the head at the zombie: a toss makes it flinch, a hard
    /// throw knocks it down.
    /// The force the next throw uses — the window's Toss/Throw choice — and
    /// a throw of it, from the window's button or a pinch in the room.
    func setThrowForce(hard: Bool) { lock.withLock { throwHard = hard } }
    var throwsHard: Bool { lock.withLock { throwHard } }
    func requestThrow() { lock.withLock { throwPending = true } }

    /// Non-nil once per requested throw (the force is read separately).
    func takeThrowRequest() -> Bool? {
        lock.withLock {
            guard throwPending else { return nil }
            throwPending = false
            return throwHard
        }
    }

    func takeProvokeRequest() -> Bool {
        lock.withLock {
            let pending = provokePending
            provokePending = false
            return pending
        }
    }

    func takeResetRequest() -> Bool {
        lock.withLock {
            let pending = resetPending
            resetPending = false
            return pending
        }
    }

    /// Inspection modes (roam, idle, freeze) ignore the player so the
    /// character can be looked at without being chased.
    func requestInspection(_ mode: ZombieChaseGame.InspectionMode) {
        lock.withLock { inspectionPending = mode }
    }

    func takeInspectionRequest() -> ZombieChaseGame.InspectionMode? {
        lock.withLock {
            let pending = inspectionPending
            inspectionPending = nil
            return pending
        }
    }

    /// The clip set chosen in the control window; the game applies it on
    /// its own thread.
    func requestClipSet(_ set: ZombieResources.ClipSet) {
        lock.withLock { clipSetPending = set }
    }

    /// The engine's pose-timing knobs, switched live from the window: for
    /// telling the presentation from the tracking when the body sways
    /// against the room while its coordinates hold.
    private var inputWaitPending: XRInputWaitMode?
    private var framePacingPending: XRFramePacing?

    func requestInputWait(_ mode: XRInputWaitMode) { lock.withLock { inputWaitPending = mode } }
    private var antiAliasingPending: AntiAliasingMode?
    func requestAntiAliasing(_ mode: AntiAliasingMode) { lock.withLock { antiAliasingPending = mode } }
    func takeAntiAliasingRequest() -> AntiAliasingMode? {
        lock.withLock { defer { antiAliasingPending = nil }; return antiAliasingPending }
    }
    func requestFramePacing(_ pacing: XRFramePacing) { lock.withLock { framePacingPending = pacing } }

    func takeInputWaitRequest() -> XRInputWaitMode? {
        lock.withLock { defer { inputWaitPending = nil }; return inputWaitPending }
    }

    func takeFramePacingRequest() -> XRFramePacing? {
        lock.withLock { defer { framePacingPending = nil }; return framePacingPending }
    }

    func takeClipSetRequest() -> ZombieResources.ClipSet? {
        lock.withLock {
            let pending = clipSetPending
            clipSetPending = nil
            return pending
        }
    }
}

/// The footnote under the phase readout, assembled in pieces: one long
/// `+` chain is more than the type checker solves in reasonable time.
@MainActor
func diagnosticsLine(_ holder: ZombieXRHolder) -> String {
    var parts: [String] = []
    parts.append("Space \(holder.spaceOpen ? "OPEN" : "closed") (last open: \(holder.lastOpenResult))")
    parts.append("head \(holder.headTracked ? "tracked" : "—")")
    if holder.distance.isFinite {
        parts.append(String(format: "distance %.2f m", holder.distance))
    }
    parts.append(String(format: "floor %+.3f m (%@, plane %@, mesh %@, trim %+.1f cm)", holder.floor, holder.floorSource,
                        holder.planeFloor.map { String(format: "%+.3f", $0) } ?? "—",
                        holder.meshFloor.map { String(format: "%+.3f", $0) } ?? "—", holder.floorTrim * 100))
    parts.append(String(format: "zombie (%+.2f, %+.3f, %+.2f)", holder.position.x, holder.position.y, holder.position.z))
    parts.append("clips \(holder.clipSet)")
    parts.append("room: \(holder.room)")
    if !holder.roomSaved.isEmpty {
        parts.append("saved \(holder.roomSaved)")
    }
    return parts.joined(separator: " · ")
}

/// Control-window choices for the engine's pose timing.
enum InputWaitChoice: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case wait = "Wait"
    case noWait = "No wait"
    var id: String { rawValue }
    var mode: XRInputWaitMode {
        switch self {
        case .auto: return .automatic
        case .wait: return .always
        case .noWait: return .never
        }
    }
}

enum AntiAliasingChoice: String, CaseIterable, Identifiable {
    case taa = "TAA"
    case fxaa = "FXAA"
    case none = "No AA"
    var id: String { rawValue }
    var mode: AntiAliasingMode {
        switch self {
        case .taa: return .taa
        case .fxaa: return .fxaa
        case .none: return .none
        }
    }
}

enum PacingChoice: String, CaseIterable, Identifiable {
    case full = "Full rate"
    case halfWhenLate = "Half if late"
    case half = "Half rate"
    var id: String { rawValue }
    var pacing: XRFramePacing {
        switch self {
        case .full: return .fullRate
        case .halfWhenLate: return .halfRateWhenLate
        case .half: return .halfRate
        }
    }
}

/// Control-window choice; maps onto the game's inspection modes.
enum InspectionChoice: String, CaseIterable, Identifiable {
    case chase = "Chase"
    case roam = "Roam"
    case idle = "Idle"
    case freeze = "Freeze"
    /// The model's bind pose (an A-pose), no clip: the asset as exported.
    case bindPose = "T-pose"

    var id: String { rawValue }

    func mode(speed: ZombieChaseGame.RoamSpeed) -> ZombieChaseGame.InspectionMode {
        switch self {
        case .chase: return .chase
        case .roam: return .roaming(speed)
        case .idle: return .idling
        case .freeze: return .frozen
        case .bindPose: return .bindPose
        }
    }
}

struct ZombieLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

@main
struct CoolZombieVisionOSXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var immersionStyle: ImmersionStyle = .mixed
    @State private var inspection: InspectionChoice = .chase
    @State private var roamSpeed: ZombieChaseGame.RoamSpeed = .walk
    @State private var clipSet: ZombieResources.ClipSet = ZombieResources.clipSet
    @State private var showRoom = ZombieXRHolder.shared.showRoom
    @State private var showFloor = ZombieXRHolder.shared.showFloor
    @State private var floorTrim: Float = ZombieXRHolder.shared.floorTrim
    @State private var inputWait: InputWaitChoice = .auto
    @State private var pacing: PacingChoice = .full
    @State private var antiAliasing: AntiAliasingChoice = .taa
    @State private var throwHard = false
    private let clipSets = ZombieResources.availableClipSets

    var body: some SwiftUI.Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Cool Zombie 🧟").font(.extraLargeTitle).fontWeight(.bold)
                    Text("A zombie waits a few meters in front of you. Walk toward it —\nget close and it comes for you. Motion matching picks every clip;\nnothing is scripted.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)

                    Button {
                        Task {
                            let result = await openImmersiveSpace(id: "Room")
                            ZombieXRHolder.shared.lastOpenResult = String(describing: result)
                            print("CoolZombie: openImmersiveSpace → \(String(describing: result))")
                        }
                    } label: {
                        Label("Enter the room", systemImage: "figure.walk")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)

                    Divider()

                    HStack(spacing: 16) {
                        Button("Provoke it") {
                            ZombieXRHolder.shared.requestProvoke()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Reset") {
                            inspection = .chase
                            ZombieXRHolder.shared.requestReset()
                        }
                        .buttonStyle(.bordered)

                        Button("Throw") {
                            ZombieXRHolder.shared.requestThrow()
                        }
                        .buttonStyle(.bordered)
                    }

                    // The ball: pick the force here, then pinch anywhere in
                    // the room to throw where you look. The button throws
                    // too, for the simulator and for a throw at the chest.
                    VStack(spacing: 6) {
                        Picker("Ball", selection: $throwHard) {
                            Text("Toss").tag(false)
                            Text("Throw hard").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                        .onChange(of: throwHard) { _, hard in
                            ZombieXRHolder.shared.setThrowForce(hard: hard)
                        }
                        Text("Pinch anywhere in the room to throw where you look.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    // Inspection: none of these modes target you. Roam walks
                    // a circle around the spawn at the chosen speed, Idle
                    // stands in the idle clip, Freeze holds the current pose,
                    // T-pose holds the model's bind pose with no clip at all
                    // (are the feet on the floor in the asset, or only in
                    // the clips?).
                    VStack(spacing: 10) {
                        Picker("Mode", selection: $inspection) {
                            ForEach(InspectionChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        .onChange(of: inspection) { _, choice in
                            ZombieXRHolder.shared.requestInspection(choice.mode(speed: roamSpeed))
                        }
                        Picker("Speed", selection: $roamSpeed) {
                            Text("Walk").tag(ZombieChaseGame.RoamSpeed.walk)
                            Text("Jog").tag(ZombieChaseGame.RoamSpeed.jog)
                            Text("Run").tag(ZombieChaseGame.RoamSpeed.run)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                        .disabled(inspection != .roam)
                        .onChange(of: roamSpeed) { _, speed in
                            if inspection == .roam { ZombieXRHolder.shared.requestInspection(.roaming(speed)) }
                        }
                    }

                    // Clip set: the motion data the matcher draws from. All
                    // sets are loaded at start, so switching rebuilds the
                    // database in place (a brief hitch) and the zombie
                    // re-matches into the new clips.
                    if clipSets.count > 1 {
                        Picker("Clips", selection: $clipSet) {
                            ForEach(clipSets) { set in
                                Text(set.title).tag(set)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        .onChange(of: clipSet) { _, set in
                            ZombieXRHolder.shared.requestClipSet(set)
                        }
                    }

                    // Pose timing: when the body sways against the room while
                    // the footnote's coordinates hold, these tell the engine's
                    // presentation from the tracking. Wait takes the pose at the
                    // compositor's optimal input time (lowest latency, more late
                    // frames); half rate gives each frame twice the budget.
                    VStack(spacing: 10) {
                        Picker("Pose", selection: $inputWait) {
                            ForEach(InputWaitChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        .onChange(of: inputWait) { _, choice in
                            ZombieXRHolder.shared.requestInputWait(choice.mode)
                        }
                        Picker("Pacing", selection: $pacing) {
                            ForEach(PacingChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        .onChange(of: pacing) { _, choice in
                            ZombieXRHolder.shared.requestFramePacing(choice.pacing)
                        }
                        // Temporal anti-aliasing blends each frame with its
                        // reprojected history: a history that lands off makes a
                        // still object swim. Off, the swim goes with it.
                        Picker("AA", selection: $antiAliasing) {
                            ForEach(AntiAliasingChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        .onChange(of: antiAliasing) { _, choice in
                            ZombieXRHolder.shared.requestAntiAliasing(choice.mode)
                        }
                    }

                    // The room. On the device the walls and furniture ARKit
                    // detects are the boxes the zombie routes around and
                    // plants its hands on; Show draws them, translucent, to
                    // check the alignment. Save writes the layout to the
                    // app's Documents folder (the Files app lists it) for
                    // the Mac sandbox's `-layoutFile`. The simulator detects
                    // nothing and gets the bundled sample room instead.
                    VStack(spacing: 10) {
                        Toggle("Show the room's boxes", isOn: $showRoom)
                            .frame(maxWidth: 420)
                            .onChange(of: showRoom) { _, show in
                                ZombieXRHolder.shared.setShowRoom(show)
                            }
                        // The detected floor plane as a green slab at the height
                        // the zombie stands on: if the slab sits above the real
                        // floor, the feet float because of the floor estimate.
                        Toggle("Show the detected floor", isOn: $showFloor)
                            .frame(maxWidth: 420)
                            .onChange(of: showFloor) { _, show in
                                ZombieXRHolder.shared.setShowFloor(show)
                            }
                        // Nudge the floor the zombie stands on by 5 mm steps until
                        // the soles sit right; the trim that does it is the plane
                        // detector's bias, and the footnote shows the mesh's own
                        // floor height next to it.
                        Stepper(String(format: "Floor trim %+.1f cm", floorTrim * 100),
                                onIncrement: { floorTrim += 0.005; ZombieXRHolder.shared.setFloorTrim(floorTrim) },
                                onDecrement: { floorTrim -= 0.005; ZombieXRHolder.shared.setFloorTrim(floorTrim) })
                            .frame(maxWidth: 420)
                        Button("Save the room") {
                            ZombieXRHolder.shared.requestRoomSave()
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider()

                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let holder = ZombieXRHolder.shared
                        VStack(spacing: 8) {
                            Text(holder.phase.capitalized)
                                .font(.title2.monospacedDigit()).fontWeight(.semibold)
                            Text(diagnosticsLine(holder))
                            .font(.footnote.monospaced())
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(48)
                .onAppear {
                    // Test hook: `-autoOpenSpace` opens the immersive space
                    // immediately, so automated simulator runs don't depend
                    // on synthesizing a gaze-and-pinch on the button.
                    guard ProcessInfo.processInfo.arguments.contains("-autoOpenSpace"),
                          !ZombieXRHolder.shared.spaceOpen else { return }
                    Task {
                        let result = await openImmersiveSpace(id: "Room")
                        ZombieXRHolder.shared.lastOpenResult = String(describing: result)
                        print("CoolZombie: auto-open → \(String(describing: result))")
                    }
                }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 440)

        ImmersiveSpace(id: "Room") {
            CompositorLayer(configuration: ZombieLayerConfiguration()) { layerRenderer in
                guard ZombieXRHolder.shared.xr == nil else {
                    print("CoolZombie: immersive space reopened before teardown finished")
                    return
                }

                // The game first: it installs the physics backend, which the
                // registry wants in place before the renderer is created.
                let game = ZombieXRGame()

                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                ZombieXRHolder.shared.xr = xr
                ZombieXRHolder.shared.spaceOpen = true
                xr.setImmersionMode(xrImmersionMode: .mixed)
                // Pinches in the room reach the layer as spatial events only
                // once the engine is told to take them, and only while the
                // scene counts as ready — which the engine's teardown clears
                // when the space closes, so say so again on every open.
                registerXREvents()
                setSceneReady(true)

                // Scene construction is main-actor (the CompositorLayer closure
                // is); per-frame updates run on the XR render thread.
                game.game.setupScene()
                ZombieXRHolder.shared.game = game
                game.start()
                xr.setupCallbacks(
                    gameUpdate: { dt in game.update(deltaTime: dt) },
                    handleInput: {}
                )

                let thread = Thread {
                    xr.start()
                    xr.runLoop()
                    // The layer was invalidated: the space closed (crown press,
                    // system dismiss). Tear down so the next open rebuilds
                    // cleanly instead of hitting a dead renderer.
                    game.shutdown()
                    Task { @MainActor in
                        ZombieXRHolder.shared.spaceOpen = false
                        shutdownUntoldEngineXR(xr) {
                            ZombieXRHolder.shared.xr = nil
                            ZombieXRHolder.shared.game = nil
                            ZombieXRHolder.shared.renderThread = nil
                            print("CoolZombie: immersive space torn down, ready to reopen")
                        }
                    }
                }
                thread.name = "XR Render Thread"
                thread.qualityOfService = .userInteractive
                ZombieXRHolder.shared.renderThread = thread
                thread.start()
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}

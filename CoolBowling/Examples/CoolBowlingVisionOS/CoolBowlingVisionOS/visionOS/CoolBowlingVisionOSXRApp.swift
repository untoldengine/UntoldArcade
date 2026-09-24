//
//  CoolBowlingVisionOSXRApp.swift  (visionOS)
//  CoolBowling
//
//  Mixed-reality bowling on the Jolt Physics plugin. Place a lane on your
//  real floor, pick the ball up with a pinch and roll it; ten real rigid-body
//  pins wobble, topple and knock each other over.
//

import CompositorServices
import CoolBowling
import simd
import SwiftUI
import UntoldEngine
import UntoldEngineXR

// Retains the XR system + game so they aren't deallocated, and carries
// control-window actions and live diagnostics between the main actor and the
// game thread.
final class BowlingXRHolder: @unchecked Sendable {
    static let shared = BowlingXRHolder()
    var xr: UntoldEngineXR?
    var game: BowlingXRGame?
    var renderThread: Thread?
    var spaceOpen = false
    var lastOpenResult = "—"

    private let lock = NSLock()
    private var pinsDownStorage = 0
    private var frameStorage = 1
    private var ballStorage = 1
    private var planeStorage = 0
    private var impulseStorage: Float = 0
    private var placingStorage = true
    private var placeLanePending = false
    private var moveLanePending = false
    private var newBallPending = false
    private var resetPinsPending = false

    func setDiagnostics(pinsDown: Int, frame: Int, ball: Int, planes: Int, impulse: Float, placing: Bool) {
        lock.withLock {
            pinsDownStorage = pinsDown
            frameStorage = frame
            ballStorage = ball
            planeStorage = planes
            impulseStorage = impulse
            placingStorage = placing
        }
    }

    func resetDiagnostics() {
        lock.withLock {
            pinsDownStorage = 0
            planeStorage = 0
            impulseStorage = 0
        }
    }

    var pinsDown: Int { lock.withLock { pinsDownStorage } }
    var frame: Int { lock.withLock { frameStorage } }
    var ballInFrame: Int { lock.withLock { ballStorage } }
    var isPlacingLane: Bool { lock.withLock { placingStorage } }
    var planeCount: Int { lock.withLock { planeStorage } }
    var lastImpulse: Float { lock.withLock { impulseStorage } }

    func requestPlaceLane() { lock.withLock { placeLanePending = true } }
    func requestMoveLane() { lock.withLock { moveLanePending = true } }
    func requestNewBall() { lock.withLock { newBallPending = true } }
    func requestResetPins() { lock.withLock { resetPinsPending = true } }

    func takePlaceLaneRequest() -> Bool { lock.withLock { defer { placeLanePending = false }; return placeLanePending } }
    func takeMoveLaneRequest() -> Bool { lock.withLock { defer { moveLanePending = false }; return moveLanePending } }
    func takeNewBallRequest() -> Bool { lock.withLock { defer { newBallPending = false }; return newBallPending } }
    func takeResetPinsRequest() -> Bool { lock.withLock { defer { resetPinsPending = false }; return resetPinsPending } }

    /// Releases a session the system closed (the Digital Crown). Once
    /// `runLoop()` has returned no frame runs again, and the engine's
    /// deferred teardown (`shutdownUntoldEngineXR`, whose completion fires
    /// from a frame's finalize pass) would never complete — the holder would
    /// keep the old session and refuse to reopen. So it is released here and
    /// now, the engine's own stale-session pattern: the entities are marked
    /// and finalized by the next session's first frames. Main actor.
    func releaseSession() {
        if let xr {
            setRendering(.extensions(.removeAll))
            xr.clearSpatialInput()
            xr.stop()
        }
        destroyAllEntities()
        xr = nil
        game = nil
        renderThread = nil
        spaceOpen = false
    }
}

struct BowlingLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

@main
struct CoolBowlingVisionOSXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some SwiftUI.Scene {
        WindowGroup(id: "Controls") {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Cool Bowling 🎳").font(.extraLargeTitle).fontWeight(.bold)
                    Text("First, place your lane: look at the floor where the foul line should be — the ghost lane\nruns away from you — and pinch (or press Place lane here). Then pinch the ball off the rack\non your right and roll it down the lane: the pit swallows it and the return brings it back.\nTwo balls a frame; ten real pins on Jolt Physics.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)

                    Button {
                        Task {
                            let result = await openImmersiveSpace(id: "Lane")
                            BowlingXRHolder.shared.lastOpenResult = String(describing: result)
                            print("CoolBowling: openImmersiveSpace → \(String(describing: result))")
                        }
                    } label: {
                        Label("Step onto the Lane", systemImage: "figure.bowling")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)

                    Divider()

                    HStack(spacing: 16) {
                        Button("Place lane here") { BowlingXRHolder.shared.requestPlaceLane() }
                            .buttonStyle(.borderedProminent)
                        Button("Move lane") { BowlingXRHolder.shared.requestMoveLane() }
                            .buttonStyle(.bordered)
                    }
                    HStack(spacing: 16) {
                        Button("New ball") { BowlingXRHolder.shared.requestNewBall() }
                            .buttonStyle(.bordered)
                        Button("Reset pins") { BowlingXRHolder.shared.requestResetPins() }
                            .buttonStyle(.bordered)
                    }

                    Divider()

                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let holder = BowlingXRHolder.shared
                        VStack(spacing: 8) {
                            Text(holder.isPlacingLane ? "Placing the lane…" : "Frame \(holder.frame) · Ball \(holder.ballInFrame) · Pins down: \(holder.pinsDown) / 10")
                                .font(.title2.monospacedDigit()).fontWeight(.semibold)
                            Text(
                                "Space \(holder.spaceOpen ? "OPEN" : "closed")"
                                    + " (last open: \(holder.lastOpenResult))"
                                    + " · physics Jolt"
                                    + " · surfaces \(holder.planeCount)"
                                    + String(format: " · last impact %.2f N·s", holder.lastImpulse)
                            )
                            .font(.footnote.monospaced())
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(48)
                .onAppear {
                    // Test hook: `-autoOpenSpace` opens the immersive space at
                    // launch, so automated simulator runs don't depend on
                    // synthesizing a gaze-and-pinch on the button.
                    guard ProcessInfo.processInfo.arguments.contains("-autoOpenSpace"),
                          !BowlingXRHolder.shared.spaceOpen else { return }
                    Task {
                        let result = await openImmersiveSpace(id: "Lane")
                        BowlingXRHolder.shared.lastOpenResult = String(describing: result)
                        print("CoolBowling: auto-open → \(String(describing: result))")
                        // `-hideWindow` also closes this control window so an
                        // unattended screenshot sees the lane, not the glass.
                        if ProcessInfo.processInfo.arguments.contains("-hideWindow") {
                            dismissWindow(id: "Controls")
                        }
                    }
                }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 480)

        ImmersiveSpace(id: "Lane") {
            CompositorLayer(configuration: BowlingLayerConfiguration()) { layerRenderer in
                if BowlingXRHolder.shared.xr != nil {
                    // Reopened before the last session's release ran.
                    print("CoolBowling: releasing the previous session first")
                    BowlingXRHolder.shared.releaseSession()
                }
                let game = BowlingXRGame()
                // The physics backend must install before the renderer exists.
                guard game.game.installPhysics() else { return }
                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                BowlingXRHolder.shared.xr = xr
                BowlingXRHolder.shared.spaceOpen = true
                xr.setImmersionMode(xrImmersionMode: .mixed)

                game.game.setupScene()
                BowlingXRHolder.shared.game = game
                game.start()
                xr.setupCallbacks(
                    gameUpdate: { dt in game.update(deltaTime: dt) },
                    handleInput: { game.handleInput() }
                )

                let thread = Thread {
                    xr.start()
                    xr.runLoop()
                    game.shutdown()
                    Task { @MainActor in
                        BowlingXRHolder.shared.releaseSession()
                        print("CoolBowling: immersive space torn down, ready to reopen")
                    }
                }
                thread.name = "XR Render Thread"
                thread.qualityOfService = .userInteractive
                BowlingXRHolder.shared.renderThread = thread
                thread.start()
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}

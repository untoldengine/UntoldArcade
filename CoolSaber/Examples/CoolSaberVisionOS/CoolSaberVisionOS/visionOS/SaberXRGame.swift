//
//  SaberXRGame.swift  (visionOS)
//  CoolSaber
//
//  Per-frame duel logic, driven from the XR render thread:
//    PSVR2 poses → blade segments → plugin slots; trigger edges → ignition;
//    segment-segment distance → clash sparks/haptics/audio; SharePlay mailbox
//    in both directions. Solo practice works with no session at all.
//
//  Coordinates: the engine's XR world frame is ARKit's world origin (on the
//  floor beneath the user at immersive-space open). PSVR2 poses arrive in the
//  same frame. With spatial Personas in a group immersive space the origin is
//  shared across participants, so remote blade poses render raw; otherwise
//  they are re-based onto a fixed opponent anchor 2 m in front, facing us.
//

import CoolSaber
import Foundation
@preconcurrency import GameController
import simd
import UntoldEngine

/// Per-wand trigger input read straight from GameController. The engine folds
/// both Sense wands into one merged GameControllerState assuming side-prefixed
/// element names ("Left Trigger"/"Right Trigger"); real wands expose their own
/// unprefixed elements, so per-hand ignite must bind per GCController.
final class SaberWandInput: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingToggles: [SaberHand] = []
    private var assignedHands: [ObjectIdentifier: SaberHand] = [:]
    private var boundElements: Set<ObjectIdentifier> = []
    private var lastToggleUptime: [ObjectIdentifier: TimeInterval] = [:]
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.attach(controller)
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            self.lock.withLock {
                _ = self.assignedHands.removeValue(forKey: ObjectIdentifier(controller))
            }
        })
        for controller in GCController.controllers() {
            attach(controller)
        }
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        lock.withLock {
            assignedHands.removeAll()
            pendingToggles.removeAll()
        }
    }

    /// Trigger presses since the last call, as the hand each belongs to.
    func takeToggles() -> [SaberHand] {
        lock.withLock {
            let toggles = pendingToggles
            pendingToggles.removeAll()
            return toggles
        }
    }

    /// Handedness from the vendor name ("...Left...", "(L)") or, failing that,
    /// from side-prefixed element names appearing exclusively.
    static func inferHand(of controller: GCController) -> SaberHand? {
        let vendor = (controller.vendorName ?? "").lowercased()
        if vendor.contains("left") || vendor.hasSuffix("(l)") { return .left }
        if vendor.contains("right") || vendor.hasSuffix("(r)") { return .right }
        let keys = controller.physicalInputProfile.buttons.keys.map { $0.lowercased() }
        let hasLeft = keys.contains { $0.hasPrefix("left") }
        let hasRight = keys.contains { $0.hasPrefix("right") }
        if hasLeft != hasRight { return hasLeft ? .left : .right }
        return nil
    }

    private func attach(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        let alreadyAttached = lock.withLock { assignedHands[key] != nil }
        guard !alreadyAttached else { return }

        let hand = Self.inferHand(of: controller) ?? nextFreeHand()
        lock.withLock { assignedHands[key] = hand }

        let buttons = controller.physicalInputProfile.buttons
        print(
            "CoolSaber: wand '\(controller.vendorName ?? "?")' → \(hand), "
                + "elements: \(buttons.keys.sorted())"
        )

        for (name, button) in buttons {
            let lower = name.lowercased()
            // The wand's trigger may surface as "Trigger", side-prefixed, or
            // via a "Button A"/"Cross" alias depending on firmware — accept
            // any of them; each toggles only this wand's blade.
            let isTrigger = lower.contains("trigger")
            let isPrimary = lower == "button a" || lower == "a" || lower == "cross"
            guard isTrigger || isPrimary,
                  !lower.contains("grip"), !lower.contains("shoulder")
            else { continue }

            // Aliases share the element object: bind each element once.
            let elementKey = ObjectIdentifier(button)
            let alreadyBound = lock.withLock { !boundElements.insert(elementKey).inserted }
            guard !alreadyBound else { continue }

            // If one GCController carries both sides' triggers, the element
            // prefix wins over the controller-level assignment.
            let target: SaberHand
            if lower.hasPrefix("left") {
                target = .left
            } else if lower.hasPrefix("right") {
                target = .right
            } else {
                target = hand
            }
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed, let self else { return }
                self.enqueueToggle(target, controllerKey: key)
            }
        }
    }

    /// One physical press can reach us through several distinct elements
    /// (analog trigger + click + alias); debounce per controller so it
    /// produces exactly one toggle.
    private func enqueueToggle(_ hand: SaberHand, controllerKey: ObjectIdentifier) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            if let last = lastToggleUptime[controllerKey], now - last < 0.3 { return }
            lastToggleUptime[controllerKey] = now
            pendingToggles.append(hand)
        }
    }

    private func nextFreeHand() -> SaberHand {
        lock.withLock {
            assignedHands.values.contains(.left) ? .right : .left
        }
    }
}

/// Everything worth tweaking on hardware lives here.
struct SaberTuning {
    /// Blade start relative to the controller pose (controller-local metres):
    /// just above the fist, at the top of the controller ring.
    func gripOffsetLocal(hand: Int) -> SIMD3<Float> {
        SaberXRHolder.shared.fit(forHand: hand).gripOffset
    }
    /// Blade direction in controller-local space, from the fit angles set in
    /// the control window. Tilt rotates from +Y (out of the fist) toward -Z
    /// (the controller's forward: 0° vertical grip, 90° arm extension); lean
    /// then swings that tilted direction left/right around the controller's
    /// up axis — the sideways correction tilt alone can't express.
    func bladeAxisLocal(hand: Int) -> SIMD3<Float> {
        let fit = SaberXRHolder.shared.fit(forHand: hand)
        let tilt = fit.tiltDegrees * .pi / 180
        let lean = fit.leanDegrees * .pi / 180
        return SIMD3<Float>(
            -sin(tilt) * sin(lean),
            cos(tilt),
            -sin(tilt) * cos(lean)
        )
    }
    var fullLength: Float = 0.95
    var coreRadius: Float = 0.02
    var clashTriggerDistance: Float = 0.05
    var remoteColor = SIMD3<Float>(1.0, 0.22, 0.15)
    var glowIntensity: Float = 4
    /// Keep an untracked blade at its last pose this long before retracting.
    var untrackedGrace: Float = 1.0
}

final class SaberXRGame {
    private struct HandState {
        var ignitedTarget = false
        var ignition = CoolSaberIgnition()
        var hilt = SIMD3<Float>(0, 1.1, -0.4)
        var direction = SIMD3<Float>(0, 1, 0)
        var lastTip = SIMD3<Float>(0, 1.1, -0.4)
        var tipSpeed: Float = 0
        var untrackedTime: Float = 0
        var everTracked = false
    }

    private struct RemoteHandState {
        var ignition = CoolSaberIgnition()
        var hilt = SIMD3<Float>(0, 0, 0)
        var direction = SIMD3<Float>(0, 1, 0)
        var wire = SaberBladeWire()
        var hasPose = false
    }

    var tuning = SaberTuning()

    private let mailbox = SaberDuelMailbox.shared
    private let audio = SaberAudio()
    private let haptics = SaberHaptics()
    private let wandInput = SaberWandInput()

    private var localHands: [HandState] = [HandState(), HandState()] // left, right
    private var remoteHands: [RemoteHandState] = [RemoteHandState(), RemoteHandState()]
    private var clashDetector: CoolSaberClashDetector
    private var sequence: UInt32 = 0
    private var sendAccumulator: Float = 0
    private var lastLocalClashUptime: TimeInterval = 0
    private var loggedControllerState = false
    private var spinnerAccumulator: Float = 0
    private var elapsed: Float = 0

    init() {
        clashDetector = CoolSaberClashDetector(triggerDistance: 0.05)
    }

    func start() {
        clashDetector.triggerDistance = tuning.clashTriggerDistance
        SaberXRHolder.shared.wandsEverTracked = false

        // Without these the engine drops all spatial input events.
        registerXREvents()
        setSceneReady(true)

        audio.start()
        haptics.start()
        wandInput.start()

        print(
            "CoolSaber: starting — trigger or Cross ignites that hand's blade. "
                + "PSVR2 connected: \(isPSVR2SenseConnected())"
        )
    }

    func shutdown() {
        audio.stop()
        haptics.stop()
        wandInput.stop()
        clearCoolSaberScene()
    }

    var localColor: SIMD3<Float> {
        SaberXRHolder.shared.localColor
    }

    // MARK: - Per frame

    func update(deltaTime: Float) {
        let dt = min(max(deltaTime, 0), 1.0 / 30.0)
        elapsed += dt

        updateLocalInput(dt: dt)
        updateLoadingSpinner(dt: dt)
        updateRemote(dt: dt)
        publishBlades()
        detectClashes(dt: dt)
        updateAudio()
        sendPoses(dt: dt)
    }

    func handleInput() {}

    // MARK: - Local controllers

    private func updateLocalInput(dt: Float) {
        let sense = getPSVR2SenseState()
        let pad = getGameControllerState()

        if sense.isConnected, !loggedControllerState {
            loggedControllerState = true
            // One-shot dump so the per-hand trigger mapping is verifiable on device.
            print(
                "CoolSaber: PSVR2 connected — LT=\(pad.leftTriggerValue) RT=\(pad.rightTriggerValue) "
                    + "A=\(pad.aPressed) leftTracked=\(sense.left.isTracked) rightTracked=\(sense.right.isTracked)"
            )
        }

        // Per-wand presses, read directly from each GCController so each
        // saber ignites independently. No merged-state fallback: the wand's
        // trigger surfaces as a "Button A" alias on real firmware, so a
        // toggle-both path on aPressed would fire on every trigger pull.
        for hand in wandInput.takeToggles() {
            toggleIgnite(hand: hand == .left ? 0 : 1)
        }

        let poses = [sense.left, sense.right]
        var autoIgnite: [Int] = []
        for hand in 0 ..< 2 {
            var state = localHands[hand]
            if poses[hand].isTracked {
                // First sight of this wand: light it up, so entering the arena
                // gives immediate feedback (mixed immersion shows nothing at
                // all otherwise). The trigger retracts it as usual.
                if !state.everTracked {
                    autoIgnite.append(hand)
                    SaberXRHolder.shared.wandsEverTracked = true
                }
                state.everTracked = true
                state.untrackedTime = 0
                state.hilt = poses[hand].position
                    + poses[hand].orientation.act(tuning.gripOffsetLocal(hand: hand))
                state.direction = simd_normalize(
                    poses[hand].orientation.act(tuning.bladeAxisLocal(hand: hand))
                )
            } else if state.everTracked {
                // Hold the last pose briefly, then retract rather than flicker.
                state.untrackedTime += dt
                if state.untrackedTime > tuning.untrackedGrace {
                    state.ignitedTarget = false
                }
            }
            state.ignition.update(deltaTime: dt, ignited: state.ignitedTarget)

            let length = state.ignition.easedProgress * tuning.fullLength
            let tip = state.hilt + state.direction * length
            state.tipSpeed = dt > 0 ? simd_distance(tip, state.lastTip) / dt : 0
            state.lastTip = tip
            localHands[hand] = state
        }
        for hand in autoIgnite where !localHands[hand].ignitedTarget {
            toggleIgnite(hand: hand)
        }

        #if targetEnvironment(simulator)
        driveSimulatorDebugBlades()
        #endif
    }

    // MARK: - Loading spinner

    /// While the wands exist but neither has delivered a tracked pose yet,
    /// orbit a pair of fading sparks on a small circle ahead of the user: a
    /// "loading" cue for the seconds ARKit needs to bring up world tracking
    /// and accessory anchors. It only renders once head tracking works (the
    /// engine skips frames without a device anchor), so a visible spinner
    /// also means the render path is healthy — it vanishes the moment the
    /// first wand tracks and the blades auto-ignite. Replaces the old
    /// frozen-blades-at-resting-pose fallback, which read as broken.
    private func updateLoadingSpinner(dt: Float) {
        guard !localHands.contains(where: { $0.everTracked }),
              isPSVR2SenseConnected()
        else { return }

        // Spawn cadence tuned to the spark system: 2 sparks every 45 ms fill
        // the 8-spark cap over ~0.18 s — exactly one spark lifetime — so the
        // ring carries a full fading comet trail.
        spinnerAccumulator += dt
        guard spinnerAccumulator >= 0.045 else { return }
        spinnerAccumulator = 0

        // World origin is on the floor beneath the user at space open, -Z is
        // where they were facing: chest height, one metre ahead.
        let center = SIMD3<Float>(0, 1.35, -1.0)
        let radius: Float = 0.12
        let speed: Float = 3.0 // rad/s
        for arm in 0 ..< 2 {
            let angle = elapsed * speed + Float(arm) * .pi
            let position = center + SIMD3<Float>(cos(angle), sin(angle), 0) * radius
            spawnCoolSaberClashSpark(at: position, color: localColor, intensity: 2.5)
        }
    }

    private func toggleIgnite(hand: Int) {
        localHands[hand].ignitedTarget.toggle()
        let ignited = localHands[hand].ignitedTarget
        if ignited {
            audio.playIgnite()
        } else {
            audio.playRetract()
        }
        let saberHand: SaberHand = hand == 0 ? .left : .right
        haptics.ignitePulse(hand: saberHand)
        mailbox.pushLocalEvent(
            .ignite(hand: saberHand, ignited: ignited, color: localColor)
        )
    }

    #if targetEnvironment(simulator)
    /// The simulator has no PSVR2: swing two auto-ignited debug blades so the
    /// full render/clash path is verifiable without hardware.
    private func driveSimulatorDebugBlades() {
        for hand in 0 ..< 2 {
            var state = localHands[hand]
            if elapsed > 1.5 { state.ignitedTarget = true }
            let side: Float = hand == 0 ? -1 : 1
            let swing = sin(elapsed * 1.6 + (hand == 0 ? 0 : 0.9))
            state.hilt = SIMD3<Float>(side * 0.28, 1.05, -0.85)
            state.direction = simd_normalize(
                SIMD3<Float>(-side * (0.45 + 0.35 * swing), 1.0, 0.15 * swing)
            )
            localHands[hand] = state
        }
    }
    #endif

    // MARK: - Remote opponent

    private func updateRemote(dt: Float) {
        for event in mailbox.takeRemoteEvents() {
            switch event {
            case .ignite(_, let ignited, _):
                if ignited { audio.playIgnite() } else { audio.playRetract() }
            case .clash(let position, let intensity):
                // Dedupe: our own detector probably saw the same contact.
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastLocalClashUptime > 0.15 {
                    spawnCoolSaberClashSpark(at: position, intensity: intensity)
                    audio.playClash(intensity: intensity)
                }
            }
        }

        let snapshot = mailbox.remoteSnapshot()
        let now = ProcessInfo.processInfo.systemUptime
        guard mailbox.sessionActive, mailbox.opponentPresent,
              let packet = snapshot.packet,
              now - snapshot.arrivalUptime < 2.0
        else {
            for hand in 0 ..< 2 {
                remoteHands[hand].hasPose = false
                remoteHands[hand].ignition.update(deltaTime: dt, ignited: false)
            }
            return
        }

        let stale = now - snapshot.arrivalUptime > 0.5
        let wires = [packet.left, packet.right]
        for hand in 0 ..< 2 {
            var state = remoteHands[hand]
            var wire = wires[hand]

            if !mailbox.isSpatial {
                // No shared origin: re-base onto the opponent anchor 2 m in
                // front of us, turned to face us. Both origins sit on their
                // respective floors, so heights roughly line up.
                wire.hilt = Self.opponentAnchor(wire.hilt)
                wire.direction = Self.opponentAnchorRotation(wire.direction)
            }

            if !state.hasPose {
                state.hilt = wire.hilt
                state.direction = wire.direction
                state.hasPose = true
            } else if !stale {
                // Exponential smoothing toward the newest packet.
                let alpha = 1 - exp(-20 * dt)
                state.hilt += (wire.hilt - state.hilt) * alpha
                let blended = simd_mix(state.direction, wire.direction, SIMD3(repeating: alpha))
                state.direction = simd_length_squared(blended) > 1e-8
                    ? simd_normalize(blended)
                    : wire.direction
            }
            state.wire = wire
            state.ignition.update(deltaTime: dt, ignited: wire.ignited)
            remoteHands[hand] = state
        }
    }

    /// translate(0, 0, -2) · rotateY(π) applied to a point.
    private static func opponentAnchor(_ point: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(-point.x, point.y, -point.z - 2)
    }

    private static func opponentAnchorRotation(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(-vector.x, vector.y, -vector.z)
    }

    // MARK: - Feeding the renderer

    private func localBladeLength(_ hand: Int) -> Float {
        localHands[hand].ignition.easedProgress * tuning.fullLength
    }

    private func remoteBladeLength(_ hand: Int) -> Float {
        remoteHands[hand].ignition.easedProgress * tuning.fullLength
    }

    private func publishBlades() {
        let localSlots: [CoolSaberBladeSlot] = [.localLeft, .localRight]
        let remoteSlots: [CoolSaberBladeSlot] = [.remoteLeft, .remoteRight]

        for hand in 0 ..< 2 {
            let state = localHands[hand]
            let length = localBladeLength(hand)
            setCoolSaberBlade(
                localSlots[hand],
                length > 0.01
                    ? CoolSaberBladeDesc(
                        hilt: state.hilt,
                        direction: state.direction,
                        length: length,
                        radius: tuning.coreRadius,
                        color: localColor,
                        glowIntensity: tuning.glowIntensity
                    )
                    : nil
            )

            let remote = remoteHands[hand]
            let remoteLength = remoteBladeLength(hand)
            setCoolSaberBlade(
                remoteSlots[hand],
                remote.hasPose && remoteLength > 0.01
                    ? CoolSaberBladeDesc(
                        hilt: remote.hilt,
                        direction: remote.direction,
                        length: remoteLength,
                        radius: tuning.coreRadius,
                        color: tuning.remoteColor,
                        glowIntensity: tuning.glowIntensity
                    )
                    : nil
            )
        }
    }

    // MARK: - Clash detection

    private struct BladeSegment {
        var slot: CoolSaberBladeSlot
        var start: SIMD3<Float>
        var end: SIMD3<Float>
        var tipVelocityRef: SIMD3<Float>
        var isLocal: Bool
        var hand: Int
    }

    private func detectClashes(dt: Float) {
        var segments: [BladeSegment] = []
        for hand in 0 ..< 2 {
            let length = localBladeLength(hand)
            if length > 0.05 {
                let state = localHands[hand]
                segments.append(BladeSegment(
                    slot: hand == 0 ? .localLeft : .localRight,
                    start: state.hilt,
                    end: state.hilt + state.direction * length,
                    tipVelocityRef: state.lastTip,
                    isLocal: true,
                    hand: hand
                ))
            }
            let remoteLength = remoteBladeLength(hand)
            if remoteHands[hand].hasPose, remoteLength > 0.05 {
                let state = remoteHands[hand]
                segments.append(BladeSegment(
                    slot: hand == 0 ? .remoteLeft : .remoteRight,
                    start: state.hilt,
                    end: state.hilt + state.direction * remoteLength,
                    tipVelocityRef: .zero,
                    isLocal: false,
                    hand: hand
                ))
            }
        }

        guard segments.count >= 2 else { return }
        for i in 0 ..< segments.count - 1 {
            for j in (i + 1) ..< segments.count {
                let a = segments[i]
                let b = segments[j]
                guard a.isLocal || b.isLocal else { continue }
                let result = CoolSaberMath.segmentSegmentClosest(
                    a.start, a.end, b.start, b.end
                )
                let pairKey = a.slot.rawValue * 4 + b.slot.rawValue
                guard clashDetector.update(
                    pairKey: pairKey,
                    distance: result.distance,
                    deltaTime: dt
                ) else { continue }

                let contact = (result.pointA + result.pointB) * 0.5
                // Faster combined tip motion → brighter spark, harder kick.
                let speed = max(localHands[0].tipSpeed, localHands[1].tipSpeed)
                let intensity = 6 + min(speed, 6) * 1.5

                lastLocalClashUptime = ProcessInfo.processInfo.systemUptime
                spawnCoolSaberClashSpark(at: contact, intensity: intensity)
                audio.playClash(intensity: intensity)
                for segment in [a, b] where segment.isLocal {
                    haptics.clashPulse(
                        hand: segment.hand == 0 ? .left : .right,
                        intensity: min(0.5 + speed * 0.12, 1)
                    )
                }
                if mailbox.sessionActive {
                    mailbox.pushLocalEvent(.clash(position: contact, intensity: intensity))
                }
            }
        }
    }

    // MARK: - Audio + network

    private func updateAudio() {
        for hand in 0 ..< 2 {
            audio.setHum(
                slot: hand,
                ignited: localBladeLength(hand) > 0.05,
                tipSpeed: localHands[hand].tipSpeed
            )
            audio.setHum(
                slot: 2 + hand,
                ignited: remoteHands[hand].hasPose && remoteBladeLength(hand) > 0.05,
                tipSpeed: 2
            )
        }
    }

    private func sendPoses(dt: Float) {
        guard mailbox.sessionActive else { return }
        sendAccumulator += dt
        guard sendAccumulator >= 1.0 / 45.0 else { return }
        sendAccumulator = 0

        sequence &+= 1
        func wire(_ hand: Int) -> SaberBladeWire {
            SaberBladeWire(
                hilt: localHands[hand].hilt,
                direction: localHands[hand].direction,
                length: localBladeLength(hand),
                ignited: localHands[hand].ignitedTarget
            )
        }
        mailbox.publishLocalPoses(SaberPosePacket(
            sequence: sequence,
            timestamp: ProcessInfo.processInfo.systemUptime,
            left: wire(0),
            right: wire(1)
        ))
    }
}

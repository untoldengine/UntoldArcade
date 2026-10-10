//
//  CoolMirrorMocapController.swift
//  CoolMirror
//
//  Bridges the iPhone body capture to the engine: receives frames, retargets
//  them for the current character's rig and hands the engine world-space
//  rotation deltas every frame through `setEntityExternalPose`, and the
//  hands' targets through reach IK (see `MocapArmReach`). With the headset's
//  pose the character is held by its head and its planted feet (see
//  `MocapBodyAnchor`), the phone giving only the pose between them.
//

import CoolMirrorMocap
import Foundation
import simd
import UntoldEngine

/// ARKit body joints → rig joints for the demo characters.
enum CoolMirrorMocapMapping {
    static func mapping(for character: CoolMirrorCharacter) -> MocapRigMapping? {
        guard let p = CoolMirrorRigProfile.profile(for: character) else { return nil }
        var joints: [MocapJoint: String] = [
            .hips: p.pelvis,
            .spine2: p.spine,
            .spine5: p.chest,
            .spine7: p.upperChest,
            .neck1: p.neck,
            .head: p.head,
            .leftShoulder: p.clavicle,
            .leftArm: p.upperArm,
            .leftForearm: p.forearm,
            .leftHand: p.hand,
            .leftUpLeg: p.thigh,
            .leftLeg: p.calf,
            .leftFoot: p.foot,
        ]
        // The toes are only a bone end: ARKit infers them from the ankle
        // (never tracked), so their twist would stretch the feet if driven.
        var reference = joints
        reference[.leftToes] = p.toe
        for (joint, name) in joints where joint.mirrored != joint {
            joints[joint.mirrored] = p.mirror(name)
        }
        for (joint, name) in reference where joint.mirrored != joint {
            reference[joint.mirrored] = p.mirror(name)
        }
        return MocapRigMapping(joints: joints, rootJoint: p.pelvis, referenceJoints: reference)
    }

    /// The rig's hands, by the side of the character.
    static func hands(for character: CoolMirrorCharacter) -> [MocapHandSide: MocapHandRig] {
        guard let p = CoolMirrorRigProfile.profile(for: character) else { return [:] }
        let left = MocapHandRig(hand: p.hand, fingers: p.fingers, tips: p.fingerTips)
        let right = MocapHandRig(hand: p.mirror(left.hand), fingers: left.fingers.map { $0.map(p.mirror) }, tips: left.tips.map { $0.map(p.mirror) })
        return [.left: left, .right: right]
    }
}

/// Lock-protected; `update()` runs on the render thread, everything else on
/// the main actor.
final class CoolMirrorMocapController: @unchecked Sendable {
    /// Frames older than this stop driving the character (the phone left).
    private static let staleInterval: TimeInterval = 1.0
    private static let debugLinesName = "coolmirror.mocap"

    private let receiver = MocapReceiver()
    private let lock = NSLock()
    private var retargeter: MocapRetargeter?
    private var characterId: EntityID?
    private var characterOrigin = simd_float3(0, 0, 0)
    private var enabled = false
    private var pendingCalibration = false
    private var lastSequence: UInt32?
    private var lastFrameDate = Date.distantPast
    /// The last frame's own timestamp (the phone's clock, which the
    /// recording's markers use).
    private var lastFrameTime: Double?
    private var driving = false
    private var storedOptions = MocapRetargetOptions()
    private var jitter = MocapJitterMeter()
    private var debugOverlay = false
    private var debugLinesShown = false
    /// The headset's own pose (world), read every update: its orientation
    /// drives the character's head, the one joint the phone cannot see
    /// under the Vision Pro, and its position says where the head is.
    private var headPoseProvider: (@Sendable () -> simd_float4x4?)?
    private var headReference: simd_quatf?
    /// The wearer's hands as the headset sees them, read every update.
    private var handProvider: (@Sendable () -> [MocapHandSide: MocapHandSample])?
    /// The hands follow the headset while it sees them and the phone
    /// while it does not (see `MocapHandLadder`).
    private var headsetHands = true
    private var handLadder = MocapHandLadder()
    /// The rig's hands by the character's side, and the finger and hand
    /// rotations last shown (world deltas by joint name), eased toward
    /// the headset's and held while it does not see the hand.
    private var handRigs: [MocapHandSide: MocapHandRig] = [:]
    private var shownHands: [MocapHandSide: [String: simd_quatf]] = [:]
    private var lastHandTime: TimeInterval?
    /// Halflife of the fingers following the headset (s).
    private static let fingerHalflife: Float = 0.04
    /// The character is held by its head (the headset's position) and its
    /// planted feet (see `MocapBodyAnchor`).
    private var headAnchor = true
    private var headTrack = MocapHeadTrack()
    private var bodyAnchor = MocapBodyAnchor()
    /// Where the rig's head is with the wearer at the calibration spot
    /// (model space); nil until the first anchored frame.
    private var headRest: simd_float3?
    /// The rig's rest joint positions by the captured joint they answer
    /// for, and the hips' share of a lean (see `MocapBodyAnchor`).
    private var restJoints: [MocapJoint: simd_float3] = [:]
    private var hipShare: Float = 0.55
    /// The rig's leg chains, in the order of `MocapBodyAnchor.feet`.
    private var legChains: [ReachIKChainDescriptor] = []
    private var groundLock = true
    /// The character stands on its planted foot (see `MocapFootAnchor`).
    private var footAnchor = MocapFootAnchor()
    /// Raw frames from the phone written to a file while recording.
    private var recording: MocapRecordingWriter?
    /// Rest height of every ankle and toe joint (model space), by the
    /// captured joint it answers for.
    private var restFootHeights: [MocapJoint: Float] = [:]
    /// The hands reach for where the captured hands are on the body (see
    /// `MocapArmReach`), over the arm pose the capture gives.
    private var armReach = true
    private let armReachSolver = MocapArmReach()
    /// The rig's arm chains, in the order of `MocapArmReach.arms`; empty
    /// when the rig lacks one of the joints.
    private var armChains: [ReachIKChainDescriptor] = []
    private var armLengths: [MocapJoint: Float] = [:]
    private var reachChainsConfigured = false
    private var reaching = false
    /// Seconds over which the reach takes and releases the limbs.
    private static let reachHalflife: Float = 0.2
    /// The capture is filtered already; this only rounds off what is left.
    private static let reachTargetHalflife: Float = 0.03
    /// A straight limb is straight: a limit short of it bends every
    /// elbow and knee that should not be.
    private static let reachExtent: Float = 1

    var options: MocapRetargetOptions {
        get { lock.withLock { storedOptions } }
        set {
            lock.withLock {
                storedOptions = newValue
                retargeter?.options = newValue
            }
        }
    }

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    var isCalibrated: Bool {
        lock.withLock { retargeter?.isCalibrated ?? false }
    }

    /// Draws the captured skeleton (orange, red bones where ARKit lost the
    /// joint) and the character's rig bones (cyan) as lines in the world.
    var isDebugOverlayEnabled: Bool {
        get { lock.withLock { debugOverlay } }
        set { lock.withLock { debugOverlay = newValue } }
    }

    // MARK: - Recording

    /// Starts writing every frame the phone sends to `url`, and what the
    /// headset knows at every frame it renders (see `MocapRecording`); a
    /// recording already running is closed first.
    func startRecording(to url: URL) throws {
        stopRecording()
        let writer = try MocapRecordingWriter(url: url)
        lock.withLock { recording = writer }
        receiver.frameSink = { frame in writer.append(frame) }
    }

    /// Notes what the wearer does from now on, in the recording.
    func markRecording(_ label: String) {
        let (writer, time) = lock.withLock { (recording, lastFrameTime) }
        writer?.mark(label, at: time ?? Date().timeIntervalSinceReferenceDate)
    }

    @discardableResult
    func stopRecording() -> (url: URL, frames: Int, headsetSamples: Int)? {
        receiver.frameSink = nil
        guard let writer = lock.withLock({ () -> MocapRecordingWriter? in
            defer { recording = nil }
            return recording
        }) else { return nil }
        writer.close()
        return (writer.url, writer.frameCount, writer.headsetSampleCount)
    }

    /// The headset's head and hands at this rendered frame, into the
    /// recording: whether or not a body is in view, and whatever the
    /// mirror makes of it.
    private func recordHeadset(at time: TimeInterval) {
        let (writer, head, hands) = lock.withLock { (recording, headPoseProvider, handProvider) }
        guard let writer else { return }
        writer.append(MocapHeadsetSample(
            time: time,
            frameTime: receiver.latestFrame?.timestamp,
            head: head?().map { MocapPose($0) },
            hands: hands?() ?? [:]
        ))
    }

    /// Supplies the wearer's hands as the headset sees them.
    func setHandProvider(_ provider: (@Sendable () -> [MocapHandSide: MocapHandSample])?) {
        lock.withLock { handProvider = provider }
    }

    var recordingFrameCount: Int? {
        lock.withLock { recording?.frameCount }
    }

    /// Supplies the headset's world orientation; the head then follows the
    /// wearer's head (mirrored like the rest) instead of riding on the neck.
    func setHeadPoseProvider(_ provider: (@Sendable () -> simd_float4x4?)?) {
        lock.withLock {
            headPoseProvider = provider
            headReference = nil
            headTrack.reset()
            bodyAnchor.reset()
            headRest = nil
        }
    }

    /// The head is where the headset is and the planted feet stay where
    /// they landed; the phone gives the pose between them, not where the
    /// body is (see `MocapBodyAnchor`). Needs the headset's pose and root
    /// motion; off, or without them, the root is the phone's.
    var isHeadAnchorEnabled: Bool {
        get { lock.withLock { headAnchor } }
        set {
            lock.withLock {
                guard headAnchor != newValue else { return }
                headAnchor = newValue
                bodyAnchor.reset()
                headRest = nil
            }
        }
    }

    /// Builds the character from the feet up: the planted foot's ankle is
    /// held where it landed, on the floor, and the root follows from it
    /// (see `MocapFootAnchor`). Off, the root is the tracked hips.
    var isGroundLockEnabled: Bool {
        get { lock.withLock { groundLock } }
        set {
            lock.withLock {
                groundLock = newValue
                if !newValue {
                    footAnchor.reset()
                }
            }
        }
    }

    /// The hands go where the captured hands are relative to the body
    /// (touching hands touch, a hand on the head lands on the head)
    /// instead of where the copied bone directions take them.
    var isArmReachEnabled: Bool {
        get { lock.withLock { armReach } }
        set { lock.withLock { armReach = newValue } }
    }

    /// The hands are where the headset sees them; the phone's take over
    /// while it does not (see `MocapHandLadder`). Needs the arm reach,
    /// the headset's pose and its hands.
    var isHeadsetHandsEnabled: Bool {
        get { lock.withLock { headsetHands } }
        set {
            lock.withLock {
                guard headsetHands != newValue else { return }
                headsetHands = newValue
                handLadder.reset()
            }
        }
    }

    /// Which device each of the character's hands follows, for the panel.
    var handSources: [MocapJoint: MocapHandLadder.Source] {
        lock.withLock { headsetHands ? handLadder.sources : [:] }
    }

    /// Joints the phone must actually see before the pose is trustworthy
    /// and calibration makes sense.
    static let framingJoints: [MocapJoint] = [.head, .leftHand, .rightHand, .leftFoot, .rightFoot]

    /// Whether the phone sees the whole body (head, hands and feet tracked,
    /// not inferred) in the newest frame.
    var isFramed: Bool {
        guard let frame = receiver.latestFrame, frame.isTracked, (receiver.secondsSinceLastFrame ?? .infinity) < 1 else { return false }
        return Self.framingJoints.allSatisfy { frame.trackedJoints.contains($0) }
    }

    /// What to change so the whole body is in the picture, or nil when it is.
    var framingHint: String? {
        guard let frame = receiver.latestFrame, frame.isTracked else { return nil }
        let missing = Set(Self.framingJoints.filter { !frame.trackedJoints.contains($0) })
        guard !missing.isEmpty else { return nil }
        let head = missing.contains(.head)
        let feet = !missing.isDisjoint(with: [.leftFoot, .rightFoot])
        let hands = !missing.isDisjoint(with: [.leftHand, .rightHand])
        if head, feet {
            return "Head and feet out of the picture: step back from the phone."
        }
        if head {
            return "Head out of the picture: step back, or tilt the phone up."
        }
        if feet {
            return "Feet out of the picture: step back, or tilt the phone down."
        }
        if hands {
            return "Hands out of the picture: keep them inside the frame."
        }
        return nil
    }

    /// An iPhone is connected and sending (frames within the last second).
    var isConnected: Bool {
        lock.withLock { enabled } && receiver.isPeerConnected && (receiver.secondsSinceLastFrame ?? .infinity) < 1
    }

    /// One line on the link: connected or not, frame rate, body seen.
    var connectionSummary: String {
        guard lock.withLock({ enabled }) else { return "○ iPhone link off" }
        guard receiver.isPeerConnected else { return "○ No iPhone connected — \(receiver.status)" }
        let hz = receiver.framesPerSecond
        guard hz > 0 else { return "◐ iPhone connected, no frames arriving" }
        let tracked = receiver.latestFrame?.isTracked ?? false
        let pictures = receiver.previewCounts.pictures
        return "● iPhone connected · \(hz) frames/s · \(tracked ? "body seen" : "no body in view") · \(pictures) pictures"
    }

    /// Newest camera preview from the phone.
    var preview: MocapPreviewFrame? {
        receiver.latestPreview
    }

    /// Raw per-frame motion of the capture (see `MocapJitterMeter`).
    var jitterReport: String {
        lock.withLock { jitter.report }
    }

    /// Setup guidance for the person wearing the headset (the phone's screen
    /// faces away from them): what to do next, in order.
    var status: String {
        let (enabled, calibrated, pending, driving, hasMapping) = lock.withLock {
            (self.enabled, retargeter?.isCalibrated ?? false, pendingCalibration, self.driving, retargeter != nil)
        }
        guard enabled else { return "off" }
        guard hasMapping else { return "This character has no motion-capture mapping; pick Spider-Man or Batman." }
        guard receiver.isPeerConnected else {
            return "1 · Open CoolMirror Capture on the iPhone (same Wi-Fi) and stand it sideways (landscape) with the back camera facing you, 3–4 m away."
        }
        let sinceLastFrame = receiver.secondsSinceLastFrame
        let tracked = (receiver.latestFrame?.isTracked ?? false) && (sinceLastFrame ?? .infinity) < 1
        guard tracked else {
            let counts = receiver.previewCounts
            return "2 · iPhone connected but it sees no body: keep the phone in landscape and step back until you are fully in its view, feet included. (pictures \(counts.pictures), chunks \(counts.chunks))"
        }
        if pending {
            return "Hold still… capturing your pose as the character's rest pose."
        }
        if let hint = framingHint {
            return "3 · \(hint) The picture above shows what the phone sees; the whole body must be inside it, or the tracker guesses and flips."
        }
        if !calibrated {
            return "4 · Whole body in view (\(receiver.framesPerSecond) Hz). Stand upright facing the phone, look at it, arms relaxed, then tap Calibrate and hold still."
        }
        let counts = receiver.previewCounts
        let seen = (receiver.latestFrame.map { "\($0.trackedJoints.count)/\($0.rotations.count) joints seen" } ?? "")
            + ", pictures \(counts.pictures) of \(counts.chunks) chunks"
        if driving {
            let held = (lock.withLock { retargeter?.isYawHeld } ?? false) ? " · heading held: the tracker turned the body faster than a body can turn" : ""
            let sources = handSources
            func name(_ joint: MocapJoint) -> String {
                switch sources[joint] {
                case .headset, .bridge: "headset"
                case .phone: "phone"
                case nil: "-"
                }
            }
            let hands = sources.isEmpty ? "" : " · hands: left \(name(.leftHand)), right \(name(.rightHand))"
            return "Mirroring you at \(receiver.framesPerSecond) Hz, \(seen)\(hands). Wrong side? tap Mirror. Facing away? tap Flip. Recalibrate any time.\n\(jitterReport)\(held) (stand still to read the tracker noise)"
        }
        return "Body tracked (\(receiver.framesPerSecond) Hz), waiting for the next frame…"
    }

    /// `origin` is where the character's rest pose stands in the world (the
    /// captured skeleton is drawn relative to it).
    func setCharacter(_ id: EntityID?, mapping: MocapRigMapping?, hands: [MocapHandSide: MocapHandRig] = [:], origin: simd_float3 = .zero) {
        lock.withLock {
            characterId = id
            characterOrigin = origin
            handRigs = hands
            shownHands = [:]
            if let mapping {
                let retargeter = MocapRetargeter(mapping: mapping)
                retargeter.options = storedOptions
                if let id {
                    retargeter.rigRestPositions = Self.restPositions(of: id)
                    restFootHeights = Self.restFootHeights(of: retargeter.rigRestPositions, mapping: mapping)
                    (armChains, armLengths) = Self.armChains(of: id, mapping: mapping)
                    legChains = Self.legChains(of: id, mapping: mapping)
                    restJoints = mapping.referenceJoints.compactMapValues { retargeter.rigRestPositions[$0] }
                    hipShare = MocapBodyAnchor.hipShare(rest: restJoints)
                }
                self.retargeter = retargeter
            } else {
                retargeter = nil
                restFootHeights = [:]
                armChains = []
                armLengths = [:]
                legChains = []
                restJoints = [:]
            }
            reachChainsConfigured = false
            reaching = false
            bodyAnchor.reset()
            headRest = nil
            driving = false
            footAnchor.reset()
            jitter.reset()
        }
        hideDebugLines()
    }

    /// The rig's rest joint positions keyed by full path and by last path
    /// component (the names the mappings use).
    private static func restPositions(of entityId: EntityID) -> [String: simd_float3] {
        var positions: [String: simd_float3] = [:]
        for joint in entitySkeletonRestJointPoses(entityId: entityId) {
            positions[joint.path] = joint.modelPosition
            if let name = joint.path.split(separator: "/").last {
                positions[String(name)] = joint.modelPosition
            }
        }
        return positions
    }

    /// Rest heights of the ankles and toes: whichever of them ends lowest
    /// in a pose is the floor contact.
    private static func restFootHeights(of positions: [String: simd_float3], mapping: MocapRigMapping) -> [MocapJoint: Float] {
        var heights: [MocapJoint: Float] = [:]
        for joint in [MocapJoint.leftFoot, .rightFoot, .leftToes, .rightToes] {
            if let name = mapping.referenceJoints[joint], let position = positions[name] {
                heights[joint] = position.y
            }
        }
        return heights
    }

    /// The rig's arm chains (full joint paths) and arm lengths, by
    /// shoulder joint; nothing unless both arms are complete.
    private static func armChains(of entityId: EntityID, mapping: MocapRigMapping) -> ([ReachIKChainDescriptor], [MocapJoint: Float]) {
        let rest = entitySkeletonRestJointPoses(entityId: entityId)
        func joint(_ captured: MocapJoint) -> (path: String, position: simd_float3)? {
            guard let name = mapping.joints[captured],
                  let pose = rest.first(where: { jointPath($0.path, matches: name) })
            else { return nil }
            return (pose.path, pose.modelPosition)
        }
        var chains: [ReachIKChainDescriptor] = []
        var lengths: [MocapJoint: Float] = [:]
        for arm in MocapArmReach.arms {
            guard let shoulder = joint(arm.shoulder), let elbow = joint(arm.elbow), let hand = joint(arm.hand) else {
                return ([], [:])
            }
            chains.append(ReachIKChainDescriptor(shoulderPath: shoulder.path, elbowPath: elbow.path, handPath: hand.path))
            lengths[arm.shoulder] = simd_distance(shoulder.position, elbow.position) + simd_distance(elbow.position, hand.position)
        }
        return (chains, lengths)
    }

    /// The rig's leg chains (full joint paths), in the order of
    /// `MocapBodyAnchor.feet`; nothing unless both legs are complete.
    private static func legChains(of entityId: EntityID, mapping: MocapRigMapping) -> [ReachIKChainDescriptor] {
        let rest = entitySkeletonRestJointPoses(entityId: entityId)
        func path(_ captured: MocapJoint) -> String? {
            guard let name = mapping.joints[captured] else { return nil }
            return rest.first { jointPath($0.path, matches: name) }?.path
        }
        var chains: [ReachIKChainDescriptor] = []
        for foot in MocapBodyAnchor.feet {
            guard let leg = MocapBodyAnchor.legs[foot], leg.count == 4,
                  let hip = path(leg[1]), let knee = path(leg[2]), let ankle = path(leg[3])
            else { return [] }
            chains.append(ReachIKChainDescriptor(
                shoulderPath: hip, elbowPath: knee, handPath: ankle, bendDirection: simd_float3(0, 0, 1)
            ))
        }
        return chains
    }

    func setEnabled(_ enabled: Bool) {
        let (wasEnabled, characterId) = lock.withLock {
            let was = self.enabled
            self.enabled = enabled
            return (was, self.characterId)
        }
        if enabled, !wasEnabled {
            receiver.start()
        } else if !enabled, wasEnabled {
            receiver.stop()
            if let characterId {
                clearEntityExternalPose(entityId: characterId)
                releaseLimbs(characterId: characterId)
            }
            lock.withLock {
                driving = false
                bodyAnchor.reset()
                headRest = nil
                retargeter?.resetSmoothing()
                jitter.reset()
            }
            hideDebugLines()
        }
    }

    func requestCalibration() {
        lock.withLock { pendingCalibration = true }
    }

    /// Render-thread step: smooths the newest frame toward the current time
    /// and retargets it onto the character. Runs every render tick, so the
    /// filter also interpolates between the phone's frames.
    func update() {
        let now = Date()
        let time = now.timeIntervalSinceReferenceDate
        recordHeadset(at: time)
        let (enabled, characterId, retargeter, origin) = lock.withLock {
            (self.enabled, self.characterId, self.retargeter, characterOrigin)
        }
        guard enabled, let characterId, let retargeter else { return }
        guard let frame = receiver.latestFrame else { return }

        let isNew = lock.withLock { () -> Bool in
            guard frame.sequence != lastSequence else { return false }
            lastSequence = frame.sequence
            lastFrameDate = now
            lastFrameTime = frame.timestamp
            jitter.add(frame, at: time)
            return true
        }
        if !isNew {
            // The phone went quiet: release the character after a moment.
            let stale = lock.withLock { now.timeIntervalSince(lastFrameDate) > Self.staleInterval }
            if stale {
                let wasDriving = lock.withLock { driving }
                if wasDriving {
                    clearEntityExternalPose(entityId: characterId)
                    releaseLimbs(characterId: characterId)
                    lock.withLock { driving = false }
                }
                hideDebugLines()
                return
            }
        }
        guard frame.isTracked else { return }

        let smoothed = retargeter.smoothed(frame, at: time)
        let calibrate = lock.withLock { () -> Bool in
            defer { pendingCalibration = false }
            return pendingCalibration
        }
        let devicePose = lock.withLock { headPoseProvider }?()
        let headPose = devicePose.map { simd_quatf($0) }
        if calibrate {
            retargeter.calibrate(with: smoothed)
            lock.withLock {
                headReference = headPose
                if let devicePose {
                    headTrack.calibrate(with: devicePose)
                } else {
                    headTrack.reset()
                }
                bodyAnchor.reset()
                headRest = nil
            }
        }
        guard var result = retargeter.retarget(smoothed) else { return }
        if let headPose, let reference = lock.withLock({ headReference }),
           let headJoint = retargeter.mapping.joints[.head]
        {
            result.worldRotationDeltas[headJoint] = Self.headDelta(
                pose: headPose, reference: reference, characterId: characterId, options: retargeter.options
            )
        }
        let pins = place(&result, devicePose: devicePose, characterId: characterId, origin: origin, time: time, options: retargeter.options)
        shapeHands(&result, devicePose: devicePose, rest: retargeter.rigRestPositions, time: time, options: retargeter.options)
        setEntityExternalPose(
            entityId: characterId,
            worldRotationDeltas: result.worldRotationDeltas,
            rootJoint: result.rootJoint,
            rootTranslationDelta: result.rootTranslationDelta,
            weight: retargeter.options.weight
        )
        reach(result, pins: pins, devicePose: devicePose, characterId: characterId, origin: origin, time: time, options: retargeter.options)
        lock.withLock { driving = true }

        if lock.withLock({ debugOverlay }) {
            showDebugLines(result: result, characterId: characterId, origin: origin)
        } else {
            hideDebugLines()
        }
    }

    // MARK: - Head from the headset

    /// The headset's rotation since calibration, mirrored in world space
    /// across the plane between the wearer and the character (a real
    /// mirror reflects the axis and reverses the angle), then brought into
    /// the character's model space (the entity is turned to face the
    /// wearer) and flipped like the captured joints.
    static func headDelta(pose: simd_quatf, reference: simd_quatf, characterId: EntityID, options: MocapRetargetOptions) -> simd_quatf {
        headDelta(pose: pose, reference: reference, entityRotation: getRotationQuaternion(entityId: characterId), options: options)
    }

    static func headDelta(pose: simd_quatf, reference: simd_quatf, entityRotation entity: simd_quatf, options: MocapRetargetOptions) -> simd_quatf {
        var delta = simd_normalize(pose * reference.inverse)
        if options.mirror {
            // Mirror plane normal: the character's facing axis (either sign
            // gives the same reflection).
            let n = simd_normalize(entity.act(simd_float3(0, 0, 1)))
            let v = delta.imag
            let reflected = -v + 2 * simd_dot(v, n) * n
            delta = simd_quatf(ix: reflected.x, iy: reflected.y, iz: reflected.z, r: delta.real)
        }
        delta = simd_normalize(entity.inverse * delta * entity)
        if options.flipFacing {
            let facing = simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0))
            delta = simd_normalize(facing * delta * facing.inverse)
        }
        return delta
    }

    // MARK: - Where the character stands

    /// The rig's joints as the engine composed them last frame (which
    /// already hold the previous corrections), in the character's model
    /// space.
    private func composed(_ joints: [MocapJoint: String], characterId: EntityID, origin: simd_float3) -> [MocapJoint: simd_float3] {
        let rotation = getRotationQuaternion(entityId: characterId)
        let scale = max(getScale(entityId: characterId).y, 1e-4)
        let poses = entitySkeletonJointPoses(entityId: characterId)
        var rig: [MocapJoint: simd_float3] = [:]
        for (captured, name) in joints {
            guard let pose = poses.first(where: { Self.jointPath($0.path, matches: name) }) else { continue }
            rig[captured] = rotation.inverse.act(pose.worldPosition - origin) / scale
        }
        return rig
    }

    /// Sets the root translation of `result` and returns the feet to hold
    /// (leg IK), if any.
    ///
    /// Heights come from the feet: the rig's ankles drive
    /// `MocapFootAnchor`, whose correction keeps the planted foot on the
    /// floor. Across the floor the character is held by its head and its
    /// planted feet when the headset's pose is known (see
    /// `MocapBodyAnchor`; the torso's tilt goes into the rotations of
    /// `result`), else the foot anchor holds the planted foot and the
    /// phone's root says where the body is. With root motion off the
    /// anchor only holds the floor, so the character walks in place.
    private func place(
        _ result: inout MocapRetargetResult, devicePose: simd_float4x4?, characterId: EntityID, origin: simd_float3,
        time: TimeInterval, options: MocapRetargetOptions
    ) -> [MocapJoint: MocapBodyAnchor.Pin] {
        let phone = result.rootTranslationDelta
        let (grounding, floor, mapping, rest, anchoring) = lock.withLock {
            (groundLock, restFootHeights, retargeter?.mapping, restJoints, headAnchor && headTrack.isCalibrated)
        }
        guard let mapping else { return [:] }
        let moving = options.rootTranslationScale > 0

        // The head, where the headset has it.
        var pose: MocapBodyAnchor.Pose?
        var moved: simd_float3?
        if anchoring, moving, let devicePose, let restRoot = rest[.hips] {
            var deltas: [MocapJoint: simd_quatf] = [:]
            for (joint, name) in mapping.joints {
                deltas[joint] = result.worldRotationDeltas[name]
            }
            pose = MocapBodyAnchor.pose(rest: rest, deltas: deltas)
            moved = lock.withLock { headTrack.displacement(of: devicePose) }.map { displacement in
                var d = displacement
                if options.mirror {
                    d.x = -d.x
                }
                if options.flipFacing {
                    d = simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0)).act(d)
                }
                return d * options.rootTranslationScale
            }
            if let pose, let moved {
                lock.withLock {
                    // The first anchored frame continues where the phone's root is.
                    if headRest == nil {
                        headRest = restRoot + pose.head + simd_float3(phone.x, 0, phone.z) - simd_float3(moved.x, 0, moved.z)
                    }
                }
            }
        }
        let head = lock.withLock { headRest }
        let anchored = pose != nil && moved != nil && head != nil

        var translation = phone
        let feet = composed(mapping.referenceJoints.filter { floor[$0.key] != nil }, characterId: characterId, origin: origin)
        if grounding, !floor.isEmpty {
            // By the rig's foot: in a mirror the wearer's other one drives it.
            let captured = MocapFootAnchor.feet.reduce(into: [MocapJoint: simd_float3]()) {
                $0[$1] = result.capturedJointPositions[options.mirror ? $1.mirrored : $1]
            }
            let correction = lock.withLock {
                footAnchor.update(
                    captured: captured, root: phone, rig: feet, floor: floor, time: time, horizontal: moving && !anchored
                )
            }
            if anchored {
                translation.y += correction.y
            } else {
                translation += correction
            }
        }
        guard let pose, let moved, let head, let restRoot = rest[.hips] else {
            lock.withLock { bodyAnchor.reset() }
            result.rootTranslationDelta = translation
            return [:]
        }

        let output = lock.withLock {
            bodyAnchor.update(
                pose: pose, restRoot: restRoot, head: head + moved,
                planted: grounding ? footAnchor.planted : [],
                composed: feet, hipShare: hipShare, time: time
            )
        }
        translation.x = output.root.x
        translation.z = output.root.z
        result.rootTranslationDelta = translation
        // Everything above the hips tilts with the torso; the head keeps
        // the headset's orientation.
        for (joint, name) in mapping.joints where Self.isAboveHips(joint) {
            if let delta = result.worldRotationDeltas[name] {
                result.worldRotationDeltas[name] = simd_normalize(output.torsoTilt * delta)
            }
        }
        return output.pins
    }

    /// The torso from the spine up and the arms, without the head.
    private static func isAboveHips(_ joint: MocapJoint) -> Bool {
        guard joint != .head else { return false }
        var current: MocapJoint? = joint
        while let at = current {
            if at == MocapBodyAnchor.spine {
                return true
            }
            current = at.parent
        }
        return false
    }

    // MARK: - Reach

    /// Hands the engine a reach target per limb. The arms: where the
    /// captured hand is on the body, as an offset from the rig's shoulder.
    /// The anchors are the rig's joints as the engine composed them last
    /// frame; the reach does not move any of them, and measured from the
    /// shoulder they change only as fast as the torso turns. The legs:
    /// the spot each held foot stands on (see `MocapBodyAnchor`).
    private func reach(
        _ result: MocapRetargetResult, pins: [MocapJoint: MocapBodyAnchor.Pin], devicePose: simd_float4x4?,
        characterId: EntityID, origin: simd_float3, time: TimeInterval, options: MocapRetargetOptions
    ) {
        let (hands, arms, legs, lengths, configured, mapping) = lock.withLock {
            (armReach, armChains, legChains, armLengths, reachChainsConfigured, retargeter?.mapping)
        }
        guard let mapping, !arms.isEmpty || !legs.isEmpty else {
            releaseLimbs(characterId: characterId)
            return
        }
        if !configured {
            setReachIKChains(entityId: characterId, chains: arms + legs)
            lock.withLock { reachChainsConfigured = true }
        }

        var targets: [ReachIKChainTarget?] = []
        var weights: [Float] = []
        if !arms.isEmpty {
            var offsets: [MocapJoint: simd_float3] = [:]
            if hands {
                let rig = composed(mapping.joints.filter { MocapArmReach.joints.contains($0.key) }, characterId: characterId, origin: origin)
                var captured: [MocapJoint: simd_float3] = [:]
                for joint in MocapArmReach.joints {
                    captured[joint] = result.capturedJointPositions[options.mirror ? joint.mirrored : joint]
                }
                let hands = handsFromTheHeadset(captured: captured, devicePose: devicePose, time: time, options: options)
                offsets = armReachSolver.targets(captured: captured, rig: rig, rigArmLength: lengths, hands: hands)
            }
            for arm in MocapArmReach.arms {
                targets.append(offsets[arm.shoulder].map { ReachIKChainTarget(position: $0, space: .shoulder) })
                weights.append(1)
            }
        }
        if !legs.isEmpty {
            for foot in MocapBodyAnchor.feet {
                targets.append(pins[foot].map { ReachIKChainTarget(position: $0.position, space: .modelGround) })
                weights.append(pins[foot]?.weight ?? 0)
            }
        }
        guard targets.contains(where: { $0 != nil }) else {
            releaseLimbs(characterId: characterId)
            return
        }
        setReachIKChainWeights(entityId: characterId, weights: weights)
        setReachIKChainTargets(
            entityId: characterId,
            targets: targets,
            weight: options.weight,
            halflife: Self.reachHalflife,
            reach: Self.reachExtent,
            targetHalflife: Self.reachTargetHalflife
        )
        lock.withLock { reaching = true }
    }

    /// The character's hands by the device that knows them best (see
    /// `MocapHandLadder`), in the space of `captured` and by the rig's
    /// hand; empty without the headset, which leaves them to the phone.
    private func handsFromTheHeadset(
        captured: [MocapJoint: simd_float3], devicePose: simd_float4x4?, time: TimeInterval, options: MocapRetargetOptions
    ) -> [MocapJoint: simd_float3] {
        let (enabled, provider, track) = lock.withLock { (headsetHands, handProvider, headTrack) }
        guard enabled, let provider, let devicePose, track.isCalibrated, let phoneHead = captured[.head] else {
            lock.withLock { handLadder.reset() }
            return [:]
        }
        let seen = provider()
        let head = track.joint(devicePose)
        var inputs: [MocapJoint: MocapHandLadder.Input] = [:]
        for (joint, side) in [(MocapJoint.leftHand, MocapHandSide.left), (.rightHand, .right)] {
            // In a mirror the wearer's other hand drives this one.
            let wearer: MocapHandSide = options.mirror ? (side == .left ? .right : .left) : side
            var fromHead: simd_float3?
            if let hand = seen[wearer], hand.isTracked {
                var v = track.inBodyAxes(hand.wrist.position - head)
                if options.mirror {
                    v.x = -v.x
                }
                if options.flipFacing {
                    v = simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0)).act(v)
                }
                fromHead = v
            }
            inputs[joint] = MocapHandLadder.Input(headset: fromHead, phone: captured[joint].map { $0 - phoneHead })
        }
        let outputs = lock.withLock { handLadder.update(inputs, time: time) }
        return outputs.mapValues { phoneHead + $0.position }
    }

    /// The hand and finger bones take the directions of the headset's
    /// while it sees the hand (see `MocapHandRetarget`), eased over a few
    /// frames; a hand it does not see keeps the shape it last had.
    private func shapeHands(
        _ result: inout MocapRetargetResult, devicePose: simd_float4x4?, rest: [String: simd_float3],
        time: TimeInterval, options: MocapRetargetOptions
    ) {
        let (enabled, provider, track, rigs) = lock.withLock { (headsetHands, handProvider, headTrack, handRigs) }
        guard enabled, let provider, devicePose != nil, track.isCalibrated, !rigs.isEmpty else {
            lock.withLock { shownHands = [:] }
            return
        }
        let seen = provider()
        let dt = Float(lock.withLock { () -> TimeInterval in
            defer { lastHandTime = time }
            return lastHandTime.map { max(0, time - $0) } ?? 0
        })
        let ease = 1 - exp(-0.693_147_18 * dt / Self.fingerHalflife)
        for (side, rig) in rigs {
            // In a mirror the wearer's other hand drives this one.
            let wearer: MocapHandSide = options.mirror ? (side == .left ? .right : .left) : side
            var shown = lock.withLock { shownHands[side] } ?? [:]
            if let hand = seen[wearer], hand.isTracked {
                let captured = MocapHandRetarget.modelSpace(
                    hand, bodyAxes: track.inBodyAxes, mirror: options.mirror, flipFacing: options.flipFacing
                )
                let targets = MocapHandRetarget.deltas(captured: captured, rig: rig, rest: rest)
                for (joint, target) in targets {
                    if let current = shown[joint] {
                        shown[joint] = simd_normalize(simd_slerp(current, target, ease))
                    } else {
                        shown[joint] = target
                    }
                }
            }
            lock.withLock { shownHands[side] = shown }
            for (joint, delta) in shown {
                result.worldRotationDeltas[joint] = delta
            }
        }
    }

    /// Eases the limbs back to the pose.
    private func releaseLimbs(characterId: EntityID) {
        let wasReaching = lock.withLock { () -> Bool in
            defer { reaching = false }
            return reaching
        }
        if wasReaching {
            setReachIKChainTargets(entityId: characterId, targets: [], halflife: Self.reachHalflife)
        }
    }

    // MARK: - Debug overlay

    private func showDebugLines(result: MocapRetargetResult, characterId: EntityID, origin: simd_float3) {
        var segments: [DebugLineSegment] = []
        let rig = simd_float4(0.2, 0.9, 1.0, 1)
        let joints = entitySkeletonJointPoses(entityId: characterId)
        for joint in joints {
            guard let parentIndex = joint.parentIndex, parentIndex < joints.count else { continue }
            segments.append(DebugLineSegment(from: joints[parentIndex].worldPosition, to: joint.worldPosition, color: rig))
        }

        // ARKit's anchor sits at the hips, not on the floor, so the captured
        // figure is placed with its hips on the rig's pelvis (both carry the
        // same root translation); limbs then show the retargeting error.
        var anchor = origin
        if let capturedHips = result.capturedJointPositions[.hips],
           let pelvis = joints.first(where: { Self.jointPath($0.path, matches: result.rootJoint) })
        {
            anchor = pelvis.worldPosition - capturedHips
        }
        let captured = simd_float4(1.0, 0.6, 0.1, 1)
        let lost = simd_float4(1.0, 0.15, 0.15, 1)
        for (joint, position) in result.capturedJointPositions.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let parent = joint.parent, let parentPosition = result.capturedJointPositions[parent] else { continue }
            let color = result.capturedTrackedJoints.isEmpty || result.capturedTrackedJoints.contains(joint) ? captured : lost
            segments.append(DebugLineSegment(from: anchor + parentPosition, to: anchor + position, color: color))
        }
        setDebugLines(segments, named: Self.debugLinesName)
        lock.withLock { debugLinesShown = true }
    }

    /// Same resolution as the engine's joint lookup: exact path, `/name`
    /// suffix or last path component.
    private static func jointPath(_ path: String, matches name: String) -> Bool {
        path == name || path.hasSuffix("/" + name) || path.split(separator: "/").last.map(String.init) == name
    }

    private func hideDebugLines() {
        let shown = lock.withLock { () -> Bool in
            defer { debugLinesShown = false }
            return debugLinesShown
        }
        if shown {
            clearDebugLines(named: Self.debugLinesName)
        }
    }
}

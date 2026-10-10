//
//  MocapPoseFilter.swift
//  CoolMirrorMocap
//
//  Temporal smoothing of captured frames: a one-euro filter per joint
//  (adaptive low-pass: heavy smoothing while the joint is still or slow,
//  little while it moves fast, so standing feet stop shaking without the
//  arms lagging). Run at render rate with the newest frame as the target,
//  it also interpolates the phone's 30–60 Hz steps.
//

import Foundation
import simd

public struct MocapSmoothingOptions: Sendable, Equatable {
    /// Low-pass cut-off (Hz) for the upper body when still; lower = steadier
    /// and laggier.
    public var bodyCutoff: Float = 2.0
    /// Cut-off for the hips, legs and feet (and the anchor orientation).
    public var legCutoff: Float = 1.0
    /// Cut-off for the root position (where the character stands).
    public var rootCutoff: Float = 0.6
    /// How much the cut-off rises with speed (per rad/s or m/s): keeps fast
    /// motion responsive. 0 = a plain low-pass.
    public var beta: Float = 0.5
    /// Cut-off of the speed estimate used by `beta`.
    public var derivativeCutoff: Float = 1.0
    public var isEnabled = true
    /// A lower-body joint moving farther than this between two phone
    /// frames is a tracker glitch, not motion: the frame is held back for
    /// up to `glitchHold` seconds. Arms and hands get `maxArmStep`.
    public var maxJointStep: Float = 0.25
    public var maxArmStep: Float = 0.4
    public var glitchHold: TimeInterval = 0.4
    /// Median over the last `medianWindow` phone frames (odd; 1 = off):
    /// a wrong detection shorter than half the window is dropped outright
    /// instead of being smoothed into the motion, at (window − 1) / 2
    /// frames of delay.
    public var medianWindow = 5

    /// Body-yaw guard, on the hip heading. A step of more than
    /// `yawJumpThreshold` within `yawJumpWindow` seconds is a tracker
    /// error (a body turns gradually), unless the heading was already
    /// turning that way at `yawMomentumRate` (rad/s) or more, which makes
    /// it the tracker catching up with a real turn. On an error the
    /// skeleton is turned back about the hips and the heading held until
    /// the tracked one returns within `yawReturnTolerance`, or keeps on
    /// turning the same way by `yawContinueAngle` more (a real turn after
    /// all: released and followed), or, after `yawHold` seconds, is taken
    /// as real and approached at `yawAdoptRate` (rad/s) so nothing ever
    /// snaps. Otherwise the heading follows at up to `maxYawRate` (rad/s).
    /// With a foot planted a body cannot turn its hips much: a jump is
    /// held for `yawHoldPlanted` seconds instead (the tracker turning the
    /// whole skeleton under planted feet is its commonest error), and the
    /// heading follows through a low-pass of `yawCutoffPlanted` (Hz) at
    /// no more than `maxYawRatePlanted`, which takes the tracker's wander
    /// (twenty degrees over two seconds, standing still) out — unless it
    /// is a real turn on the spot, which is then followed at `maxYawRate`:
    /// the tracked heading turning at `yawMomentumRate` or more toward
    /// where it sits, or staying away by `yawBiasThresholdLarge` or more
    /// for `yawBiasTime` seconds, or by `yawBiasThreshold` or more for
    /// `yawBiasTimeSmall` seconds (a slow pivot — longer than the
    /// tracker's wander of twenty-odd degrees with the arms going up,
    /// which drifts at half that rate and comes back before that).
    public var steadyYaw = true
    public var maxYawRate: Float = 4.0 // ~230°/s
    public var yawJumpThreshold: Float = 0.3 // ~17°
    public var yawJumpWindow: TimeInterval = 0.06
    public var yawMomentumRate: Float = 0.7 // ~40°/s
    public var yawMomentumWindow: TimeInterval = 0.3
    public var yawContinueAngle: Float = 0.26 // ~15°
    public var yawReturnTolerance: Float = 0.17 // ~10°
    public var yawHold: TimeInterval = 2.0
    public var yawHoldPlanted: TimeInterval = 12.0
    public var yawAdoptRate: Float = 0.5 // ~30°/s
    public var maxYawRatePlanted: Float = 0.35 // ~20°/s
    public var yawCutoffPlanted: Float = 0.03
    public var yawBiasThreshold: Float = 0.21 // ~12°
    public var yawBiasThresholdLarge: Float = 0.52 // ~30°
    public var yawBiasTime: TimeInterval = 0.5
    public var yawBiasTimeSmall: TimeInterval = 2.0
    /// A foot counts as planted (for the yaw guard) while, over
    /// `plantedWindow`, either foot travels slower than `plantedFootSpeed`
    /// (m/s) in the world (a body standing on one foot cannot turn its
    /// hips fast either), or the leg lengths and the stance width all
    /// change by less than `plantedShapeTolerance` (m): the tracker
    /// shifting or turning the whole skeleton moves the feet but not the
    /// body's shape, a step or a lift does. Lifted again once both feet
    /// move faster than twice the speed with the shape changing.
    public var plantedFootSpeed: Float = 0.15
    public var plantedWindow: TimeInterval = 0.2
    public var plantedShapeTolerance: Float = 0.04

    /// Foot planting: a foot slower than `plantSpeed` (m/s) for
    /// `plantDelay` seconds is pinned near where it is (the pin creeps
    /// after slow drift with time constant `plantCreep`), the knee
    /// re-solved for it, until the tracked foot moves faster than twice
    /// `plantSpeed`, `releaseDistance` away or `releaseRise` up; the
    /// release blends out over `releaseBlend` seconds.
    public var plantFeet = false
    public var plantSpeed: Float = 0.3
    public var plantDelay: TimeInterval = 0.12
    public var plantCreep: TimeInterval = 1.5
    public var releaseDistance: Float = 0.08
    public var releaseRise: Float = 0.04
    public var releaseBlend: TimeInterval = 0.15

    public init() {}

    /// The still cut-off for `joint`'s rotation and position.
    public func cutoff(for joint: MocapJoint) -> Float {
        joint.isLowerBody ? legCutoff : bodyCutoff
    }
}

/// Smoothing factor of a first-order low-pass with cut-off `cutoff` (Hz)
/// sampled every `dt` seconds.
func lowPassAlpha(cutoff: Float, dt: Float) -> Float {
    guard cutoff.isFinite, cutoff > 0 else { return 1 }
    let tau = 1 / (2 * Float.pi * cutoff)
    return 1 / (1 + tau / dt)
}

/// Angle (radians) between two orientations.
public func rotationAngle(between a: simd_quatf, _ b: simd_quatf) -> Float {
    let d = min(1, abs(simd_dot(a.vector, b.vector)))
    return 2 * acos(d)
}

struct OneEuroQuaternion {
    private(set) var value: simd_quatf?
    private var speed: Float = 0

    mutating func filter(_ input: simd_quatf, dt: Float, minCutoff: Float, beta: Float, derivativeCutoff: Float) -> simd_quatf {
        guard let previous = value, dt > 0 else {
            value = input
            return input
        }
        // Same hemisphere as the previous value so the slerp takes the short way.
        var target = input
        if simd_dot(previous.vector, target.vector) < 0 {
            target = simd_quatf(vector: -target.vector)
        }
        let rawSpeed = rotationAngle(between: previous, target) / dt
        let speedAlpha = lowPassAlpha(cutoff: derivativeCutoff, dt: dt)
        speed += speedAlpha * (rawSpeed - speed)
        let alpha = lowPassAlpha(cutoff: minCutoff + beta * speed, dt: dt)
        let output = simd_normalize(simd_slerp(previous, target, alpha))
        value = output
        return output
    }
}

struct OneEuroVector {
    private(set) var value: simd_float3?
    private var speed: Float = 0

    mutating func filter(_ input: simd_float3, dt: Float, minCutoff: Float, beta: Float, derivativeCutoff: Float) -> simd_float3 {
        guard let previous = value, dt > 0 else {
            value = input
            return input
        }
        let rawSpeed = simd_length(input - previous) / dt
        let speedAlpha = lowPassAlpha(cutoff: derivativeCutoff, dt: dt)
        speed += speedAlpha * (rawSpeed - speed)
        let alpha = lowPassAlpha(cutoff: minCutoff + beta * speed, dt: dt)
        let output = previous + alpha * (input - previous)
        value = output
        return output
    }
}

/// Smooths successive frames; feed it the newest frame every render tick
/// with the current time. Also undoes two ARKit body-tracking glitches
/// before smoothing: a left/right relabelling of the arms or the legs is
/// swapped back, and a frame in which a joint jumps farther than a body
/// can move is held back for a moment (see `guardGlitches`).
public struct MocapPoseFilter: Sendable {
    private var rotations: [MocapJoint: OneEuroQuaternion] = [:]
    private var positions: [MocapJoint: OneEuroVector] = [:]
    private var root = OneEuroVector()
    private var lastTime: TimeInterval?
    private var lastAccepted: MocapFrame?
    private var holdUntil: TimeInterval?
    /// After a hold expires, positions blend from the held frame to the
    /// tracked ones over `holdReleaseBlend` seconds instead of snapping.
    private var holdRelease: (start: TimeInterval, from: MocapFrame)?
    public var holdReleaseBlend: TimeInterval = 0.2
    /// Frames the glitch guard rejected since the last accepted one.
    public private(set) var rejectedFrames = 0
    /// Frames whose sides were swapped back.
    public private(set) var swappedFrames = 0

    public init() {}

    public mutating func reset() {
        rotations.removeAll()
        positions.removeAll()
        root = OneEuroVector()
        lastTime = nil
        lastAccepted = nil
        holdUntil = nil
        holdRelease = nil
        plants.removeAll()
        plantedFeet.removeAll()
        rejectedFrames = 0
        swappedFrames = 0
        lastOutput = nil
        trustedYaw = nil
        rawYawHistory.removeAll()
        yawHoldStart = nil
        yawBiasSince = nil
        yawLastTime = nil
        yawFeetHistory.removeAll()
        feetPlanted = false
        isYawHeld = false
        recentRaw.removeAll()
    }

    /// A side of the body ARKit can relabel on its own: the arms (with the
    /// shoulders) or the legs.
    public enum SideGroup: CaseIterable, Sendable {
        case arms, legs

        public var joints: [MocapJoint] {
            switch self {
            case .arms: [.leftShoulder, .leftArm, .leftForearm, .leftHand, .rightShoulder, .rightArm, .rightForearm, .rightHand]
            case .legs: [.leftUpLeg, .leftLeg, .leftFoot, .leftToes, .rightUpLeg, .rightLeg, .rightFoot, .rightToes]
            }
        }
    }

    /// `frame` with the group's left joints' data on the right and vice versa.
    public static func swappingSides(_ frame: MocapFrame, group: SideGroup) -> MocapFrame {
        var swapped = frame
        for joint in group.joints {
            swapped.rotations[joint] = frame.rotations[joint.mirrored]
            swapped.positions[joint] = frame.positions[joint.mirrored]
            if frame.trackedJoints.contains(joint.mirrored) {
                swapped.trackedJoints.insert(joint)
            } else {
                swapped.trackedJoints.remove(joint)
            }
        }
        return swapped
    }

    /// World-space position of a joint.
    private static func world(_ joint: MocapJoint, in frame: MocapFrame) -> simd_float3? {
        guard let p = frame.positions[joint] else { return nil }
        let anchor = frame.rotations[.root] ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        return anchor.act(p) + frame.rootPosition
    }

    /// Mean world distance of the group's joints between two frames.
    private static func distance(_ a: MocapFrame, _ b: MocapFrame, group: SideGroup) -> Float {
        var sum: Float = 0
        var count: Float = 0
        for joint in group.joints {
            guard let pa = world(joint, in: a), let pb = world(joint, in: b) else { continue }
            sum += simd_length(pa - pb)
            count += 1
        }
        return count > 0 ? sum / count : 0
    }

    /// Side-swap undo and jump rejection. Motion is continuous, so of the
    /// two readings of each limb group — as delivered, or with left and
    /// right exchanged — the one nearer the previous accepted frame is
    /// the true one; that undoes ARKit's relabelling without any state.
    /// What still jumps farther than a body can move in one frame is a
    /// glitch and the previous frame stands in for it, for up to
    /// `glitchHold` seconds.
    private mutating func guardGlitches(_ frame: MocapFrame, at time: TimeInterval, options: MocapSmoothingOptions) -> MocapFrame {
        guard let previous = lastAccepted, frame.sequence != previous.sequence else {
            if lastAccepted == nil {
                lastAccepted = frame
            }
            return lastAccepted ?? frame
        }
        var candidate = frame
        for group in SideGroup.allCases where group.joints.allSatisfy({ frame.positions[$0] != nil && previous.positions[$0] != nil }) {
            let swapped = Self.swappingSides(candidate, group: group)
            if Self.distance(swapped, previous, group: group) < Self.distance(candidate, previous, group: group) {
                candidate = swapped
                swappedFrames += 1
            }
        }
        var jump: Float = 0
        for joint in MocapJoint.allCases {
            guard let a = Self.world(joint, in: candidate), let b = Self.world(joint, in: previous) else { continue }
            let limit = joint.isLowerBody ? options.maxJointStep : options.maxArmStep
            jump = max(jump, simd_length(a - b) / limit)
        }
        if jump > 1 {
            if let holdUntil, time >= holdUntil {
                // Held long enough: this is real motion after all; ease into it.
                self.holdUntil = nil
                holdRelease = (time, previous)
            } else {
                if holdUntil == nil {
                    holdUntil = time + options.glitchHold
                }
                rejectedFrames += 1
                return previous
            }
        } else {
            holdUntil = nil
        }
        rejectedFrames = 0
        lastAccepted = candidate
        if let release = holdRelease {
            let s = Float(min(max((time - release.start) / holdReleaseBlend, 0), 1))
            if s < 1 {
                var eased = candidate
                for (joint, position) in candidate.positions {
                    if let from = release.from.positions[joint] {
                        eased.positions[joint] = from + s * (position - from)
                    }
                }
                eased.rootPosition = release.from.rootPosition + s * (candidate.rootPosition - release.from.rootPosition)
                return eased
            }
            holdRelease = nil
        }
        return candidate
    }

    // MARK: - Median over recent frames

    private var recentRaw: [MocapFrame] = []
    private var lastOutput: MocapFrame?

    /// `frame` with every joint position (and the root position) replaced
    /// by the per-component median over the last `window` distinct phone
    /// frames; the newest frame's rotations and flags are kept.
    private mutating func median(_ frame: MocapFrame, window: Int) -> MocapFrame {
        let window = max(1, window | 1)
        guard window > 1 else { return frame }
        if recentRaw.last?.sequence != frame.sequence {
            recentRaw.append(frame)
            if recentRaw.count > window {
                recentRaw.removeFirst(recentRaw.count - window)
            }
        }
        guard recentRaw.count >= 3 else { return frame }
        func median(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func median3(_ values: [simd_float3]) -> simd_float3 {
            simd_float3(median(values.map(\.x)), median(values.map(\.y)), median(values.map(\.z)))
        }
        var output = frame
        for joint in frame.positions.keys {
            let samples = recentRaw.compactMap { $0.positions[joint] }
            if samples.count == recentRaw.count {
                output.positions[joint] = median3(samples)
            }
        }
        output.rootPosition = median3(recentRaw.map(\.rootPosition))
        return output
    }

    // MARK: - Body-yaw guard

    private var trustedYaw: Float?
    /// Recent tracked headings (unwrapped), for the jump and momentum tests.
    private var rawYawHistory: [(time: TimeInterval, yaw: Float)] = []
    private var yawHoldStart: TimeInterval?
    /// The tracked heading (unwrapped) when the hold began.
    private var yawHoldFrom: Float = 0
    private var yawBiasSince: TimeInterval?
    private var yawLastTime: TimeInterval?
    /// Recent world positions of the feet and hips, for the planted test.
    private var yawFeetHistory: [(time: TimeInterval, feet: [MocapJoint: simd_float3], hips: simd_float3)] = []
    /// Whether the heading is currently held against a tracker jump.
    public private(set) var isYawHeld = false
    /// The last measured hip heading (rad) and the correction applied to it.
    public private(set) var lastMeasuredYaw: Float?
    public private(set) var lastYawCorrection: Float = 0
    /// Whether a foot was planted at the last update (the heading then
    /// follows only slowly).
    public private(set) var feetPlanted = false

    /// Heading of the hips in world space (the hip axis; the shoulders
    /// swing with the arms and are no measure of where the body faces),
    /// or nil without both hips.
    static func bodyYaw(of frame: MocapFrame) -> Float? {
        let anchor = frame.rotations[.root] ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        guard let l = frame.positions[.leftUpLeg], let r = frame.positions[.rightUpLeg] else { return nil }
        var d = anchor.act(r - l)
        d.y = 0
        guard simd_length_squared(d) > 1e-6 else { return nil }
        d = simd_normalize(d)
        return atan2(d.z, d.x)
    }

    /// Both feet planted: see `MocapSmoothingOptions.plantedFootSpeed`.
    private mutating func updateFeetPlanted(_ frame: MocapFrame, at time: TimeInterval, options: MocapSmoothingOptions) {
        let anchor = frame.rotations[.root] ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        func world(_ joint: MocapJoint) -> simd_float3? {
            frame.positions[joint].map { anchor.act($0) + frame.rootPosition }
        }
        guard let hips = world(.hips), let left = world(.leftFoot), let right = world(.rightFoot) else {
            feetPlanted = false
            yawFeetHistory.removeAll()
            return
        }
        yawFeetHistory.removeAll { $0.time > time || time - $0.time > options.plantedWindow * 1.5 }
        let feet: [MocapJoint: simd_float3] = [.leftFoot: left, .rightFoot: right]
        defer { yawFeetHistory.append((time, feet, hips)) }
        guard let oldest = yawFeetHistory.first, time - oldest.time >= options.plantedWindow * 0.5 else {
            feetPlanted = false
            return
        }
        let dt = Float(time - oldest.time)
        guard let oldLeft = oldest.feet[.leftFoot], let oldRight = oldest.feet[.rightFoot] else {
            feetPlanted = false
            return
        }
        let speed = min(simd_length(left - oldLeft), simd_length(right - oldRight)) / dt
        // The body's shape: leg lengths (feet to hips) and stance width.
        let shapeChange = max(
            abs(simd_length(left - hips) - simd_length(oldLeft - oldest.hips)),
            abs(simd_length(right - hips) - simd_length(oldRight - oldest.hips)),
            abs(simd_length(left - right) - simd_length(oldLeft - oldRight))
        )
        let shapeSteady = shapeChange < options.plantedShapeTolerance
        // Hysteresis: a planted pair stays planted until a foot clearly moves.
        if speed < options.plantedFootSpeed || shapeSteady {
            feetPlanted = true
        } else if speed > 2 * options.plantedFootSpeed {
            feetPlanted = false
        }
    }

    private static func wrap(_ angle: Float) -> Float {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        return a
    }

    /// Keeps the torso heading within what a body can do and turns the
    /// whole skeleton back about the hips by the rejected part.
    private mutating func steadyYaw(_ frame: inout MocapFrame, at time: TimeInterval, options: MocapSmoothingOptions) {
        guard let raw = Self.bodyYaw(of: frame) else { return }
        updateFeetPlanted(frame, at: time, options: options)
        let dt = Float(min(max(time - (yawLastTime ?? time), 0), 0.25))
        yawLastTime = time
        // The tracked heading, unwrapped against the last one.
        let unwrappedRaw = rawYawHistory.last.map { $0.yaw + Self.wrap(raw - $0.yaw) } ?? raw
        rawYawHistory.removeAll { $0.time > time || time - $0.time > max(options.yawMomentumWindow, options.yawJumpWindow) * 1.5 }
        let jumpSample = rawYawHistory.last { time - $0.time >= options.yawJumpWindow } ?? rawYawHistory.first
        let rawStep = jumpSample.map { unwrappedRaw - $0.yaw } ?? 0
        let momentumSample = rawYawHistory.first
        // How fast the tracked heading has been turning over the momentum window (rad/s).
        let rawRate: Float = momentumSample.map { sample in
            let span = Float(time - sample.time)
            return span > 0.05 ? (unwrappedRaw - sample.yaw) / span : 0
        } ?? 0
        rawYawHistory.append((time, unwrappedRaw))
        guard let trusted = trustedYaw else {
            trustedYaw = raw
            return
        }
        let delta = Self.wrap(raw - trusted)
        let step = max(dt, 1 / 120)
        let planted = feetPlanted
        let fastStep = options.maxYawRate * step
        let adoptStep = options.yawAdoptRate * step
        var next = trusted
        if abs(rawStep) >= options.yawJumpThreshold, yawHoldStart == nil {
            // A step no body makes in a few frames — unless the heading
            // was already turning that way: then the tracker only caught
            // up with a real turn.
            let turningThatWay = momentumSample.map { sample -> Bool in
                let span = Float(time - sample.time)
                guard span > 0.05, let before = jumpSample else { return false }
                let rate = (before.yaw - sample.yaw) / max(span - Float(options.yawJumpWindow), 0.05)
                return abs(rate) >= options.yawMomentumRate && (rate > 0) == (rawStep > 0)
            } ?? false
            if !turningThatWay {
                yawHoldStart = time
                yawHoldFrom = unwrappedRaw
            }
        }
        if let start = yawHoldStart {
            let further = unwrappedRaw - yawHoldFrom
            if abs(delta) <= options.yawReturnTolerance {
                // The tracker came back: the hold is over (the rate limit
                // below still applies to the remaining difference).
                yawHoldStart = nil
            } else if abs(further) >= options.yawContinueAngle, (further > 0) == (Self.wrap(yawHoldFrom - trusted) > 0) {
                // It kept turning the same way: a real turn after all.
                yawHoldStart = nil
            } else if time - start > (planted ? options.yawHoldPlanted : options.yawHold) {
                // Long enough that it must be real: approach it slowly.
                next = trusted + (delta > 0 ? adoptStep : -adoptStep)
            }
        }
        if yawHoldStart == nil {
            // Following. Planted feet: a low-pass, unless the tracked
            // heading has sat away for a while (a slow real turn).
            var wanted = delta
            var maxStep = fastStep
            if planted {
                if abs(delta) > options.yawBiasThreshold {
                    if yawBiasSince == nil { yawBiasSince = time }
                } else {
                    yawBiasSince = nil
                }
                let biasTime = abs(delta) >= options.yawBiasThresholdLarge ? options.yawBiasTime : options.yawBiasTimeSmall
                let biased = yawBiasSince.map { time - $0 >= biasTime } ?? false
                let turning = abs(rawRate) >= options.yawMomentumRate && (rawRate > 0) == (delta > 0) && abs(delta) > options.yawBiasThreshold
                if !biased, !turning {
                    wanted = delta * lowPassAlpha(cutoff: options.yawCutoffPlanted, dt: step)
                    maxStep = options.maxYawRatePlanted * step
                }
            } else {
                yawBiasSince = nil
            }
            next = trusted + min(max(wanted, -maxStep), maxStep)
        }
        trustedYaw = Self.wrap(next)
        let correction = Self.wrap(next - raw)
        isYawHeld = abs(correction) > 1e-3
        lastMeasuredYaw = raw
        lastYawCorrection = correction
        guard isYawHeld, let hips = frame.positions[.hips] else { return }

        // Turn the whole skeleton about the vertical axis through the hips
        // by moving its anchor (orientation, and position so the hips stay
        // put): the joints keep their anchor-space positions, so the
        // smoothing after this sees no flip at all.
        let anchor = frame.rotations[.root] ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        let hipsWorld = anchor.act(hips) + frame.rootPosition
        // A positive turn about y decreases the measured yaw, hence the sign.
        let turn = simd_quatf(angle: -correction, axis: simd_float3(0, 1, 0))
        let turnedAnchor = simd_normalize(turn * anchor)
        frame.rotations[.root] = turnedAnchor
        frame.rootPosition = hipsWorld - turnedAnchor.act(hips)
    }

    // MARK: - Foot planting

    private struct FootPlant {
        /// Pinned world position while planted.
        var locked: simd_float3?
        /// Recent tracked world positions, for the speed estimate.
        var history: [(time: TimeInterval, position: simd_float3)] = []
        var stillSince: TimeInterval?
        /// Release in progress: blending from the pin to the tracked foot.
        var releasing: (start: TimeInterval, from: simd_float3)?
        var lastTime: TimeInterval?
    }

    private var plants: [MocapJoint: FootPlant] = [:]
    /// Feet currently pinned.
    public private(set) var plantedFeet: Set<MocapJoint> = []

    private static let legs: [(hip: MocapJoint, knee: MocapJoint, foot: MocapJoint, toes: MocapJoint)] = [
        (.leftUpLeg, .leftLeg, .leftFoot, .leftToes), (.rightUpLeg, .rightLeg, .rightFoot, .rightToes),
    ]

    /// Pins still feet and re-solves their knees (two-bone IK on the
    /// captured leg, keeping the bend plane), so tracker wobble on a
    /// standing foot never reaches the rig.
    private mutating func plantFeet(_ frame: inout MocapFrame, at time: TimeInterval, options: MocapSmoothingOptions) {
        let anchor = frame.rotations[.root] ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        let root = frame.rootPosition
        for leg in Self.legs {
            guard let foot = frame.positions[leg.foot], let knee = frame.positions[leg.knee], let hip = frame.positions[leg.hip] else { continue }
            var plant = plants[leg.foot, default: FootPlant()]
            let dt = Float(min(max(time - (plant.lastTime ?? time), 0), 0.25))
            plant.lastTime = time
            let tracked = anchor.act(foot) + root
            plant.history.append((time, tracked))
            plant.history.removeAll { time - $0.time > 0.15 }
            let span = time - (plant.history.first?.time ?? time)
            let speed: Float = span >= 0.08 ? simd_length(tracked - plant.history[0].position) / Float(span) : .infinity

            if var locked = plant.locked {
                let away = simd_length(tracked - locked)
                if speed > 2 * options.plantSpeed || away > options.releaseDistance || tracked.y - locked.y > options.releaseRise {
                    plant.locked = nil
                    plant.stillSince = nil
                    plant.releasing = (time, locked)
                } else {
                    // Follow slow drift so the pin never sticks for good.
                    let creep = 1 - expf(-dt / Float(options.plantCreep))
                    locked += creep * (tracked - locked)
                    plant.locked = locked
                }
            } else if speed < options.plantSpeed {
                if plant.stillSince == nil {
                    plant.stillSince = time
                }
                if let since = plant.stillSince, time - since >= options.plantDelay {
                    plant.locked = plant.history.reduce(simd_float3.zero) { $0 + $1.position } / Float(plant.history.count)
                    plant.releasing = nil
                }
            } else {
                plant.stillSince = nil
            }

            // Where the foot goes: the pin, the tail of a release, or the
            // tracked foot.
            var target: simd_float3?
            if let locked = plant.locked {
                target = locked
            } else if let releasing = plant.releasing {
                let s = Float(min(max((time - releasing.start) / options.releaseBlend, 0), 1))
                if s < 1 {
                    target = releasing.from + s * (tracked - releasing.from)
                } else {
                    plant.releasing = nil
                }
            }

            if let target {
                let local = anchor.inverse.act(target - root)
                let offset = local - foot
                frame.positions[leg.foot] = local
                if let toes = frame.positions[leg.toes] {
                    frame.positions[leg.toes] = toes + offset
                }
                if let solved = Self.solveKnee(hip: hip, knee: knee, foot: foot, target: local, forward: anchor.inverse.act(simd_float3(0, 0, 1))) {
                    frame.positions[leg.knee] = solved
                }
            }
            if plant.locked != nil {
                plantedFeet.insert(leg.foot)
            } else {
                plantedFeet.remove(leg.foot)
            }
            plants[leg.foot] = plant
        }
    }

    /// Knee for a moved foot: same thigh and shin lengths, same bend plane
    /// (toward `forward` when the leg is straight).
    static func solveKnee(hip: simd_float3, knee: simd_float3, foot: simd_float3, target: simd_float3, forward: simd_float3) -> simd_float3? {
        let thigh = simd_length(knee - hip)
        let shin = simd_length(foot - knee)
        let toTarget = target - hip
        let distance = simd_length(toTarget)
        guard distance > 1e-4, thigh > 1e-4, shin > 1e-4 else { return nil }
        let u = toTarget / distance
        let reach = min(distance, thigh + shin - 1e-3)
        let a = (thigh * thigh - shin * shin + reach * reach) / (2 * reach)
        let b = sqrt(max(thigh * thigh - a * a, 0))
        var bend = (knee - hip) - simd_dot(knee - hip, u) * u
        if simd_length_squared(bend) < 1e-6 {
            bend = forward - simd_dot(forward, u) * u
        }
        guard simd_length_squared(bend) > 1e-8 else { return nil }
        return hip + a * u + b * simd_normalize(bend)
    }

    /// The smoothed frame; untracked frames pass through untouched.
    public mutating func filter(_ frame: MocapFrame, at time: TimeInterval, options: MocapSmoothingOptions) -> MocapFrame {
        guard options.isEnabled else { return frame }
        // A frame the tracker lost is no pose: the last one stands.
        guard frame.isTracked else { return lastOutput ?? frame }
        let dt = Float(min(max(time - (lastTime ?? time), 0), 0.25))
        lastTime = time
        var frame = guardGlitches(median(frame, window: options.medianWindow), at: time, options: options)
        if options.steadyYaw {
            steadyYaw(&frame, at: time, options: options)
        }

        var output = frame
        for (joint, rotation) in frame.rotations {
            output.rotations[joint] = rotations[joint, default: OneEuroQuaternion()].filter(
                rotation, dt: dt, minCutoff: options.cutoff(for: joint), beta: options.beta, derivativeCutoff: options.derivativeCutoff
            )
        }
        for (joint, position) in frame.positions {
            output.positions[joint] = positions[joint, default: OneEuroVector()].filter(
                position, dt: dt, minCutoff: options.cutoff(for: joint), beta: options.beta, derivativeCutoff: options.derivativeCutoff
            )
        }
        output.rootPosition = root.filter(
            frame.rootPosition, dt: dt, minCutoff: options.rootCutoff, beta: options.beta, derivativeCutoff: options.derivativeCutoff
        )
        if options.plantFeet {
            plantFeet(&output, at: time, options: options)
        } else if !plantedFeet.isEmpty {
            plants.removeAll()
            plantedFeet.removeAll()
        }
        lastOutput = output
        return output
    }
}

/// Measures how much the raw capture moves from one phone frame to the
/// next, before any smoothing: with the user standing still that is pure
/// tracker noise, the number that says whether ARKit itself is the
/// problem. Averages over the last second.
public struct MocapJitterMeter: Sendable {
    public struct Sample: Sendable, Equatable {
        public var time: TimeInterval
        /// Root position step (m).
        public var root: Float
        /// Mean foot position step (m), in anchor space.
        public var feet: Float
        /// Hips orientation step (rad).
        public var hips: Float
        /// Whether the hip or shoulder axis reversed since the previous
        /// frame: the tracker changed its mind about the facing or the sides.
        public var flipped: Bool
    }

    private var previous: MocapFrame?
    private var samples: [Sample] = []
    private let window: TimeInterval = 1
    /// Since the last reset: tracked frames seen and how many flipped.
    public private(set) var totalFrames = 0
    public private(set) var totalFlips = 0

    public init() {}

    public mutating func reset() {
        previous = nil
        samples.removeAll()
        totalFrames = 0
        totalFlips = 0
    }

    /// Records the step from the previous raw frame to `frame`.
    public mutating func add(_ frame: MocapFrame, at time: TimeInterval) {
        defer { previous = frame }
        guard frame.isTracked, let previous, previous.isTracked, frame.sequence != previous.sequence else { return }
        let root = simd_length(frame.rootPosition - previous.rootPosition)
        var feet: Float = 0
        var feetCount: Float = 0
        for joint in [MocapJoint.leftFoot, .rightFoot] {
            if let a = frame.positions[joint], let b = previous.positions[joint] {
                feet += simd_length(a - b)
                feetCount += 1
            }
        }
        var hips: Float = 0
        if let a = frame.rotations[.hips], let b = previous.rotations[.hips] {
            hips = rotationAngle(between: a, b)
        }
        var flipped = false
        for (left, right) in [(MocapJoint.leftUpLeg, MocapJoint.rightUpLeg), (.leftShoulder, .rightShoulder)] {
            if let a = Self.axis(frame, left, right), let b = Self.axis(previous, left, right), simd_dot(a, b) < -0.5 {
                flipped = true
            }
        }
        samples.append(Sample(time: time, root: root, feet: feetCount > 0 ? feet / feetCount : 0, hips: hips, flipped: flipped))
        samples.removeAll { time - $0.time > window }
        totalFrames += 1
        if flipped {
            totalFlips += 1
        }
    }

    /// e.g. "flips 12 in 1340 frames (0.9%)" since the last reset.
    public var totals: String {
        guard totalFrames > 0 else { return "no tracked frames yet" }
        return String(format: "flips %d in %d frames (%.1f%%)", totalFlips, totalFrames, 100 * Float(totalFlips) / Float(totalFrames))
    }

    /// World-space left → right axis between two joints.
    private static func axis(_ frame: MocapFrame, _ left: MocapJoint, _ right: MocapJoint) -> simd_float3? {
        guard let l = frame.positions[left], let r = frame.positions[right] else { return nil }
        let anchor = frame.rotations[.root] ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        let d = anchor.act(r - l)
        return simd_length_squared(d) > 1e-6 ? simd_normalize(d) : nil
    }

    /// Frames in the window whose facing or sides reversed.
    public var flips: Int {
        samples.filter(\.flipped).count
    }

    /// Mean step per frame over the window, or nil without two frames.
    public func average() -> Sample? {
        guard !samples.isEmpty else { return nil }
        let n = Float(samples.count)
        return Sample(
            time: samples.last!.time,
            root: samples.reduce(0) { $0 + $1.root } / n,
            feet: samples.reduce(0) { $0 + $1.feet } / n,
            hips: samples.reduce(0) { $0 + $1.hips } / n,
            flipped: false
        )
    }

    /// e.g. "raw step/frame: root 4 mm · feet 9 mm · hips 0.6° · flips 2/s"
    public var report: String {
        guard let a = average() else { return "raw step/frame: —" }
        return String(
            format: "raw step/frame: root %.0f mm · feet %.0f mm · hips %.1f° · flips %d/s",
            a.root * 1000, a.feet * 1000, a.hips * 180 / .pi, flips
        )
    }
}

//
//  MocapFootAnchor.swift
//  CoolMirrorMocap
//
//  The character built from the feet up. The phone's skeleton hangs from
//  its hips: every wobble of the tracked root carries the feet with it,
//  and the person feels driven from the hip. Here the planted foot is the
//  fixed point instead — its rig ankle is held where it landed, on the
//  floor, and the root translation is corrected so the hips move relative
//  to that foot exactly as captured. A step hands the anchor to the other
//  foot where it lands, so nothing jumps. Pure and testable.
//

import Foundation
import simd

public struct MocapFootAnchor: Sendable {
    /// A foot is planted once its captured speed over `window` seconds
    /// stays below this (m/s), and lifted as soon as its speed over the
    /// last `liftWindow` exceeds twice it: planting is slow and sure,
    /// lifting is quick, so an anchor never holds a foot down that is
    /// leaving.
    /// Speed is the smaller of the foot's travel in the world and its
    /// travel relative to the root: a root that wobbles carries both feet
    /// with it, which is no step.
    public var plantedSpeed: Float = 0.15
    public var window: TimeInterval = 0.2
    /// Lifting is judged over this long: one jittery frame is no lift.
    public var liftWindow: TimeInterval = 0.05
    /// Only a foot this close to the floor may become the anchor: a foot
    /// held still in the air is planted in nothing, and anchoring it
    /// would pull it (and the whole character) down to the floor.
    public var floorTolerance: Float = 0.06
    /// Fraction of the remaining error closed per update (the rig pose read
    /// each frame already carries the previous correction).
    public var gain: Float = 0.8
    /// A foot that takes the anchor is held where it is and brought to
    /// the floor at this speed (m/s): the tracked feet land at different
    /// heights, and snapping each new anchor to the floor at once moved
    /// the whole body up and down by the difference at every step.
    public var settleSpeed: Float = 0.25

    /// The root translation correction, in the space of the positions given.
    public private(set) var correction = simd_float3.zero
    /// The foot the character stands on, and where its ankle is held.
    public private(set) var anchor: MocapJoint?
    public private(set) var anchorPosition = simd_float3.zero

    /// The feet standing still, from the captured travel.
    public private(set) var planted: Set<MocapJoint> = []
    private var history: [(time: TimeInterval, feet: [MocapJoint: simd_float3], root: simd_float3)] = []

    public static let feet: [MocapJoint] = [.leftFoot, .rightFoot]

    public init() {}

    /// `captured`: the captured ankles and `root` the captured root, in
    /// one consistent space (only their travel matters). `rig`: the rig's
    /// ankle (and toe) positions as composed last frame, `floor`: each
    /// one's height when standing, both in the space of the correction.
    /// `horizontal`: whether the anchor may correct sideways too (off, the
    /// character walks in place: only the floor holds).
    public mutating func update(
        captured: [MocapJoint: simd_float3], root: simd_float3, rig: [MocapJoint: simd_float3], floor: [MocapJoint: Float],
        time: TimeInterval, horizontal: Bool
    ) -> simd_float3 {
        // Planted feet, from the captured travel.
        history.removeAll { $0.time > time || time - $0.time > window * 1.5 }
        func speed(of foot: MocapJoint, since sample: (time: TimeInterval, feet: [MocapJoint: simd_float3], root: simd_float3)) -> Float? {
            guard let now = captured[foot], let was = sample.feet[foot], time > sample.time else { return nil }
            let world = simd_length(now - was)
            let relative = simd_length((now - root) - (was - sample.root))
            return min(world, relative) / Float(time - sample.time)
        }
        for foot in Self.feet {
            guard captured[foot] != nil else {
                planted.remove(foot)
                continue
            }
            let liftSample = history.last { time - $0.time >= liftWindow } ?? history.first
            if let liftSample, let recent = speed(of: foot, since: liftSample), recent > 2 * plantedSpeed {
                planted.remove(foot)
            } else if let oldest = history.first, time - oldest.time >= window * 0.5, let slow = speed(of: foot, since: oldest), slow < plantedSpeed {
                planted.insert(foot)
            }
        }
        history.append((time, captured, root))

        // The anchor: the current foot while it stays planted, else the
        // lower planted foot that is on the floor, held where its ankle is
        // now, at floor height.
        if let current = anchor, !planted.contains(current) || rig[current] == nil {
            anchor = nil
        }
        if anchor == nil {
            let candidates = Self.feet.filter { foot in
                guard planted.contains(foot), let position = rig[foot], let height = floor[foot] else { return false }
                return position.y - height <= floorTolerance
            }
            if let foot = candidates.min(by: { rig[$0]!.y < rig[$1]!.y }) {
                anchor = foot
                anchorPosition = rig[foot]!
            }
        }

        let dt = Float(history.count >= 2 ? time - history[history.count - 2].time : 0)
        if let anchor, let position = rig[anchor] {
            // Settle the anchor onto the floor.
            if let height = floor[anchor] {
                let toFloor = height - anchorPosition.y
                anchorPosition.y += min(max(toFloor, -settleSpeed * dt), settleSpeed * dt)
            }
            // The rig ankle hangs from the tracked root: this frame it will
            // move by whatever the captured ankle moved since the frame the
            // rig pose was composed from. Cancel that in full, and close a
            // fraction of what remained.
            var error = anchorPosition - position
            var travel = simd_float3.zero
            if let previous = history.dropLast().last?.feet[anchor], let now = captured[anchor] {
                travel = now - previous
            }
            if !horizontal {
                error.x = 0
                error.z = 0
                travel.x = 0
                travel.z = 0
            }
            correction += gain * error - travel
        } else {
            // No foot planted (a step in progress, a hop): bring the lowest
            // foot to the floor, both ways (lifting only would let every
            // step ratchet the body upward) and no faster than a settling
            // anchor, so a foot that lands high does not snap the body.
            var lowest: Float?
            for (foot, position) in rig {
                guard let height = floor[foot] else { continue }
                let rise = position.y - height
                lowest = min(lowest ?? rise, rise)
            }
            if let lowest {
                correction.y -= min(max(gain * lowest, -settleSpeed * dt), settleSpeed * dt)
            }
        }
        return correction
    }

    public mutating func reset() {
        var fresh = MocapFootAnchor()
        fresh.plantedSpeed = plantedSpeed
        fresh.window = window
        fresh.liftWindow = liftWindow
        fresh.floorTolerance = floorTolerance
        fresh.gain = gain
        fresh.settleSpeed = settleSpeed
        self = fresh
    }
}

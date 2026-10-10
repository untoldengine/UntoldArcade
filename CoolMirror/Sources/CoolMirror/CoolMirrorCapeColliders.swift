//
//  CoolMirrorCapeColliders.swift
//  CoolMirror
//
//  The cape's body colliders, fitted to the character's own mesh: one
//  convex hull per bone segment, built from the segment's skinned
//  vertices in the segment's joint frame and moved with that joint (the
//  elbow pad, the belt and the back are their own shape, not a tube's),
//  with a capsule through the joints as the fallback where the mesh gives
//  too few vertices. Pure and testable.
//

import Foundation
import simd

enum CoolMirrorCapeColliders {
    /// A bone segment to wrap: the capsule runs `from` → `to`. A vertex
    /// sizes the segment whose `from` joint is the nearest ancestor of
    /// the joint that owns most of it (twist and helper bones hang under
    /// the bone they belong to).
    struct Segment {
        var from: String
        var to: String
        /// The radius when the mesh gives no vertices for the segment.
        var fallbackRadius: Float
        /// Where along the bone the capsule starts and ends (0 = at
        /// `from`, 1 = at `to`). A partial segment is sized by the
        /// vertices over its own stretch of the bone only: the shoulder
        /// is the first third of the upper arm bone, the arm the rest.
        var startFraction: Float = 0
        var endFraction: Float = 1
        /// Ceiling on the fitted radius: a gauntlet's fins or a boot's
        /// top must not make an arm or a foot a barrel that shoves the
        /// cape about when the limb comes near it.
        var maxRadius: Float = CoolMirrorCapeColliders.radiusRange.upperBound
        /// Sized by the vertices all around the bone rather than those on
        /// the cape's side: the cape drapes over a shoulder's top and
        /// outside, not its back.
        var allAround = false
        /// A convex hull of the segment's vertices, or the capsule alone.
        /// Jolt tests every cloth particle against every plane of every
        /// hull each step, so hulls go where a tube is visibly wrong (the
        /// torso, shoulders and arms the cape drapes over) and the legs,
        /// which the cape only brushes, stay capsules.
        var hull = true
    }

    /// A fitted collider: the convex hull of `hull` (points in the `from`
    /// joint's rest frame, moved with that joint) when the mesh gave one,
    /// otherwise a capsule of `radius` through the joints; `shift` is the
    /// capsule's axis offset in the `from` joint's rest frame.
    struct Fit {
        var from: String
        var to: String
        var fromJoint: Int
        var toJoint: Int
        var startFraction: Float
        var endFraction: Float
        var shift: simd_float3
        var radius: Float
        var hull: [simd_float3]
        /// The hull's bounding slab along every `directions` entry (joint
        /// frame): the farthest hull point's extent. A cheap
        /// inside/outside test for the mesh vertices.
        var slabs: [Float]
        /// The hull's bounds in the joint frame.
        var hullBounds: (min: simd_float3, max: simd_float3)
        var vertices: Int
    }

    /// A collider's kinematic pose for a set of joints.
    struct Pose {
        var position: simd_float3
        var rotation: simd_quatf
    }

    /// The margin the mesh vertices keep off a collider when they are
    /// pushed out of it after the cloth step (see `pushOut`).
    static let meshClearance: Float = 0.006

    /// The hull keeps the vertices farthest along this many directions
    /// (about twenty points describe a limb; Jolt builds the hull). Cost
    /// grows with the planes: the headless scenario steps in 2.0 ms at 24
    /// directions, 1.6 at 16, 2.9 with hulls on the legs too, 0.5 with
    /// capsules everywhere (Release, this Mac).
    static let hullDirections = 24

    /// `hullDirections` unit directions spread over the sphere.
    static let directions: [simd_float3] = {
        let golden = Float.pi * (3 - sqrt(5))
        return (0 ..< hullDirections).map { index in
            let y = 1 - 2 * (Float(index) + 0.5) / Float(hullDirections)
            let r = sqrt(max(0, 1 - y * y))
            let angle = golden * Float(index)
            return simd_float3(r * cos(angle), y, r * sin(angle))
        }
    }()

    /// Radii from the mesh are clamped to this range: an outlier vertex
    /// (a glove skinned to the forearm) must not swell a limb, and a
    /// sliver of vertices must not leave a segment without a body.
    static let radiusRange: ClosedRange<Float> = 0.03 ... 0.2
    /// The vertices' radial spread that the capsule covers.
    static let radiusPercentile: Float = 0.9

    /// The upper back and the shoulders are wrapped too, collar pins and
    /// all: Jolt leaves a pinned vertex where it is put, and the headless
    /// scenario with the shoulders at 12 cm (forty pins inside) stays as
    /// calm as without them.
    static func segments(_ rig: CoolMirrorCapeRig) -> [Segment] {
        [
            Segment(from: rig.pelvis, to: rig.spine, fallbackRadius: 0.11),
            Segment(from: rig.spine, to: rig.chest, fallbackRadius: 0.1),
            Segment(from: rig.chest, to: rig.upperChest, fallbackRadius: 0.1),
            // The shoulders (trapezius, pads, deltoids): the cape drapes
            // over their top and outside, so they are sized all around.
            Segment(from: rig.leftClavicle, to: rig.leftUpperArm, fallbackRadius: 0.06, maxRadius: 0.12, allAround: true),
            Segment(from: rig.rightClavicle, to: rig.rightUpperArm, fallbackRadius: 0.06, maxRadius: 0.12, allAround: true),
            Segment(from: rig.leftUpperArm, to: rig.leftForearm, fallbackRadius: 0.07, endFraction: 0.35, maxRadius: 0.12, allAround: true),
            Segment(from: rig.rightUpperArm, to: rig.rightForearm, fallbackRadius: 0.07, endFraction: 0.35, maxRadius: 0.12, allAround: true),
            // Batman's arm, measured: the upper arm is 9–11 cm thick at the
            // elbow (its pad), the forearm 7–8 cm at the middle, the
            // gauntlet's fins 12–16 cm out. The ceilings trim the fins only.
            Segment(from: rig.leftUpperArm, to: rig.leftForearm, fallbackRadius: 0.05, startFraction: 0.35, maxRadius: 0.11),
            Segment(from: rig.rightUpperArm, to: rig.rightForearm, fallbackRadius: 0.05, startFraction: 0.35, maxRadius: 0.11),
            Segment(from: rig.leftForearm, to: rig.leftHand, fallbackRadius: 0.04, maxRadius: 0.1),
            Segment(from: rig.rightForearm, to: rig.rightHand, fallbackRadius: 0.04, maxRadius: 0.1),
            Segment(from: rig.leftThigh, to: rig.leftCalf, fallbackRadius: 0.08, hull: false),
            Segment(from: rig.rightThigh, to: rig.rightCalf, fallbackRadius: 0.08, hull: false),
            Segment(from: rig.leftCalf, to: rig.leftFoot, fallbackRadius: 0.06, hull: false),
            Segment(from: rig.rightCalf, to: rig.rightFoot, fallbackRadius: 0.06, hull: false),
            Segment(from: rig.leftFoot, to: rig.leftToe, fallbackRadius: 0.05, maxRadius: 0.12, hull: false),
            Segment(from: rig.rightFoot, to: rig.rightToe, fallbackRadius: 0.05, maxRadius: 0.12, hull: false),
        ]
    }

    /// Joints whose vertices size no segment: the neck, head and hands,
    /// and everything under them (a glove would swell the forearm).
    static func excludedJoints(_ rig: CoolMirrorCapeRig) -> [String] {
        [rig.neck, rig.head, rig.leftHand, rig.rightHand]
    }

    /// Fits the segments to a mesh at rest: `positions` in the space of
    /// `restJoints` (world, the character's transform applied), skinned
    /// by `jointIndices`/`jointWeights` (skeleton indices; `parents` the
    /// skeleton's parent of each joint). A segment whose joints the
    /// skeleton lacks is skipped. With `back` (the side the cape hangs
    /// on), the capsule stays on the bone and its radius is the extent of
    /// the vertices within 45° of that side: the surface the cape touches,
    /// not the average of a wide belt with a deep chest.
    static func fit(
        _ segments: [Segment], excluding excluded: [String], positions: [simd_float3], jointIndices: [simd_ushort4], jointWeights: [simd_float4],
        restJoints: [CoolMirrorCapeCloth.JointFrame], parents: [Int?], jointIndexByName: [String: Int], back: simd_float3? = nil
    ) -> [Fit] {
        // Which segment a joint sizes: the nearest ancestor (itself
        // included) that starts a segment, unless an excluded joint
        // comes first.
        var segmentsOfStart: [Int: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            if let joint = jointIndexByName[segment.from] { segmentsOfStart[joint, default: []].append(index) }
        }
        let excludedJoints = Set(excluded.compactMap { jointIndexByName[$0] })
        var segmentsOfJoint: [Int: [Int]] = [:]
        func segmentsSized(by joint: Int) -> [Int] {
            if let known = segmentsOfJoint[joint] { return known }
            var current: Int? = joint
            var result: [Int] = []
            var visited = 0
            while let j = current, visited < parents.count {
                visited += 1
                if excludedJoints.contains(j) { break }
                if let indices = segmentsOfStart[j] {
                    result = indices
                    break
                }
                current = j < parents.count ? parents[j] : nil
            }
            segmentsOfJoint[joint] = result
            return result
        }

        // Every vertex goes to the segments of the joint that owns most
        // of it; a partial segment takes only the vertices over its
        // stretch of the bone.
        var verticesOfSegment = [[simd_float3]](repeating: [], count: segments.count)
        if jointIndices.count == positions.count, jointWeights.count == positions.count {
            for (vertex, p) in positions.enumerated() {
                let ids = jointIndices[vertex], w = jointWeights[vertex]
                var owner = Int(ids.x), best = w.x
                if w.y > best { owner = Int(ids.y); best = w.y }
                if w.z > best { owner = Int(ids.z); best = w.z }
                if w.w > best { owner = Int(ids.w) }
                for index in segmentsSized(by: owner) {
                    let segment = segments[index]
                    if segment.startFraction > 0 || segment.endFraction < 1,
                       let a = jointIndexByName[segment.from], let b = jointIndexByName[segment.to], a < restJoints.count, b < restJoints.count
                    {
                        let axis = restJoints[b].position - restJoints[a].position
                        let t = simd_dot(p - restJoints[a].position, axis) / max(simd_length_squared(axis), 1e-8)
                        guard t >= segment.startFraction, t <= segment.endFraction else { continue }
                    }
                    verticesOfSegment[index].append(p)
                }
            }
        }
        var fits: [Fit] = []
        for (index, segment) in segments.enumerated() {
            guard let a = jointIndexByName[segment.from], let b = jointIndexByName[segment.to],
                  a < restJoints.count, b < restJoints.count
            else { continue }
            let start = restJoints[a].position, end = restJoints[b].position
            let axis = end - start
            let lengthSquared = simd_length_squared(axis)
            guard lengthSquared > 1e-6 else { continue }
            let vertices = verticesOfSegment[index]
            var fit = Fit(from: segment.from, to: segment.to, fromJoint: a, toJoint: b, startFraction: segment.startFraction, endFraction: segment.endFraction, shift: .zero, radius: segment.fallbackRadius, hull: [], slabs: [], hullBounds: (.zero, .zero), vertices: vertices.count)
            if vertices.count >= 24 {
                // Sideways offsets of the vertices from the axis; the
                // capsule's axis moves to their mean, its radius covers
                // most of their spread around it.
                let offsets = vertices.map { p -> simd_float3 in
                    let d = p - start
                    return d - axis * (simd_dot(d, axis) / lengthSquared)
                }
                // The hull: the vertices within the radius ceiling (a
                // gauntlet's fins stay out), in the joint's rest frame.
                let inverseRest = restJoints[a].rotation.inverse
                var local: [simd_float3] = []
                local.reserveCapacity(vertices.count)
                for (p, offset) in zip(vertices, offsets) where simd_length(offset) <= segment.maxRadius {
                    local.append(inverseRest.act(p - start))
                }
                fit.hull = segment.hull ? hullPoints(local) : []
                if !fit.hull.isEmpty {
                    fit.slabs = directions.map { d in fit.hull.reduce(-Float.greatestFiniteMagnitude) { max($0, simd_dot($1, d)) } }
                    fit.hullBounds = (fit.hull.reduce(fit.hull[0], simd_min), fit.hull.reduce(fit.hull[0], simd_max))
                }
                var mean = simd_float3.zero
                var spread: [Float]
                let band = segment.allAround ? [] : back.map { back in offsets.filter { simd_length_squared($0) > 1e-8 && simd_dot(simd_normalize($0), back) >= 0.7071 } } ?? []
                if band.count >= 24 {
                    spread = band.map { simd_length($0) }
                } else {
                    mean = offsets.reduce(simd_float3.zero, +) / Float(offsets.count)
                    spread = offsets.map { simd_length($0 - mean) }
                }
                spread.sort()
                let index = min(spread.count - 1, Int(Float(spread.count - 1) * radiusPercentile))
                fit.radius = min(spread[index].clamped(to: radiusRange), segment.maxRadius)
                fit.shift = restJoints[a].rotation.inverse.act(mean)
            }
            fits.append(fit)
        }
        return fits
    }

    /// The extreme points of `points` along `hullDirections` directions
    /// spread over the sphere: what a convex hull of them needs (fewer
    /// than four distinct points, or all coplanar, is no hull).
    static func hullPoints(_ points: [simd_float3]) -> [simd_float3] {
        guard points.count >= 4 else { return [] }
        var chosen = Set<Int>()
        for direction in directions {
            var best = 0
            var bestDot = -Float.greatestFiniteMagnitude
            for (i, p) in points.enumerated() {
                let d = simd_dot(p, direction)
                if d > bestDot {
                    bestDot = d
                    best = i
                }
            }
            chosen.insert(best)
        }
        let hull = chosen.sorted().map { points[$0] }
        guard hull.count >= 4 else { return [] }
        // Not all coplanar.
        let a = hull[0]
        var normal = simd_float3.zero
        for i in 1 ..< hull.count {
            for j in i + 1 ..< hull.count {
                let n = simd_cross(hull[i] - a, hull[j] - a)
                if simd_length_squared(n) > simd_length_squared(normal) { normal = n }
            }
        }
        guard simd_length_squared(normal) > 1e-12 else { return [] }
        normal = simd_normalize(normal)
        guard hull.contains(where: { abs(simd_dot($0 - a, normal)) > 1e-3 }) else { return [] }
        return hull
    }

    /// Moves every point of `points` (world) that is inside a collider out
    /// to its surface plus `meshClearance`. Jolt collides the cloth
    /// particles only, and they sit centimetres apart: an elbow's point
    /// slips between three particles that are all outside it and shows
    /// through the mesh triangle they span. So the mesh vertices, skinned
    /// from the particles, are pushed out themselves. A hull is tested as
    /// the intersection of its `directions` slabs (a hair larger than the
    /// hull at its corners), a capsule as itself.
    static func pushOut(_ points: inout [simd_float3], fits: [Fit], joints: [CoolMirrorCapeCloth.JointFrame]) {
        let capsules = capsules(fits, joints: joints)
        for (fit, capsule) in zip(fits, capsules) {
            if !fit.hull.isEmpty, fit.fromJoint < joints.count {
                let joint = joints[fit.fromJoint]
                let inverse = joint.rotation.inverse
                let lo = fit.hullBounds.min - meshClearance, hi = fit.hullBounds.max + meshClearance
                for index in points.indices {
                    let local = inverse.act(points[index] - joint.position)
                    guard local.x > lo.x, local.y > lo.y, local.z > lo.z, local.x < hi.x, local.y < hi.y, local.z < hi.z else { continue }
                    // Inside every slab: push out through the nearest one.
                    var nearest = 0
                    var nearestDistance = -Float.greatestFiniteMagnitude
                    var inside = true
                    for (slot, direction) in directions.enumerated() {
                        let distance = simd_dot(local, direction) - fit.slabs[slot]
                        if distance >= meshClearance {
                            inside = false
                            break
                        }
                        if distance > nearestDistance {
                            nearestDistance = distance
                            nearest = slot
                        }
                    }
                    guard inside else { continue }
                    let moved = local + directions[nearest] * (meshClearance - nearestDistance)
                    points[index] = joint.position + joint.rotation.act(moved)
                }
            } else {
                let axis = capsule.end - capsule.start
                let lengthSquared = max(simd_length_squared(axis), 1e-8)
                let wanted = capsule.radius + meshClearance
                for index in points.indices {
                    let p = points[index]
                    let t = simd_clamp(simd_dot(p - capsule.start, axis) / lengthSquared, 0, 1)
                    let closest = capsule.start + axis * t
                    let d = p - closest
                    let distance = simd_length(d)
                    if distance < wanted, distance > 1e-6 {
                        points[index] = closest + d / distance * wanted
                    }
                }
            }
        }
    }

    /// The push-out from the last frame carried into this one: a
    /// displacement that grew is taken at once (the body must not show),
    /// one that shrank eases back with the time constant `releaseSeconds`
    /// (gone within a quarter second), so the mesh does not snap when the
    /// body moves away.
    static let releaseSeconds: Float = 0.06
    static func eased(previous: [simd_float3], target: [simd_float3], dt: Float) -> [simd_float3] {
        guard previous.count == target.count, dt > 0 else { return target }
        let s = 1 - exp(-dt / releaseSeconds)
        return zip(previous, target).map { was, now in
            simd_length_squared(now) >= simd_length_squared(was) ? now : was + (now - was) * s
        }
    }

    /// The kinematic pose of every fit for the current joints: a hull sits
    /// on its joint, a capsule's centre is on the (shifted) bone with its
    /// axis along it.
    static func poses(_ fits: [Fit], joints: [CoolMirrorCapeCloth.JointFrame]) -> [Pose] {
        zip(fits, capsules(fits, joints: joints)).map { fit, capsule in
            if !fit.hull.isEmpty, fit.fromJoint < joints.count {
                return Pose(position: joints[fit.fromJoint].position, rotation: joints[fit.fromJoint].rotation)
            }
            let (position, rotation) = capsulePose(from: capsule.start, to: capsule.end)
            return Pose(position: position, rotation: rotation)
        }
    }

    /// A capsule's centre and the rotation taking its local y axis along `a → b`.
    static func capsulePose(from a: simd_float3, to b: simd_float3) -> (simd_float3, simd_quatf) {
        let axis = b - a
        let length = simd_length(axis)
        guard length > 1e-5 else { return ((a + b) * 0.5, simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))) }
        let direction = axis / length
        let up = simd_float3(0, 1, 0)
        let rotation: simd_quatf
        if simd_dot(up, direction) < -0.9999 {
            rotation = simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
        } else {
            rotation = simd_normalize(simd_quatf(from: up, to: direction))
        }
        return ((a + b) * 0.5, rotation)
    }

    /// The fitted capsules for the current joints (the fallback shape, and
    /// the start-placement approximation of every collider).
    static func capsules(_ fits: [Fit], joints: [CoolMirrorCapeCloth.JointFrame]) -> [CoolMirrorCapeCloth.Capsule] {
        fits.compactMap { fit in
            guard fit.fromJoint < joints.count, fit.toJoint < joints.count else { return nil }
            let shift = joints[fit.fromJoint].rotation.act(fit.shift)
            let from = joints[fit.fromJoint].position + shift, to = joints[fit.toJoint].position + shift
            return .init(start: from + (to - from) * fit.startFraction, end: from + (to - from) * fit.endFraction, radius: fit.radius)
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

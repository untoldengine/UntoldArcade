//
//  CoolBowlingPinMesh.swift
//  CoolBowling
//
//  The pin's visual, built at runtime: a profile revolved into vertex
//  arrays and handed to the engine's `Mesh.makeMesh`. The engine's file
//  loaders only take cooked `.untold` assets, so this is how a demo draws a
//  shape the primitives don't cover.
//

import Foundation
import simd
import UntoldEngine

enum CoolBowlingPinMesh {
    /// (radius, height) samples of a regulation pin, base at y = 0.
    static let profile: [(r: Float, y: Float)] = [
        (0.000, 0.000), (0.030, 0.000), (0.040, 0.004), (0.050, 0.020), (0.058, 0.060),
        (0.0605, 0.110), (0.058, 0.150), (0.050, 0.190), (0.040, 0.220), (0.031, 0.250),
        (0.026, 0.275), (0.026, 0.300), (0.031, 0.320), (0.036, 0.340), (0.034, 0.362),
        (0.024, 0.376), (0.010, 0.381), (0.000, 0.381),
    ]

    /// Revolves the profile in `segments` steps. Main actor: the engine
    /// allocates the Metal buffers on the render device.
    @MainActor static func makeMeshes(segments: Int = 32) -> [Mesh] {
        let rings = profile.count
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(rings * (segments + 1))
        for (index, point) in profile.enumerated() {
            let previous = profile[max(index - 1, 0)]
            let next = profile[min(index + 1, rings - 1)]
            let tangent = SIMD2<Float>(next.r - previous.r, next.y - previous.y)
            let outward = simd_normalize(SIMD2<Float>(tangent.y, -tangent.x))
            for segment in 0 ... segments {
                let angle = Float(segment) / Float(segments) * 2 * .pi
                let c = cosf(angle), s = sinf(angle)
                positions.append(SIMD3<Float>(point.r * c, point.y, point.r * s))
                normals.append(point.r < 1e-4
                    ? SIMD3<Float>(0, point.y > 0.1 ? 1 : -1, 0)
                    : simd_normalize(SIMD3<Float>(outward.x * c, outward.y, outward.x * s)))
                uvs.append(SIMD2<Float>(Float(segment) / Float(segments), point.y / CoolBowlingScene.pinHeight))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity((rings - 1) * segments * 6)
        for ring in 0 ..< rings - 1 {
            for segment in 0 ..< segments {
                let a = UInt32(ring * (segments + 1) + segment), b = a + 1
                let c = UInt32((ring + 1) * (segments + 1) + segment), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        guard let mesh = Mesh.makeMesh(positions: positions, normals: normals, uvs: uvs, indices: indices, name: "BowlingPin") else {
            return []
        }
        return [mesh]
    }
}

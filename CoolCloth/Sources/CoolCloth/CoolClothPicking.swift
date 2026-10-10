import Foundation
import simd

/// One cloth particle hit by a picking ray.
public struct CoolClothPick: Sendable {
    public let column: Int
    public let row: Int
    public let worldPosition: SIMD3<Float>
    /// Distance from the particle to the ray (perpendicular), world units.
    public let distanceToRay: Float
    /// Distance along the ray to the particle's closest point, world units.
    public let rayDistance: Float
}

/// CPU snapshot of the particle positions, refreshed once per simulated frame by
/// the render extension, used for gaze/pinch picking without a GPU round-trip.
final class CoolClothPickingStore: @unchecked Sendable {
    static let shared = CoolClothPickingStore()

    private let lock = NSLock()
    private var positions: [SIMD4<Float>] = []
    private var modelMatrix = matrix_identity_float4x4
    private var gridSize = 0

    private init() {}

    func update(positions: [SIMD4<Float>], gridSize: Int, modelMatrix: simd_float4x4) {
        lock.withLock {
            self.positions = positions
            self.gridSize = gridSize
            self.modelMatrix = modelMatrix
        }
    }

    func snapshot() -> (positions: [SIMD4<Float>], gridSize: Int, model: simd_float4x4) {
        lock.withLock { (positions, gridSize, modelMatrix) }
    }

    func resetForTesting() {
        lock.withLock {
            positions = []
            gridSize = 0
            modelMatrix = matrix_identity_float4x4
        }
    }
}

/// Finds the particle nearest to a world-space ray. Returns nil until the
/// simulation has produced at least one frame, or when nothing is within
/// `maxDistanceToRay`.
public func pickCoolClothParticle(
    rayOriginWorld: SIMD3<Float>,
    rayDirectionWorld: SIMD3<Float>,
    maxDistanceToRay: Float
) -> CoolClothPick? {
    guard rayOriginWorld.allFinite, rayDirectionWorld.allFinite else { return nil }
    let directionLength = simd_length(rayDirectionWorld)
    guard directionLength > 1e-6 else { return nil }
    let direction = rayDirectionWorld / directionLength

    let (positions, gridSize, model) = CoolClothPickingStore.shared.snapshot()
    guard gridSize > 0, positions.count == gridSize * gridSize else { return nil }

    var best: CoolClothPick?
    var bestScore = Float.greatestFiniteMagnitude
    for row in 0 ..< gridSize {
        for column in 0 ..< gridSize {
            let local = positions[row * gridSize + column]
            let world4 = model * SIMD4<Float>(local.x, local.y, local.z, 1)
            let world = SIMD3<Float>(world4.x, world4.y, world4.z)
            let t = simd_dot(world - rayOriginWorld, direction)
            guard t > 0 else { continue }
            let closest = rayOriginWorld + direction * t
            let distance = simd_length(world - closest)
            guard distance <= maxDistanceToRay else { continue }
            // Prefer the particle closest to the ray, breaking near-ties by
            // taking the one nearest the viewer (front layer of a folded cloth).
            let score = distance + t * 0.02
            if score < bestScore {
                bestScore = score
                best = CoolClothPick(
                    column: column,
                    row: row,
                    worldPosition: world,
                    distanceToRay: distance,
                    rayDistance: t
                )
            }
        }
    }
    return best
}

/// Latest known world position of one particle (from the picking snapshot).
public func coolClothParticleWorldPosition(column: Int, row: Int) -> SIMD3<Float>? {
    let (positions, gridSize, model) = CoolClothPickingStore.shared.snapshot()
    guard gridSize > 0,
          (0 ..< gridSize).contains(column),
          (0 ..< gridSize).contains(row),
          positions.count == gridSize * gridSize
    else { return nil }
    let local = positions[row * gridSize + column]
    let world = model * SIMD4<Float>(local.x, local.y, local.z, 1)
    return SIMD3<Float>(world.x, world.y, world.z)
}

/// World-space bounds of the sheet from the last simulation readback, with
/// the number of non-finite particles: a diagnostic for a sheet that has
/// blown up. nil before the first frame.
public func coolClothWorldBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>, nonFinite: Int)? {
    let (positions, gridSize, model) = CoolClothPickingStore.shared.snapshot()
    guard gridSize > 0, !positions.isEmpty else { return nil }
    var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    var nonFinite = 0
    for p in positions {
        let world = model * SIMD4<Float>(p.x, p.y, p.z, 1)
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite else {
            nonFinite += 1
            continue
        }
        lower = simd_min(lower, SIMD3<Float>(world.x, world.y, world.z))
        upper = simd_max(upper, SIMD3<Float>(world.x, world.y, world.z))
    }
    guard nonFinite < positions.count else { return (.zero, .zero, nonFinite) }
    return (lower, upper, nonFinite)
}

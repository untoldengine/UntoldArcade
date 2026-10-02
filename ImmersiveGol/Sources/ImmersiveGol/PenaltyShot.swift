import simd

enum PenaltyAim: String, CaseIterable, Sendable {
    case left = "Left"
    case center = "Center"
    case right = "Right"

    var lateralOffset: Float {
        switch self {
        case .left: return -0.22
        case .center: return 0
        case .right: return 0.22
        }
    }
}

struct PenaltySettings: Sendable {
    var distance: Float = 3
    var flightTime: Float = 1
    var aim: PenaltyAim = .center

    var clamped: Self {
        Self(distance: distance.isFinite ? min(max(distance, 2), 10) : 3,
             flightTime: flightTime.isFinite ? min(max(flightTime, 0.6), 1.5) : 1,
             aim: aim)
    }
}

/// A shot freezes the goalie's frame and target before launch. It never homes
/// toward the hands after being kicked; Jolt owns the trajectory and response.
struct PenaltyTrajectory: Sendable {
    let origin: SIMD3<Float>
    let target: SIMD3<Float>
    let velocity: SIMD3<Float>
    let forward: SIMD3<Float>
    let keeperPosition: SIMD3<Float>
    let flightTime: Float

    init(settings: PenaltySettings, head: simd_float4x4, gravity: SIMD3<Float>) {
        let settings = settings.clamped
        let position = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let horizontal = SIMD3<Float>(-head.columns.2.x, 0, -head.columns.2.z)
        forward = simd_length_squared(horizontal) > 0.001
            ? simd_normalize(horizontal) : SIMD3<Float>(0, 0, -1)
        let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        keeperPosition = SIMD3<Float>(position.x, 0, position.z)
        // Chest-height target slightly ahead of the body and within arm's reach.
        target = keeperPosition + forward * 0.55 + right * settings.aim.lateralOffset
            + SIMD3<Float>(0, max(0.6, position.y - 0.35), 0)
        origin = keeperPosition + forward * settings.distance + SIMD3<Float>(0, 0.11, 0)
        // Untold Engine steps at 60 Hz. Jolt 5.6 defaults rigid-body linear
        // damping to 0.05 and applies gravity/damping before integrating position.
        // Solve those discrete updates so the marker matches the actual flight,
        // including at the longest flight-time setting.
        let dt: Float = 1 / 60
        let steps = Int((settings.flightTime / dt).rounded())
        flightTime = Float(steps) * dt
        let damping: Float = 1 - 0.05 * dt
        var velocityFactor: Float = 1
        var displacementFactor: Float = 0
        var gravityVelocity: Float = 0
        var gravityDisplacement: Float = 0
        for _ in 0..<steps {
            velocityFactor *= damping
            gravityVelocity = (gravityVelocity + dt) * damping
            displacementFactor += velocityFactor * dt
            gravityDisplacement += gravityVelocity * dt
        }
        velocity = (target - origin - gravity * gravityDisplacement) / displacementFactor
    }
}

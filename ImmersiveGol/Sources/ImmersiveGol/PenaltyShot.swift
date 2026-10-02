import simd

/// Reachable offsets relative to the goalie's chest-height target.
struct PenaltyAim: Sendable {
    var lateralOffset: Float = 0
    var heightOffset: Float = 0

    static func random() -> Self {
        Self(lateralOffset: Float.random(in: -0.35...0.35),
             heightOffset: Float.random(in: -0.2...0.2))
    }
}

struct PenaltySettings: Sendable {
    var distance: Float = 3
    var flightTime: Float = 0.35

    var clamped: Self {
        Self(distance: distance.isFinite ? min(max(distance, 2), 10) : 3,
             flightTime: flightTime.isFinite ? min(max(flightTime, 0.2), 0.5) : 0.35)
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

    init(settings: PenaltySettings, head: simd_float4x4, gravity: SIMD3<Float>,
         aim: PenaltyAim = .random()) {
        let settings = settings.clamped
        let position = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let horizontal = SIMD3<Float>(-head.columns.2.x, 0, -head.columns.2.z)
        forward = simd_length_squared(horizontal) > 0.001
            ? simd_normalize(horizontal) : SIMD3<Float>(0, 0, -1)
        let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        keeperPosition = SIMD3<Float>(position.x, 0, position.z)
        // Chest-height target slightly ahead of the body and within arm's reach.
        target = keeperPosition + forward * 0.55 + right * aim.lateralOffset
            + SIMD3<Float>(0, max(0.6, position.y - 0.35 + aim.heightOffset), 0)
        origin = keeperPosition + forward * settings.distance + SIMD3<Float>(0, 0.11, 0)
        // Keep the flight on its rising path to the target, rather than a lob
        // above it. Long requested times are shortened at close range.
        let rise = target.y - origin.y
        let upwardFlightLimit = sqrt(2 * rise / max(-gravity.y, 0.001))
        let dt: Float = 1 / 60
        var steps = max(1, Int(floor(min(settings.flightTime, upwardFlightLimit) / dt + 0.0001)))
        var launch = Self.launchVelocity(origin: origin, target: target, gravity: gravity, steps: steps)
        // At short distances the previous shot was mostly vertical. Prefer
        // horizontal motion; the target's height remains reachable with gravity.
        while steps > 6 && launch.y > simd_length(SIMD2<Float>(launch.x, launch.z)) {
            steps -= 1
            launch = Self.launchVelocity(origin: origin, target: target, gravity: gravity, steps: steps)
        }
        flightTime = Float(steps) * dt
        velocity = launch
    }

    private static func launchVelocity(
        origin: SIMD3<Float>, target: SIMD3<Float>, gravity: SIMD3<Float>, steps: Int
    ) -> SIMD3<Float> {
        // Match the engine's 60 Hz step and Jolt 5.6's default damping (0.05).
        let dt: Float = 1 / 60
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
        return (target - origin - gravity * gravityDisplacement) / displacementFactor
    }
}

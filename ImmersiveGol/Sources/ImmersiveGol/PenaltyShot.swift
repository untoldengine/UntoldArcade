import Foundation
import simd

/// Random target across a reachable width and low-to-overhead height range.
struct PenaltyAim: Sendable {
    var lateralOffset: Float = 0
    var heightFraction: Float = 0.5

    static func random() -> Self {
        Self(lateralOffset: Float.random(in: -0.65...0.65),
             heightFraction: Float.random(in: 0...1))
    }
}

struct PenaltySettings: Sendable {
    var distance: Float = 11
    var flightTime: Float = 1.0

    var clamped: Self {
        Self(distance: distance.isFinite ? min(max(distance, 11), 14) : 11,
             flightTime: flightTime.isFinite ? min(max(flightTime, 0.3), 1.5) : 1.0)
    }
}

/// A shot freezes the goalie's frame and target before launch. It never homes
/// toward the hands after being kicked; Jolt owns the trajectory and response.
struct PenaltyTrajectory: Sendable {
    let origin: SIMD3<Float>
    private(set) var target: SIMD3<Float>
    private(set) var velocity: SIMD3<Float>
    let forward: SIMD3<Float>
    let keeperPosition: SIMD3<Float>
    let flightTime: Float

    init(settings: PenaltySettings, head: simd_float4x4, gravity: SIMD3<Float>,
         aim: PenaltyAim = .random(), floorY: Float = 0, shotOrigin: SIMD3<Float>? = nil) {
        let settings = settings.clamped
        let position = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let horizontal = SIMD3<Float>(-head.columns.2.x, 0, -head.columns.2.z)
        forward = simd_length_squared(horizontal) > 0.001
            ? simd_normalize(horizontal) : SIMD3<Float>(0, 0, -1)
        let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        keeperPosition = SIMD3<Float>(position.x, floorY, position.z)
        // Sample the full height range instead of a narrow band below the head.
        let lowHeight: Float = 0.45
        let highHeight = max(1.2, position.y - floorY + 0.25)
        let targetHeight = lowHeight + (highHeight - lowHeight) * min(max(aim.heightFraction, 0), 1)
        target = keeperPosition + forward * 0.55 + right * aim.lateralOffset
            + SIMD3<Float>(0, targetHeight, 0)
        origin = shotOrigin ?? (keeperPosition + forward * settings.distance + SIMD3<Float>(0, 0.11, 0))
        // A gentler demo shot allows an arc instead of forcing a fast rising flight.
        let dt: Float = 1 / 60
        let steps = max(1, Int(floor(settings.flightTime / dt + 0.0001)))
        flightTime = Float(steps) * dt
        velocity = Self.launchVelocity(origin: origin, target: target, gravity: gravity, steps: steps)
    }

    /// Re-aim once at foot contact, preserving the ball spot and captured goalie frame.
    func aimed(at target: SIMD3<Float>, gravity: SIMD3<Float>) -> Self {
        var shot = self
        shot.target = target
        let steps = max(1, Int(round(flightTime * 60)))
        shot.velocity = Self.launchVelocity(origin: origin, target: target, gravity: gravity, steps: steps)
        return shot
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

/// Predicts a raw sampled toe after root-motion extraction. Root motion removes
/// both initial horizontal root translation and initial heading, not just position.
enum PenaltyContactAlignment {
    static func predictedToe(sampledToe: SIMD3<Float>, rootStart: SIMD3<Float>,
                             anchor: SIMD3<Float>, actorRotation: simd_quatf,
                             initialRootYaw: Float) -> SIMD3<Float> {
        let rootOffset = SIMD3<Float>(rootStart.x - anchor.x, 0, rootStart.z - anchor.z)
        let inverseHeading = simd_quatf(angle: -initialRootYaw, axis: SIMD3<Float>(0, 1, 0))
        let worldHeading = actorRotation * inverseHeading * actorRotation.inverse
        return anchor + worldHeading.act(sampledToe - anchor - rootOffset)
    }
}

/// Locomotion is chosen from the actor's current facing, never the next shot's aim.
struct ShooterTravelPlan {
    let movingForward: Bool
    let rotation: simd_quatf
    let distance: Float
    let turnDuration: TimeInterval

    init(displacement: SIMD3<Float>, facing: simd_quatf) {
        let horizontal = SIMD3<Float>(displacement.x, 0, displacement.z)
        distance = simd_length(horizontal)
        let direction = distance > 0.0001 ? horizontal / distance : facing.act(SIMD3<Float>(0, 0, 1))
        let forward = facing.act(SIMD3<Float>(0, 0, 1))
        // Backpedal only toward a mark clearly behind the player (within 45°
        // of straight backward). For lateral travel, turn and jog forward.
        movingForward = simd_dot(direction, forward) > -sqrt(Float(0.5))
        let heading = movingForward ? direction : -direction
        rotation = simd_quatf(angle: atan2(heading.x, heading.z), axis: SIMD3<Float>(0, 1, 0))
        turnDuration = Self.turnDuration(from: facing, to: rotation)
    }

    static func turnDuration(from start: simd_quatf, to end: simd_quatf) -> TimeInterval {
        let angle = 2 * acos(min(abs(simd_dot(start.vector, end.vector)), 1))
        return angle < 0.02 ? 0 : Double(angle / .pi)
    }
}

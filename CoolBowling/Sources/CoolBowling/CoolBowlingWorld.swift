//
//  CoolBowlingWorld.swift
//  CoolBowling
//
//  The real room as physics: ARKit planes become Jolt environment slabs, and
//  the game's side channel to the backend (ball/pin state, teleports).
//

import Foundation
import simd
import UntoldEngine
import UntoldJoltPhysics

/// A bounded real-world surface from ARKit plane detection. `center` and
/// `normal` in world space; `extents` are half-sizes along the tangents.
public struct CoolBowlingWorldPlane: Sendable {
    public let id: UUID
    public var center: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var tangentU: SIMD3<Float>
    public var tangentV: SIMD3<Float>
    public var extentU: Float
    public var extentV: Float
    /// ARKit classified this surface as the floor.
    public var isFloor: Bool

    public init(
        id: UUID,
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        tangentU: SIMD3<Float>,
        tangentV: SIMD3<Float>,
        extentU: Float,
        extentV: Float,
        isFloor: Bool = false
    ) {
        self.id = id
        self.center = center
        self.normal = normal
        self.tangentU = tangentU
        self.tangentV = tangentV
        self.extentU = extentU
        self.extentV = extentV
        self.isFloor = isFloor
    }

    /// An unbounded horizontal floor — the simulator fallback and the safety
    /// net under holes in the real scan.
    public static func infiniteFloor(y: Float = 0.0) -> CoolBowlingWorldPlane {
        CoolBowlingWorldPlane(
            id: UUID(),
            center: SIMD3<Float>(0.0, y, 0.0),
            normal: SIMD3<Float>(0.0, 1.0, 0.0),
            tangentU: SIMD3<Float>(1.0, 0.0, 0.0),
            tangentV: SIMD3<Float>(0.0, 0.0, 1.0),
            extentU: .greatestFiniteMagnitude,
            extentV: .greatestFiniteMagnitude
        )
    }
}

/// An oriented box in world space. Real surfaces that intersect it are
/// kept out of the simulation: the alley is the game's, not the room's.
public struct CoolBowlingKeepOutBox: Sendable {
    public var center: SIMD3<Float>
    public var right: SIMD3<Float>
    public var up: SIMD3<Float>
    public var forward: SIMD3<Float>
    public var halfExtents: SIMD3<Float>
    /// The floor the alley was placed on: horizontal surfaces within a
    /// step of it are the floor, and stay even if a later estimate puts
    /// them a few centimetres higher.
    public var floorY: Float

    public init(center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>, halfExtents: SIMD3<Float>, floorY: Float) {
        self.center = center
        self.right = right
        self.up = up
        self.forward = forward
        self.halfExtents = halfExtents
        self.floorY = floorY
    }

    /// Horizontal and no higher than a step above the placement floor.
    public func isFloor(_ plane: CoolBowlingWorldPlane) -> Bool {
        plane.normal.y > 0.85 && plane.center.y < floorY + 0.15
    }

    /// Whether the plane's slab must stay out of the simulation.
    public func excludes(_ plane: CoolBowlingWorldPlane, slab: JoltEnvironmentBox) -> Bool {
        !isFloor(plane) && intersects(slab: slab)
    }

    /// Separating-axis test against another oriented box.
    public func intersects(center other: SIMD3<Float>, axes otherAxes: [SIMD3<Float>], halfExtents otherHalf: SIMD3<Float>) -> Bool {
        let axes = [right, up, forward]
        let half = [halfExtents.x, halfExtents.y, halfExtents.z]
        let otherHalves = [otherHalf.x, otherHalf.y, otherHalf.z]
        let offset = other - center
        var candidates = axes + otherAxes
        for a in axes {
            for b in otherAxes {
                let cross = simd_cross(a, b)
                if simd_length_squared(cross) > 1e-6 {
                    candidates.append(simd_normalize(cross))
                }
            }
        }
        for axis in candidates {
            var reach: Float = 0
            for index in 0 ..< 3 {
                reach += half[index] * abs(simd_dot(axes[index], axis))
                reach += otherHalves[index] * abs(simd_dot(otherAxes[index], axis))
            }
            if abs(simd_dot(offset, axis)) > reach {
                return false
            }
        }
        return true
    }

    public func intersects(slab: JoltEnvironmentBox) -> Bool {
        intersects(
            center: slab.center,
            axes: [
                slab.orientation.act(SIMD3<Float>(1, 0, 0)),
                slab.orientation.act(SIMD3<Float>(0, 1, 0)),
                slab.orientation.act(SIMD3<Float>(0, 0, 1)),
            ],
            halfExtents: slab.halfExtents
        )
    }
}

/// Jolt behind the game's side channel: detected planes become environment
/// slabs (thin static boxes whose top face lies on the plane), except where
/// the alley stands.
public final class CoolBowlingSimulation: @unchecked Sendable {
    public let backend: JoltPhysicsBackend
    private let planeCount = CoolBowlingLockedBox<Int>(0)
    private let droppedCount = CoolBowlingLockedBox<Int>(0)
    private let keepOut = CoolBowlingLockedBox<CoolBowlingKeepOutBox?>(nil)

    /// Half thickness of the slab standing in for a (zero-thickness) plane.
    static let slabHalfThickness: Float = 0.02
    /// Cap for the "infinite" safety floor: Jolt wants finite boxes.
    static let maxHalfExtent: Float = 100

    public init(backend: JoltPhysicsBackend) {
        self.backend = backend
    }

    /// Real surfaces inside `box` are left out of the world from the next
    /// `setWorldPlanes` on; nil lets the whole room back in.
    public func setAlleyKeepOut(_ box: CoolBowlingKeepOutBox?) {
        keepOut.value = box
    }

    public func setWorldPlanes(_ planes: [CoolBowlingWorldPlane]) {
        let boxes = Self.environmentBoxes(for: planes, keepOut: keepOut.value)
        let dropped = planes.count - boxes.count
        if dropped != droppedCount.value {
            coolBowlingLog.log("alley keep-out: \(dropped) real surface(s) left out of the simulation")
        }
        planeCount.value = boxes.count
        droppedCount.value = dropped
        backend.setEnvironmentBoxes(boxes)
    }

    /// Slabs for `planes`, minus those cutting into the alley's keep-out.
    static func environmentBoxes(for planes: [CoolBowlingWorldPlane], keepOut: CoolBowlingKeepOutBox?) -> [JoltEnvironmentBox] {
        planesInSimulation(planes, keepOut: keepOut).map(environmentBox(for:))
    }

    /// The planes that make it into the world: all of them without a
    /// keep-out; otherwise the floor and whatever stays clear of the alley.
    static func planesInSimulation(_ planes: [CoolBowlingWorldPlane], keepOut: CoolBowlingKeepOutBox?) -> [CoolBowlingWorldPlane] {
        guard let keepOut else { return planes }
        return planes.filter { plane in
            !keepOut.excludes(plane, slab: environmentBox(for: plane))
        }
    }

    /// Real surfaces currently in the simulation.
    public var worldPlaneCount: Int {
        planeCount.value
    }

    /// Real surfaces left out because they cut into the alley.
    public var droppedPlaneCount: Int {
        droppedCount.value
    }

    public func bodyState(for entity: EntityID) -> (position: SIMD3<Float>, velocity: SIMD3<Float>)? {
        backend.bodyState(for: entity)
    }

    @discardableResult
    public func resetBody(entity: EntityID, position: SIMD3<Float>, velocity: SIMD3<Float>) -> Bool {
        backend.resetBody(entity: entity, position: position, velocity: velocity)
    }

    public func isBodyActive(entity: EntityID) -> Bool {
        backend.isBodyActive(entity: entity)
    }

    /// A plane as a slab: local X along `tangentU`, local Y along `tangentV`,
    /// local Z along the normal; centred half a thickness below the surface
    /// so the top face is exactly the plane.
    static func environmentBox(for plane: CoolBowlingWorldPlane) -> JoltEnvironmentBox {
        let normal = simd_normalize(plane.normal)
        let u = simd_normalize(plane.tangentU)
        var v = simd_normalize(plane.tangentV)
        // A quaternion needs a right-handed basis; the slab is symmetric, so
        // flipping V costs nothing.
        if simd_dot(simd_cross(u, v), normal) < 0 {
            v = -v
        }
        let basis = simd_float3x3(columns: (u, v, normal))
        return JoltEnvironmentBox(
            center: plane.center - normal * slabHalfThickness,
            orientation: simd_normalize(simd_quatf(basis)),
            halfExtents: SIMD3<Float>(
                min(plane.extentU, maxHalfExtent),
                min(plane.extentV, maxHalfExtent),
                slabHalfThickness
            ),
            friction: 0.5,
            restitution: 0.0
        )
    }
}

/// Minimal lock-guarded box for cross-thread handoff.
final class CoolBowlingLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

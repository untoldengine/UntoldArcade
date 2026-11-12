//
//  ZombiePhysicsTests.swift
//  CoolZombieKitTests
//
//  The physics adapter against a real Jolt world (no engine entities, no
//  registry): the room's boxes and their layers, the character controller
//  sliding the frame's motion against them, and the ragdoll re-seated when
//  the entity jumps.
//

@testable import CoolZombieKit
import simd
import UntoldEngine
import UntoldJoltPhysics
import XCTest

final class ZombiePhysicsTests: XCTestCase {
    private let step: Float = 1.0 / 60.0

    private func makePhysics() -> ZombiePhysics {
        var settings = JoltWorldSettings()
        settings.workerThreads = 0
        let backend = JoltPhysicsBackend(settings: settings)
        backend.configure(PhysicsWorldConfiguration())
        let physics = ZombiePhysics(backend: backend, configuration: ZombiePhysics.Configuration())
        physics.applyLayers()
        return physics
    }

    /// The sandbox's wall layout: a 3.2 × 1.5 × 0.2 m wall across the origin.
    private let wall = NavObstacle(center: simd_float3(0, 0.75, 0), size: simd_float3(3.2, 1.5, 0.2))

    /// Walks the controller `frames` frames of `delta` per frame the way the
    /// game does: the entity moved, the controller resolves it, the world steps.
    private func walk(_ physics: ZombiePhysics, from start: simd_float3, delta: simd_float3, frames: Int) -> simd_float3 {
        var position = start
        for _ in 0 ..< frames {
            position = physics.resolve(target: position + delta, deltaTime: step)
            physics.backend.step(deltaTime: step)
        }
        return position
    }

    /// Steps the world `seconds` of frames.
    private func settle(_ physics: ZombiePhysics, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
            physics.backend.step(deltaTime: step)
            elapsed += step
        }
    }

    /// A dynamic sphere on the ragdoll's layer at `position`, the way the
    /// plugin's tests build a body: a part without the rest of the body.
    private func addPart(_ physics: ZombiePhysics, entity: EntityID, at position: simd_float3) {
        physics.backend.didAddBody(entity: entity, descriptor: PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(shape: .sphere(radius: 0.11), friction: 0.5, restitution: 0.0),
            mass: 1,
            layer: physics.configuration.ragdollLayer,
            position: position
        ))
    }

    func testObstaclesBecomeOrientedBoxesPlusAFloor() {
        let turned = NavObstacle(center: simd_float3(2, 0.5, -1), size: simd_float3(1.2, 1.0, 0.4), yaw: 0.7)
        let box = ZombiePhysics.environmentBox(turned, layer: 4)
        XCTAssertEqual(box.center, turned.center)
        XCTAssertEqual(box.halfExtents, turned.size / 2)
        XCTAssertEqual(box.layer, 4)
        // The box's local X axis is the obstacle's along-axis in the world.
        let localX = box.orientation.act(simd_float3(1, 0, 0))
        let along = turned.toWorldDirection(simd_float2(1, 0))
        XCTAssertEqual(localX.x, along.x, accuracy: 1e-5)
        XCTAssertEqual(localX.z, along.y, accuracy: 1e-5)

        let physics = makePhysics()
        physics.setObstacles([wall, turned], floor: 0)
        physics.backend.step(deltaTime: step)
        XCTAssertEqual(physics.backend.environmentBodyCount, 3, "two boxes and the floor slab")
    }

    func testThePoweredRagdollIgnoresTheRoomUntilItIsDown() {
        let configuration = ZombiePhysics.Configuration()
        let character = configuration.characterLayer, ragdoll = configuration.ragdollLayer
        let ball = configuration.ballLayer, room = configuration.roomLayer
        // The bridge opens a pair when either side's mask says so.
        func meet(_ a: UInt32, _ b: UInt32, in masks: [UInt32]) -> Bool {
            (masks[Int(a)] >> b) & 1 != 0 || (masks[Int(b)] >> a) & 1 != 0
        }
        let standing = ZombiePhysics.layerMatrix(
            characterLayer: character, ragdollLayer: ragdoll, ballLayer: ball, roomLayer: room, ragdollMeetsRoom: false
        )
        XCTAssertEqual(standing.count, 32)
        XCTAssertFalse(meet(ragdoll, room, in: standing), "a desk within reach cannot bend a tracked arm")
        XCTAssertTrue(meet(character, room, in: standing), "the controller still slides along the walls")
        XCTAssertTrue(meet(ball, room, in: standing), "balls still bounce off the furniture")
        XCTAssertTrue(meet(ragdoll, 0, in: standing), "the feet keep the floor slab")
        XCTAssertTrue(meet(ragdoll, ball, in: standing))
        XCTAssertFalse(meet(character, ragdoll, in: standing))
        XCTAssertFalse(meet(character, ball, in: standing))

        let down = ZombiePhysics.layerMatrix(
            characterLayer: character, ragdollLayer: ragdoll, ballLayer: ball, roomLayer: room, ragdollMeetsRoom: true
        )
        XCTAssertTrue(meet(ragdoll, room, in: down), "the fallen body lands on the furniture")
        XCTAssertTrue(meet(ragdoll, 0, in: down))
        XCTAssertFalse(meet(character, ragdoll, in: down))
        XCTAssertFalse(meet(character, ball, in: down))
    }

    func testTheRoomIsOnItsLayerAndTheFloorOnTheFirst() {
        let physics = makePhysics()
        physics.setObstacles([wall], floor: 0)
        physics.backend.step(deltaTime: step)

        // Standing: a part dropped over the wall (top at y = 1.5) falls
        // through it and comes to rest on the floor slab.
        addPart(physics, entity: 1, at: simd_float3(0, 2.0, 0))
        settle(physics, seconds: 2.0)
        XCTAssertFalse(physics.isDown)
        XCTAssertEqual(physics.backend.bodyState(for: 1)!.position.y, 0.11, accuracy: 0.03, "through the wall, onto the floor slab")
        physics.backend.didRemoveBody(entity: 1)

        // Down: a fresh part rests on the wall's top.
        physics.setDown(true)
        XCTAssertTrue(physics.isDown)
        addPart(physics, entity: 2, at: simd_float3(0, 2.0, 0))
        settle(physics, seconds: 2.0)
        XCTAssertEqual(physics.backend.bodyState(for: 2)!.position.y, 1.61, accuracy: 0.03, "the fallen body lands on the furniture")
        XCTAssertFalse(physics.backend.isBodyActive(entity: 2), "and sleeps there")

        // Up again: the matrix follows, and the wall is transparent once
        // more even to the part asleep on it (Jolt pairs active bodies only;
        // the plugin wakes the world on a matrix change).
        physics.setDown(false)
        settle(physics, seconds: 2.0)
        XCTAssertEqual(physics.backend.bodyState(for: 2)!.position.y, 0.11, accuracy: 0.03, "standing again: through the wall")
    }

    func testRemovingTheRagdollStandsTheMatrixUp() {
        // The game drops the ragdoll when the space closes, fallen or not;
        // the next one is powered from its first frame and must not meet
        // the room.
        let physics = makePhysics()
        physics.setObstacles([wall], floor: 0)
        physics.backend.step(deltaTime: step)
        physics.setDown(true)
        physics.removeRagdoll()
        XCTAssertFalse(physics.isDown)
        addPart(physics, entity: 1, at: simd_float3(0, 2.0, 0))
        settle(physics, seconds: 2.0)
        XCTAssertEqual(physics.backend.bodyState(for: 1)!.position.y, 0.11, accuracy: 0.03, "the matrix stood up with the instance")
    }

    func testAJumpOfThePelvisReseatsTheParts() {
        let physics = makePhysics()
        physics.setObstacles([], floor: 0)
        physics.backend.step(deltaTime: step)
        let joints = mannequin()
        XCTAssertNotNil(physics.attachRagdoll(entity: 1, joints: joints))
        func entity(atX x: Float) -> simd_float4x4 {
            var world = matrix_identity_float4x4
            world.columns.3 = simd_float4(x, 0, 0, 1)
            return world
        }
        func errors(atX x: Float) -> [Float] {
            physics.trackingErrors(jointModelTransforms: joints.bindModelTransforms, entityWorld: entity(atX: x)).map(\.distance)
        }
        // The first track places the parts on the body; the motors hold
        // them there.
        physics.track(jointModelTransforms: joints.bindModelTransforms, entityWorld: entity(atX: 0))
        XCTAssertTrue(physics.isPlaced)
        settle(physics, seconds: 0.5)
        XCTAssertEqual(errors(atX: 0).count, 20)
        XCTAssertLessThan(errors(atX: 0).max()!, 0.05, "tracking the bind pose")

        // A step under the threshold is motion: nothing is touched, the
        // pelvis moves on and the motors drag the rest after it.
        physics.track(jointModelTransforms: joints.bindModelTransforms, entityWorld: entity(atX: 0.1))
        XCTAssertGreaterThan(errors(atX: 0.1).min()!, 0.08, "a 10 cm step: no part was re-seated")
        settle(physics, seconds: 0.5)

        // Half a metre at once is a jump: every part is on the new pose
        // before the world steps, and arrives still.
        physics.track(jointModelTransforms: joints.bindModelTransforms, entityWorld: entity(atX: 0.6))
        XCTAssertLessThan(errors(atX: 0.6).max()!, 0.005, "re-seated on the new pose")
        physics.backend.step(deltaTime: step)
        XCTAssertLessThan(errors(atX: 0.6).max()!, 0.03, "with no velocity to carry it on")
    }

    func testTheControllerStopsAtTheWallStandOff() {
        let physics = makePhysics()
        physics.setObstacles([wall], floor: 0)
        physics.backend.step(deltaTime: step)
        physics.attachCharacter(entity: 7, at: simd_float3(0.5, 0, -1.5))
        XCTAssertTrue(physics.hasCharacter)

        // Straight at the wall's near face (z = -0.1) at 3 m/s.
        let end = walk(physics, from: simd_float3(0.5, 0, -1.5), delta: simd_float3(0, 0, 0.05), frames: 60)
        // Radius 0.2 plus Jolt's 2 cm padding: the stand-off the wall hold wants.
        XCTAssertEqual(end.z, -0.1 - 0.22, accuracy: 0.02)
        XCTAssertEqual(end.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(end.y, 0, accuracy: 0.001)
        let touching = physics.contacts().filter { $0.entity == JoltPhysicsBackend.environmentEntity && $0.normal.z < -0.9 }
        XCTAssertFalse(touching.isEmpty)

        // Along the wall it slides freely.
        let slid = walk(physics, from: end, delta: simd_float3(0.03, 0, 0.03), frames: 30)
        XCTAssertEqual(slid.x, end.x + 0.9, accuracy: 0.05)
        XCTAssertEqual(slid.z, end.z, accuracy: 0.02)
    }

    func testASlowFrameStillStopsAtTheWall() {
        let physics = makePhysics()
        physics.setObstacles([wall], floor: 0)
        physics.backend.step(deltaTime: step)
        physics.attachCharacter(entity: 7, at: simd_float3(0, 0, -1.0))

        // One stalled frame: root motion moved the entity 1.4 m, well past
        // the wall. The motion is swept, never skipped over it.
        let corrected = physics.resolve(target: simd_float3(0, 0, 0.4), deltaTime: 0.25)
        XCTAssertEqual(corrected.z, -0.32, accuracy: 0.03)
        XCTAssertEqual(corrected.x, 0, accuracy: 0.01)
    }

    func testAJumpGoesThroughTeleport() {
        let physics = makePhysics()
        physics.setObstacles([wall], floor: 0)
        physics.backend.step(deltaTime: step)
        physics.attachCharacter(entity: 7, at: simd_float3(0, 0, -2))

        // Reset puts the entity on the far side of the wall: the game says
        // so explicitly, and the controller follows without sliding.
        physics.teleport(to: simd_float3(0, 0, 2))
        XCTAssertEqual(physics.resolve(target: simd_float3(0, 0, 2), deltaTime: step), simd_float3(0, 0, 2))
        XCTAssertEqual(physics.resolve(target: simd_float3(0, 0, 2.03), deltaTime: step).z, 2.03, accuracy: 0.005)
    }

    func testTheFloorMovesWithTheHost() {
        let physics = makePhysics()
        physics.setObstacles([], floor: 0)
        physics.backend.step(deltaTime: step)
        physics.attachCharacter(entity: 7, at: simd_float3(0, 0, 0))

        // The host measured the floor 3 cm lower: the entity was re-set, the
        // controller follows in place and keeps sliding horizontally.
        physics.setObstacles([], floor: -0.03)
        let corrected = physics.resolve(target: simd_float3(0.02, -0.03, 0), deltaTime: step)
        XCTAssertEqual(corrected.y, -0.03, accuracy: 1e-5)
        XCTAssertEqual(corrected.x, 0.02, accuracy: 0.005)
        physics.backend.step(deltaTime: step)
        XCTAssertEqual(physics.backend.environmentBodyCount, 1)

        physics.removeCharacter()
        XCTAssertFalse(physics.hasCharacter)
        XCTAssertEqual(physics.resolve(target: simd_float3(5, 0, 5), deltaTime: step), simd_float3(5, 0, 5), "no controller: the target stands")
    }
}

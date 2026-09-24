//
//  CoolBowlingTests.swift
//  CoolBowlingTests
//

@testable import CoolBowling
import simd
import UntoldEngine
import UntoldJoltPhysics
import XCTest

private final class RecordingSink: PhysicsEventSink {
    var contacts: [PhysicsContactEvent] = []
    func receiveContact(_ event: PhysicsContactEvent) { contacts.append(event) }
    func receiveTrigger(_: PhysicsTriggerEvent) {}
    func receiveActivation(_: PhysicsBodyActivationEvent) {}
    func reportDroppedEvents(count _: Int) {}
}

final class CoolBowlingTests: XCTestCase {
    private let step: Float = 1.0 / 60.0

    func testRackHasTenPinsInTheRegulationTriangle() {
        let layout = CoolBowlingScene.LaneLayout(foul: .zero, facing: SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(layout.pinPositions.count, 10)
        // Head pin straight down the lane at the deck distance.
        let head = layout.pinPositions[0]
        XCTAssertEqual(head.x, 0, accuracy: 1e-5)
        XCTAssertEqual(head.z, -CoolBowlingScene.pinDeckDistance, accuracy: 1e-5)
        // Pin 7 is at the player's left: negative X when facing -Z.
        XCTAssertLessThan(layout.pinPositions[6].x, 0)
        XCTAssertGreaterThan(layout.pinPositions[9].x, 0)
        // A pin's length plus margin between the back row and the pit wall.
        let backRowZ = layout.pinPositions[6].z
        XCTAssertGreaterThan(backRowZ + CoolBowlingScene.laneLength, CoolBowlingScene.pinHeight + 0.2)
        XCTAssertEqual(head.y, CoolBowlingScene.laneSurfaceHeight, accuracy: 1e-5, "Pins stand on the lane surface")
        // Neighbours 12 inches apart; the back row is 10 wide (7 … 10).
        XCTAssertEqual(simd_length(layout.pinPositions[1] - layout.pinPositions[2]), CoolBowlingScene.pinSpacing, accuracy: 1e-4)
        XCTAssertEqual(simd_length(layout.pinPositions[0] - layout.pinPositions[1]), CoolBowlingScene.pinSpacing, accuracy: 1e-4)
        XCTAssertEqual(simd_length(layout.pinPositions[6] - layout.pinPositions[9]), CoolBowlingScene.pinSpacing * 3, accuracy: 1e-4)
        // The plinth runs from the foul line to the pit; the surface is its top.
        XCTAssertEqual(layout.laneCenter.z, -CoolBowlingScene.pitStart * 0.5, accuracy: 1e-5)
        XCTAssertEqual(layout.laneCenter.y, CoolBowlingScene.laneSurfaceHeight * 0.5, accuracy: 1e-6)
        XCTAssertEqual(layout.surfaceY, CoolBowlingScene.laneSurfaceHeight, accuracy: 1e-6)
        // The back row keeps a margin before the pit edge.
        XCTAssertLessThan(-layout.pinPositions[6].z + CoolBowlingScene.pinMaxRadius, CoolBowlingScene.pitStart - 0.1)
        // Local +Z of the orientation points down the lane.
        XCTAssertEqual(simd_dot(layout.orientation.act(SIMD3<Float>(0, 0, 1)), layout.forward), 1.0, accuracy: 1e-4)
    }

    func testLaneLocalFrameRoundTrips() {
        let layout = CoolBowlingScene.LaneLayout(foul: SIMD3<Float>(1, -1, 2), facing: SIMD3<Float>(1, 0, 1))
        let local = SIMD3<Float>(0.3, 0.5, 2.0)
        let world = layout.worldPoint(local)
        XCTAssertEqual(simd_length(layout.localPoint(world) - local), 0, accuracy: 1e-5)
        // Local +x is the player's right: facing +x+z, that is −x+z
        // (facing −z it is +x, as the rack test checks).
        XCTAssertGreaterThan(simd_dot(layout.right, simd_normalize(SIMD3<Float>(-1, 0, 1))), 0.99)
        XCTAssertEqual(layout.localPoint(layout.foul), .zero)
    }

    func testPitDetection() {
        let layout = CoolBowlingScene.LaneLayout(foul: .zero, facing: SIMD3<Float>(0, 0, -1))
        // On the deck, on the surface: not in the pit.
        XCTAssertFalse(layout.isInPit(layout.pinPositions[0] + SIMD3<Float>(0, CoolBowlingScene.ballRadius, 0)))
        // Past the lane end and still at surface height (in the air over the pit): not yet.
        let overPit = layout.worldPoint(SIMD3<Float>(0, CoolBowlingScene.laneSurfaceHeight + CoolBowlingScene.ballRadius, CoolBowlingScene.pitStart + 0.3))
        XCTAssertFalse(layout.isInPit(overPit))
        // Resting on the pit floor: in the pit.
        let onPitFloor = layout.worldPoint(SIMD3<Float>(0.1, 0.02 + CoolBowlingScene.ballRadius, CoolBowlingScene.pitStart + 0.3))
        XCTAssertTrue(layout.isInPit(onPitFloor))
        // Resting on a pin lying in the pit, or on deadwood piled in the
        // backstop corner (a pose Jolt produced): still the pit.
        let onAPin = layout.worldPoint(SIMD3<Float>(0.1, 0.02 + 2 * CoolBowlingScene.pinMaxRadius + CoolBowlingScene.ballRadius, CoolBowlingScene.pitStart + 0.3))
        XCTAssertTrue(layout.isInPit(onAPin))
        XCTAssertTrue(layout.isInPit(layout.worldPoint(SIMD3<Float>(-0.27, 0.19, 4.39))))
        // Against the pit's front wall, on the floor: the pit.
        XCTAssertTrue(layout.isInPit(layout.worldPoint(SIMD3<Float>(0, 0.02 + CoolBowlingScene.ballRadius, CoolBowlingScene.pitStart + CoolBowlingScene.ballRadius))))
        // Pivoting on the deck's edge, still at rolling height: not yet.
        let r = CoolBowlingScene.ballRadius
        XCTAssertFalse(layout.isInPit(layout.worldPoint(SIMD3<Float>(0, CoolBowlingScene.laneSurfaceHeight + sqrtf(r * r - (r / 2) * (r / 2)), CoolBowlingScene.pitStart + r / 2))))
        // Beyond the backstop or outside the bumpers: not the pit.
        XCTAssertFalse(layout.isInPit(layout.worldPoint(SIMD3<Float>(0, 0.1, CoolBowlingScene.laneLength + 0.5))))
        XCTAssertFalse(layout.isInPit(layout.worldPoint(SIMD3<Float>(1.0, 0.1, CoolBowlingScene.pitStart + 0.3))))
    }

    func testBallInPlayRegions() {
        let layout = CoolBowlingScene.LaneLayout(foul: .zero, facing: SIMD3<Float>(0, 0, -1), approachLength: 1.2)
        // At the rack (within the tolerance, not past it), and half way down the return: in play.
        XCTAssertTrue(layout.isAtRack(layout.rackPoint + layout.forward * (CoolBowlingScene.ballRadius * 2)))
        XCTAssertFalse(layout.isAtRack(layout.rackPoint + layout.forward * (CoolBowlingScene.ballRadius * 3)))
        XCTAssertTrue(layout.isOnReturn(layout.rackPoint))
        XCTAssertTrue(layout.isOnReturn(layout.returnStart))
        let midZ: Float = 1.5
        XCTAssertTrue(layout.isOnReturn(layout.worldPoint(SIMD3<Float>(layout.returnCenterX, layout.returnFloorTop(atZ: midZ) + CoolBowlingScene.ballRadius, midZ))))
        XCTAssertFalse(layout.isAtRack(layout.returnStart))
        // On the lane: over the alley, not on the return, not lost.
        let onLane = layout.worldPoint(SIMD3<Float>(0.2, CoolBowlingScene.laneSurfaceHeight + CoolBowlingScene.ballRadius, 2.0))
        XCTAssertTrue(layout.isOverAlley(onLane))
        XCTAssertFalse(layout.isOnReturn(onLane))
        XCTAssertFalse(layout.isLost(onLane))
        // On the ramp and at its foot: still the alley.
        XCTAssertTrue(layout.isOverAlley(layout.worldPoint(SIMD3<Float>(0, CoolBowlingScene.ballRadius, -0.9))))
        // On the real floor beside the left bumper, or behind the backstop: lost.
        XCTAssertTrue(layout.isLost(layout.worldPoint(SIMD3<Float>(-1.0, CoolBowlingScene.ballRadius, 2.0))))
        XCTAssertTrue(layout.isLost(layout.worldPoint(SIMD3<Float>(0, CoolBowlingScene.ballRadius, CoolBowlingScene.laneLength + 0.5))))
        // Flying over the bumper, still high: not lost yet.
        XCTAssertFalse(layout.isLost(layout.worldPoint(SIMD3<Float>(-1.0, 1.2, 2.0))))
        // Under the return, on the floor (fell off the trough): lost.
        XCTAssertTrue(layout.isLost(layout.worldPoint(SIMD3<Float>(layout.returnCenterX, CoolBowlingScene.ballRadius, 1.0))))
    }

    func testBallReturnRunsDownhillToARackBesideThePlayer() {
        let layout = CoolBowlingScene.LaneLayout(foul: .zero, facing: SIMD3<Float>(0, 0, -1), approachLength: 1.2)
        // On the player's right, clear of the bumper, above the lane.
        XCTAssertGreaterThan(layout.returnCenterX - CoolBowlingScene.returnInnerWidth * 0.5, CoolBowlingScene.laneWidth * 0.5 + 0.08)
        XCTAssertGreaterThan(layout.returnFloorTop(atZ: 0), CoolBowlingScene.laneSurfaceHeight + 0.3)
        // The rack end (behind the foul line) is the low end.
        XCTAssertEqual(layout.returnNearZ, -1.2)
        XCTAssertLessThan(layout.returnFloorTop(atZ: layout.returnNearZ), layout.returnFloorTop(atZ: layout.returnFarZ))
        XCTAssertEqual(layout.returnFloorTop(atZ: layout.returnNearZ), CoolBowlingScene.returnRackHeight, accuracy: 1e-6)
        // The ball starts at the pit end, above the trough, and rolls toward the player.
        let start = layout.localPoint(layout.returnStart)
        XCTAssertEqual(start.x, layout.returnCenterX, accuracy: 1e-5)
        XCTAssertGreaterThan(start.z, CoolBowlingScene.pitStart)
        XCTAssertGreaterThan(start.y, layout.returnFloorTop(atZ: start.z) + CoolBowlingScene.ballRadius)
        XCTAssertLessThan(simd_dot(layout.returnVelocity, layout.forward), 0)
        // The rack point is behind the foul line, within the player's reach of the rack end.
        let rack = layout.localPoint(layout.rackPoint)
        XCTAssertLessThan(rack.z, 0)
        XCTAssertLessThan(rack.z - layout.returnNearZ, 0.2)
    }

    func testFrameCycleReturnsThenResolves() {
        var cycle = CoolBowlingFrameCycle(returnDelay: 0.7, settleDelay: 2.0)
        XCTAssertEqual(cycle.tick(now: 5), [], "Nothing due while the ball is in play")
        XCTAssertTrue(cycle.endBall(at: 10))
        XCTAssertFalse(cycle.endBall(at: 10.1), "A ball ends once")
        XCTAssertTrue(cycle.isBallEnded)
        XCTAssertEqual(cycle.tick(now: 10.5), [])
        XCTAssertEqual(cycle.tick(now: 10.8), [.returnBall])
        XCTAssertEqual(cycle.tick(now: 11.5), [], "The return happens once")
        XCTAssertEqual(cycle.tick(now: 12.1), [.resolve])
        XCTAssertFalse(cycle.isBallEnded)
        XCTAssertEqual(cycle.tick(now: 13), [])
        // Both at once when the game thread stalled past both deadlines.
        cycle.endBall(at: 20)
        XCTAssertEqual(cycle.tick(now: 23), [.returnBall, .resolve])
    }

    func testFrameCycleTwoBallsAFrame() {
        var cycle = CoolBowlingFrameCycle()
        XCTAssertTrue(cycle.isFirstBall)
        XCTAssertEqual(cycle.resolve(pinsDown: 7), .sweep, "Open first ball: deadwood cleared")
        XCTAssertEqual(cycle.frame, 1)
        XCTAssertEqual(cycle.ballInFrame, 2)
        XCTAssertFalse(cycle.isFirstBall)
        XCTAssertEqual(cycle.resolve(pinsDown: 9), .rerack, "The second ball ends the frame, spare or not")
        XCTAssertEqual(cycle.frame, 2)
        XCTAssertEqual(cycle.ballInFrame, 1)
        XCTAssertEqual(cycle.resolve(pinsDown: 10), .rerack, "Strike: fresh rack at once")
        XCTAssertEqual(cycle.frame, 3)
        XCTAssertEqual(cycle.ballInFrame, 1)
        XCTAssertEqual(cycle.resolve(pinsDown: 0), .sweep)
        XCTAssertEqual(cycle.resolve(pinsDown: 0), .rerack, "A miss on the second ball still ends the frame")
        XCTAssertEqual(cycle.frame, 4)
    }

    func testFrameCycleManualButtons() {
        var cycle = CoolBowlingFrameCycle(returnDelay: 0.7, settleDelay: 2.0)
        // New ball during the settle stands in for the return; the pins are still judged.
        cycle.endBall(at: 30)
        cycle.ballReturnedManually()
        XCTAssertEqual(cycle.tick(now: 30.8), [], "No second return on top of the manual one")
        XCTAssertEqual(cycle.tick(now: 32.1), [.resolve])
        // Reset pins drops the pending judgement and opens a new frame.
        cycle.endBall(at: 40)
        cycle.rerackedManually()
        XCTAssertEqual(cycle.tick(now: 42.5), [])
        XCTAssertEqual(cycle.frame, 2)
        XCTAssertEqual(cycle.ballInFrame, 1)
        // New ball with no cycle running changes nothing.
        cycle.ballReturnedManually()
        XCTAssertEqual(cycle.tick(now: 50), [])
        cycle.reset()
        XCTAssertEqual(cycle.frame, 1)
    }

    func testKeepOutDropsSurfacesInTheAlleyButKeepsTheFloorAndTheRoom() {
        let layout = CoolBowlingScene.LaneLayout(foul: SIMD3<Float>(0, 0, 0), facing: SIMD3<Float>(0, 0, -1))
        func plane(_ center: SIMD3<Float>, normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, eu: Float, ev: Float) -> CoolBowlingWorldPlane {
            CoolBowlingWorldPlane(id: UUID(), center: center, normal: normal, tangentU: u, tangentV: v, extentU: eu, extentV: ev)
        }
        let floor = CoolBowlingWorldPlane.infiniteFloor(y: 0)
        let chairSeat = plane(SIMD3<Float>(0.1, 0.45, -2.0), normal: SIMD3<Float>(0, 1, 0), u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 0, 1), eu: 0.25, ev: 0.25)
        let tableOverReturn = plane(layout.worldPoint(SIMD3<Float>(layout.returnCenterX, 0.75, 1.0)), normal: SIMD3<Float>(0, 1, 0), u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 0, 1), eu: 0.4, ev: 0.4)
        let wallAcross = plane(SIMD3<Float>(0, 1.3, -3.0), normal: SIMD3<Float>(0, 0, 1), u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 1, 0), eu: 3.0, ev: 1.3)
        let wallBeside = plane(SIMD3<Float>(-2.5, 1.3, -2.0), normal: SIMD3<Float>(1, 0, 0), u: SIMD3<Float>(0, 0, 1), v: SIMD3<Float>(0, 1, 0), eu: 4.0, ev: 1.3)
        let sofaBehind = plane(SIMD3<Float>(0, 0.45, 2.5), normal: SIMD3<Float>(0, 1, 0), u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 0, 1), eu: 0.9, ev: 0.4)
        let X = SIMD3<Float>(1, 0, 0), Y = SIMD3<Float>(0, 1, 0), Z = SIMD3<Float>(0, 0, 1)
        let c30 = cosf(30 * .pi / 180), s30 = sinf(30 * .pi / 180)
        // Centre well outside on the left, but a 1.6 m top reaching over the bumper.
        let longTableBeside = plane(SIMD3<Float>(-1.2, 0.75, -2.0), normal: Y, u: X, v: Z, eu: 0.8, ev: 0.4)
        // Sloped 30°, centre outside, its extent crossing the bumper line.
        let slopedIntoAlley = plane(SIMD3<Float>(-1.0, 0.9, -2.0), normal: SIMD3<Float>(-s30, c30, 0), u: SIMD3<Float>(c30, s30, 0), v: Z, eu: 0.5, ev: 0.5)
        // Floor patches a few centimetres above the placement floor: the floor, kept.
        let floorPatchLow = plane(SIMD3<Float>(0.2, 0.03, -2.0), normal: Y, u: X, v: Z, eu: 1.0, ev: 1.0)
        let floorPatchHigh = plane(SIMD3<Float>(0.2, 0.08, -2.0), normal: Y, u: X, v: Z, eu: 1.0, ev: 1.0)
        // A low shelf over the lane: not the floor, out.
        let lowShelf = plane(SIMD3<Float>(0, 0.25, -2.0), normal: Y, u: X, v: Z, eu: 0.3, ev: 0.3)
        // A wall just behind the backstop: clear of the alley, kept.
        let wallBehindPit = plane(SIMD3<Float>(0, 1.3, -4.9), normal: Z, u: X, v: Y, eu: 3.0, ev: 1.3)
        let planes = [floor, chairSeat, tableOverReturn, wallAcross, wallBeside, sofaBehind,
                      longTableBeside, slopedIntoAlley, floorPatchLow, floorPatchHigh, lowShelf, wallBehindPit]

        let unfiltered = CoolBowlingSimulation.environmentBoxes(for: planes, keepOut: nil)
        XCTAssertEqual(unfiltered.count, planes.count)
        let kept = Set(CoolBowlingSimulation.planesInSimulation(planes, keepOut: layout.keepOut).map(\.id))
        let expectedKept: Set<UUID> = [floor.id, wallBeside.id, sofaBehind.id, floorPatchLow.id, floorPatchHigh.id, wallBehindPit.id]
        XCTAssertEqual(kept, expectedKept, "The floor (and floor patches), the wall beside the lane, the sofa behind the player and the wall behind the pit stay")
        for dropped in [chairSeat, tableOverReturn, wallAcross, longTableBeside, slopedIntoAlley, lowShelf] {
            XCTAssertFalse(kept.contains(dropped.id))
        }
        XCTAssertEqual(CoolBowlingSimulation.environmentBoxes(for: planes, keepOut: layout.keepOut).count, expectedKept.count)
    }

    func testPinHullSpansThePin() {
        let hull = CoolBowlingScene.pinHullVertices
        XCTAssertGreaterThan(hull.count, 40)
        let minY = hull.map(\.y).min()!, maxY = hull.map(\.y).max()!
        XCTAssertEqual(minY, 0, accuracy: 1e-6)
        XCTAssertEqual(maxY, CoolBowlingScene.pinHeight, accuracy: 1e-6)
        let belly = hull.map { simd_length(SIMD2<Float>($0.x, $0.z)) }.max()!
        XCTAssertEqual(belly, CoolBowlingScene.pinMaxRadius, accuracy: 1e-6)
    }

    func testPinsDownPredicate() {
        XCTAssertFalse(CoolBowlingScene.isPinDown(up: SIMD3<Float>(0, 1, 0), displacement: 0))
        XCTAssertFalse(CoolBowlingScene.isPinDown(up: simd_normalize(SIMD3<Float>(0.3, 1, 0)), displacement: 0.1), "A wobble is not a fall")
        XCTAssertTrue(CoolBowlingScene.isPinDown(up: SIMD3<Float>(1, 0, 0), displacement: 0), "Lying flat")
        XCTAssertTrue(CoolBowlingScene.isPinDown(up: SIMD3<Float>(0, 1, 0), displacement: 0.5), "Standing, but off its spot")
    }

    func testFloorPlaneBecomesASlabUnderTheSurface() {
        let floor = CoolBowlingWorldPlane.infiniteFloor(y: 0.3)
        let box = CoolBowlingSimulation.environmentBox(for: floor)
        XCTAssertEqual(box.center.y, 0.3 - CoolBowlingSimulation.slabHalfThickness, accuracy: 1e-6)
        XCTAssertEqual(box.halfExtents.x, CoolBowlingSimulation.maxHalfExtent)
        XCTAssertEqual(simd_dot(box.orientation.act(SIMD3<Float>(0, 0, 1)), floor.normal), 1.0, accuracy: 1e-4)
    }

    /// The whole alley on Jolt, headless: a rolled ball must topple pins,
    /// and pins standing untouched must stay up.
    func testRolledBallKnocksPinsOverOnJolt() throws {
        var settings = JoltWorldSettings()
        settings.workerThreads = 0
        let backend = JoltPhysicsBackend(settings: settings)
        backend.configure(PhysicsWorldConfiguration())
        let layout = CoolBowlingScene.LaneLayout(foul: .zero, facing: SIMD3<Float>(0, 0, -1))

        // The lane plinth, the pit floor and the backstop.
        backend.didAddBody(entity: 100, descriptor: PhysicsBodyDescriptor(
            motionType: .static,
            collider: PhysicsColliderDescriptor(
                shape: .box(halfExtents: SIMD3<Float>(CoolBowlingScene.laneWidth * 0.5, CoolBowlingScene.laneSurfaceHeight * 0.5, CoolBowlingScene.pitStart * 0.5)),
                friction: CoolBowlingScene.laneFriction, restitution: 0.1
            ),
            position: layout.laneCenter, orientation: layout.orientation
        ))
        backend.didAddBody(entity: 101, descriptor: PhysicsBodyDescriptor(
            motionType: .static,
            collider: PhysicsColliderDescriptor(
                shape: .box(halfExtents: SIMD3<Float>(CoolBowlingScene.laneWidth * 0.5, 0.01, CoolBowlingScene.pitLength * 0.5)),
                friction: 0.6, restitution: 0.05
            ),
            position: layout.worldPoint(SIMD3<Float>(0, 0.01, CoolBowlingScene.pitStart + CoolBowlingScene.pitLength * 0.5)), orientation: layout.orientation
        ))
        backend.didAddBody(entity: 102, descriptor: PhysicsBodyDescriptor(
            motionType: .static,
            collider: PhysicsColliderDescriptor(shape: .box(halfExtents: SIMD3<Float>(0.7, 0.4, 0.03)), friction: 0.5, restitution: 0.2),
            position: layout.worldPoint(SIMD3<Float>(0, 0.4, CoolBowlingScene.laneLength + 0.03)), orientation: layout.orientation
        ))
        // Bumpers along the whole alley, and a floor under everything.
        for (entity, side) in [(103, Float(-1)), (104, Float(1))] {
            backend.didAddBody(entity: EntityID(entity), descriptor: PhysicsBodyDescriptor(
                motionType: .static,
                collider: PhysicsColliderDescriptor(shape: .box(halfExtents: SIMD3<Float>(0.04, 0.17, CoolBowlingScene.laneLength * 0.5)), friction: 0.3, restitution: 0.35),
                position: layout.worldPoint(SIMD3<Float>(side * (CoolBowlingScene.laneWidth * 0.5 + 0.04), 0.17, CoolBowlingScene.laneLength * 0.5)), orientation: layout.orientation
            ))
        }
        backend.setEnvironmentBoxes(CoolBowlingSimulation.environmentBoxes(for: [.infiniteFloor(y: 0)], keepOut: layout.keepOut))
        // Ten pins.
        for (index, position) in layout.pinPositions.enumerated() {
            backend.didAddBody(entity: EntityID(1 + index), descriptor: PhysicsBodyDescriptor(
                motionType: .dynamic,
                collider: PhysicsColliderDescriptor(shape: .convexHull(vertices: CoolBowlingScene.pinHullVertices), friction: 0.5, restitution: 0.3),
                mass: CoolBowlingScene.pinMass,
                position: position, orientation: layout.orientation
            ))
        }
        // Let the rack settle: nothing must fall on its own. Poses are
        // merged across steps because a body's final pose is read back once,
        // on the step it falls asleep.
        var poses: [EntityID: PhysicsBodyTransform] = [:]
        for _ in 0 ..< 120 {
            backend.step(deltaTime: step)
            mergeReadback(backend, into: &poses)
        }
        XCTAssertEqual(pinsDown(poses, layout: layout), 0, "A racked pin stands on its own")

        // The ball, rolled from the foul line straight at the head pin.
        let start = layout.foul + layout.forward * 0.3 + SIMD3<Float>(0, layout.surfaceY + CoolBowlingScene.ballRadius + 0.005, 0)
        backend.didAddBody(entity: 50, descriptor: PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(shape: .sphere(radius: CoolBowlingScene.ballRadius), friction: CoolBowlingScene.ballFriction, restitution: CoolBowlingScene.ballRestitution),
            mass: CoolBowlingScene.ballMass,
            position: start, linearVelocity: layout.forward * 7.0 + layout.right * 0.1
        ))
        let sink = RecordingSink()
        for _ in 0 ..< 240 {
            backend.step(deltaTime: step)
            backend.drainEvents(into: sink)
            mergeReadback(backend, into: &poses)
        }
        let down = pinsDown(poses, layout: layout)
        XCTAssertGreaterThanOrEqual(down, 4, "A 7 m/s ball into the head pin scatters the rack (got \(down))")
        // The ball rolled off the end of the lane into the pit.
        let ball = try XCTUnwrap(poses[50])
        XCTAssertTrue(layout.isInPit(ball.position), "Ball ended at local \(layout.localPoint(ball.position))")
        XCTAssertTrue(sink.contacts.contains { ($0.entityA == 50 && (1 ... 10).contains($0.entityB)) }, "The ball hit a pin")
        XCTAssertTrue(sink.contacts.contains { (1 ... 10).contains($0.entityA) && (1 ... 10).contains($0.entityB) }, "Pins hit each other")
    }

    /// Reads back whatever moved this step, like the coordinator does.
    private func mergeReadback(_ backend: JoltPhysicsBackend, into poses: inout [EntityID: PhysicsBodyTransform]) {
        var entities = [EntityID](repeating: 0, count: 32)
        var transforms = [PhysicsBodyTransform](repeating: PhysicsBodyTransform(position: .zero, orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)), count: 32)
        entities.withUnsafeMutableBufferPointer { e in
            transforms.withUnsafeMutableBufferPointer { t in
                let written = backend.readActiveTransforms(into: PhysicsTransformReadBatch(entities: e, transforms: t))
                for i in 0 ..< written { poses[e[i]] = t[i] }
            }
        }
    }

    private func pinsDown(_ poses: [EntityID: PhysicsBodyTransform], layout: CoolBowlingScene.LaneLayout) -> Int {
        var down = 0
        for index in 0 ..< 10 {
            let spot = layout.pinPositions[index]
            let pose = poses[EntityID(1 + index)] ?? PhysicsBodyTransform(position: spot, orientation: layout.orientation)
            let up = pose.orientation.act(SIMD3<Float>(0, 1, 0))
            let displacement = simd_length(SIMD3<Float>(pose.position.x - spot.x, 0, pose.position.z - spot.z))
            if CoolBowlingScene.isPinDown(up: up, displacement: displacement) { down += 1 }
        }
        return down
    }
}

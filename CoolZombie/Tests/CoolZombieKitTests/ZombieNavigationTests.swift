import CoolZombieKit
import simd
import XCTest

final class ZombieNavigationTests: XCTestCase {
    // A 3 m wall across the origin, 0.2 m thick.
    let wall = NavObstacle(center: simd_float3(0, 0.75, 0), size: simd_float3(3.2, 1.5, 0.2))

    func testClearLineIsDirect() {
        let nav = ZombieNavigator(obstacles: [wall])
        let route = nav.route(from: simd_float3(-3, 0, -3), to: simd_float3(3, 0, -3))
        XCTAssertTrue(route.direct)
        XCTAssertEqual(route.waypoints.count, 1)
        XCTAssertEqual(route.length, 6, accuracy: 1e-4)
    }

    func testRouteGoesAroundTheWall() {
        let nav = ZombieNavigator(obstacles: [wall])
        let from = simd_float3(0, 0, -2), to = simd_float3(0, 0, 2)
        let route = nav.route(from: from, to: to)
        XCTAssertFalse(route.direct)
        XCTAssertTrue(route.reachable)
        XCTAssertGreaterThan(route.waypoints.count, 1, "a detour needs a corner waypoint")
        XCTAssertGreaterThan(route.length, 4.5, "around a 3.2 m wall the path is well over the 4 m straight line")
        XCTAssertLessThan(route.length, 7)
        // Every pulled segment is clear of the inflated wall, and it ends at the target.
        var previous = from
        for point in route.waypoints {
            XCTAssertTrue(nav.isClear(from: previous, to: point))
            previous = point
        }
        XCTAssertEqual(previous.x, to.x, accuracy: 1e-4)
        XCTAssertEqual(previous.z, to.z, accuracy: 1e-4)
    }

    func testEnclosedTargetIsUnreachableButStillSteered() {
        // Four walls around the target.
        let box: [NavObstacle] = [
            NavObstacle(center: simd_float3(0, 0.5, 1.5), size: simd_float3(3, 1, 0.2)),
            NavObstacle(center: simd_float3(0, 0.5, -1.5), size: simd_float3(3, 1, 0.2)),
            NavObstacle(center: simd_float3(1.5, 0.5, 0), size: simd_float3(0.2, 1, 3)),
            NavObstacle(center: simd_float3(-1.5, 0.5, 0), size: simd_float3(0.2, 1, 3)),
        ]
        let nav = ZombieNavigator(obstacles: box)
        let route = nav.route(from: simd_float3(-4, 0, 0), to: simd_float3(0, 0, 0))
        XCTAssertFalse(route.reachable)
        XCTAssertEqual(route.waypoints, [simd_float3(0, 0, 0)])
    }

    func testPushOutLeavesTheInflatedBox() {
        let nav = ZombieNavigator(obstacles: [wall], radius: 0.4)
        let inside = simd_float3(0.5, 0, 0.05)
        let out = nav.pushOut(inside)
        XCTAssertEqual(out.x, 0.5, accuracy: 1e-4, "shortest way out is along z")
        XCTAssertEqual(out.z, 0.1 + 0.4, accuracy: 1e-4)
        XCTAssertEqual(out.y, 0)
        let outside = simd_float3(3, 0, 3)
        XCTAssertEqual(nav.pushOut(outside), outside)
    }

    func testRadiusKeepsTheRouteOffTheWallEnds() {
        let nav = ZombieNavigator(obstacles: [wall], radius: 0.4)
        let route = nav.route(from: simd_float3(0, 0, -2), to: simd_float3(0, 0, 2))
        for point in route.waypoints.dropLast() {
            XCTAssertGreaterThan(abs(point.x), 1.6 + 0.3, "corner waypoints clear the wall end by about the radius")
        }
    }
}

final class ZombieNavigationHitTests: XCTestCase {
    func testFirstHitReturnsTheEntryFaceAndNormal() {
        let wall = NavObstacle(center: simd_float3(0, 0.75, 0), size: simd_float3(3.2, 1.5, 0.2))
        let nav = ZombieNavigator(obstacles: [wall])
        let hit = nav.firstHit(from: simd_float3(0.5, 0, -2), to: simd_float3(0.5, 0, 2))
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit!.point.z, -0.1, accuracy: 1e-4)
        XCTAssertEqual(hit!.point.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(hit!.normal, simd_float3(0, 0, -1))
        XCTAssertEqual(hit!.distance, 1.9, accuracy: 1e-4)
        XCTAssertNil(nav.firstHit(from: simd_float3(-3, 0, -2), to: simd_float3(-3, 0, 2)), "misses the wall's end")
    }
}

final class ZombieNavigationOrientedTests: XCTestCase {
    func testRotatedWallBlocksAndRoutes() {
        // The same 3.2 m wall turned to lie along z (yaw 90°): a line across x is blocked, across z is clear.
        let wall = NavObstacle(center: simd_float3(0, 0.75, 0), size: simd_float3(3.2, 1.5, 0.2), yaw: .pi / 2)
        let nav = ZombieNavigator(obstacles: [wall])
        XCTAssertFalse(nav.isClear(from: simd_float3(-2, 0, 0), to: simd_float3(2, 0, 0)))
        XCTAssertTrue(nav.isClear(from: simd_float3(0.5, 0, -2), to: simd_float3(0.5, 0, 2)))
        let route = nav.route(from: simd_float3(-2, 0, 0), to: simd_float3(2, 0, 0))
        XCTAssertTrue(route.reachable)
        XCTAssertFalse(route.direct)
        XCTAssertGreaterThan(route.length, 4.5)
    }

    func testDiagonalWallHitNormalAndPushOut() {
        let wall = NavObstacle(center: simd_float3(0, 0.75, 0), size: simd_float3(4, 1.5, 0.2), yaw: .pi / 4)
        let nav = ZombieNavigator(obstacles: [wall], radius: 0.4)
        // Approach along the wall's local normal: local +Z maps to world (sin 45°, cos 45°).
        let normalWorld = simd_normalize(simd_float3(sin(Float.pi / 4), 0, cos(Float.pi / 4)))
        let hit = nav.firstHit(from: -normalWorld * 2, to: normalWorld * 2)
        XCTAssertNotNil(hit)
        XCTAssertEqual(simd_dot(hit!.normal, -normalWorld), 1, accuracy: 1e-3, "normal points back toward the start")
        XCTAssertEqual(hit!.distance, 1.9, accuracy: 1e-3)
        // A point just inside the inflated wall on that side is pushed straight out along the normal.
        let inside = -normalWorld * 0.3
        let out = nav.pushOut(inside)
        XCTAssertEqual(simd_dot(out, -normalWorld), 0.1 + 0.4, accuracy: 1e-3)
        XCTAssertEqual(simd_length(out - simd_dot(out, -normalWorld) * -normalWorld), 0, accuracy: 1e-3)
    }

    func testLayoutFileRoundTrip() throws {
        let boxes = [NavObstacle(center: simd_float3(1, 0.75, -2), size: simd_float3(3, 1.5, 0.1), yaw: 0.3),
                     NavObstacle(center: simd_float3(-1, 0.4, 1), size: simd_float3(0.8, 0.8, 0.8))]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString).json")
        try NavLayoutFile(name: "test", obstacles: boxes).write(to: url)
        let loaded = try NavLayoutFile.read(from: url)
        XCTAssertEqual(loaded.name, "test")
        XCTAssertEqual(loaded.obstacles, boxes)
        try? FileManager.default.removeItem(at: url)
    }
}

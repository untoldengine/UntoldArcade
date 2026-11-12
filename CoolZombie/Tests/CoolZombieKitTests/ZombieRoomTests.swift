import CoolZombieKit
import simd
import XCTest

final class ZombieRoomTests: XCTestCase {
    /// A vertical surface whose width runs along `along` on the ground;
    /// `swapAxes` puts the height on the extent's first axis instead, as
    /// ARKit is free to.
    func wall(kind: RoomSurface.Kind = .wall, center: simd_float3, width: Float, height: Float,
              along: simd_float3, swapAxes: Bool = false) -> RoomSurface
    {
        let up = simd_float3(0, 1, 0)
        return RoomSurface(kind: kind, orientation: .vertical, center: center,
                           axisU: swapAxes ? up : along, axisV: swapAxes ? along : up,
                           width: swapAxes ? height : width, height: swapAxes ? width : height)
    }

    /// A horizontal surface, `width` along `along` and `depth` across it.
    func top(kind: RoomSurface.Kind, center: simd_float3, width: Float, depth: Float,
             along: simd_float3 = simd_float3(1, 0, 0)) -> RoomSurface
    {
        RoomSurface(kind: kind, orientation: .horizontal, center: center,
                    axisU: along, axisV: simd_float3(-along.z, 0, along.x), width: width, height: depth)
    }

    func testWallBecomesAThinBoxAlongItsLength() {
        let along = simd_float3(cos(0.4), 0, -sin(0.4))
        let center = simd_float3(1, 1.3, -2)
        let boxes = ZombieRoom.obstacles(from: [wall(center: center, width: 3, height: 2.6, along: along)], floor: 0)
        XCTAssertEqual(boxes.count, 1)
        let box = boxes[0]
        XCTAssertEqual(box.center, center)
        XCTAssertEqual(box.size.x, 3, accuracy: 1e-5)
        XCTAssertEqual(box.size.y, 2.6, accuracy: 1e-5)
        XCTAssertEqual(box.size.z, 0.1, accuracy: 1e-5)
        XCTAssertEqual(box.yaw, 0.4, accuracy: 1e-5)
        XCTAssertEqual(box.alongAxis.x, along.x, accuracy: 1e-5)
        XCTAssertEqual(box.alongAxis.y, along.z, accuracy: 1e-5)
        // It blocks the way through and not the way past.
        let nav = ZombieNavigator(obstacles: boxes)
        let normal = simd_float3(-along.z, 0, along.x)
        XCTAssertFalse(nav.isClear(from: center - normal, to: center + normal))
        XCTAssertTrue(nav.isClear(from: center + normal - along * 3, to: center + normal + along * 3))
        XCTAssertTrue(ZombieRoom.isWall(box))
    }

    func testSwappedExtentAxesGiveTheSameWall() {
        let along = simd_float3(0, 0, 1)
        let center = simd_float3(-3, 1.2, 0)
        let straight = ZombieRoom.obstacles(from: [wall(center: center, width: 4, height: 2.4, along: along)], floor: 0)
        let swapped = ZombieRoom.obstacles(from: [wall(center: center, width: 4, height: 2.4, along: along, swapAxes: true)], floor: 0)
        XCTAssertEqual(straight, swapped)
        XCTAssertEqual(straight[0].size.x, 4, accuracy: 1e-5)
        XCTAssertEqual(straight[0].size.y, 2.4, accuracy: 1e-5)
    }

    func testDoorsAndWindowsAreWallsFloorsAndCeilingsAreNot() {
        let along = simd_float3(1, 0, 0)
        let surfaces = [
            wall(kind: .door, center: simd_float3(2, 1.05, -3), width: 0.9, height: 2.1, along: along),
            wall(kind: .window, center: simd_float3(-2, 1.5, -3), width: 1.2, height: 1.0, along: along),
            top(kind: .floor, center: simd_float3(0, 0, 0), width: 5, depth: 5),
            top(kind: .ceiling, center: simd_float3(0, 2.6, 0), width: 5, depth: 5),
            RoomSurface(kind: .unknown, orientation: .slanted, center: simd_float3(0, 2, 0),
                        axisU: simd_float3(1, 0, 0), axisV: simd_float3(0, 0.7, 0.7), width: 2, height: 2),
        ]
        let boxes = ZombieRoom.obstacles(from: surfaces, floor: 0)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertTrue(boxes.allSatisfy { ZombieRoom.isWall($0) })
        XCTAssertEqual(ZombieRoom.summary(of: boxes), "2 walls, 0 pieces of furniture")
    }

    func testFragmentsAreDropped() {
        let along = simd_float3(1, 0, 0)
        let picture = wall(center: simd_float3(0, 1.5, -3), width: 0.3, height: 0.3, along: along)
        let chairBack = wall(kind: .unknown, center: simd_float3(1, 0.6, -1), width: 0.6, height: 0.5, along: along)
        let wardrobeSide = wall(kind: .unknown, center: simd_float3(-2, 1, -1), width: 1.0, height: 1.9, along: along)
        XCTAssertTrue(ZombieRoom.obstacles(from: [picture, chairBack], floor: 0).isEmpty)
        XCTAssertEqual(ZombieRoom.obstacles(from: [wardrobeSide], floor: 0).count, 1)
    }

    func testTableStandsOnTheFloor() {
        // The simulator's floor is 1 m below the origin; the top is 0.75 m above it.
        let along = simd_float3(cos(0.3), 0, sin(0.3))
        let table = top(kind: .table, center: simd_float3(1.2, -0.25, -3), width: 1.2, depth: 0.7, along: along)
        let boxes = ZombieRoom.obstacles(from: [table], floor: -1)
        XCTAssertEqual(boxes.count, 1)
        let box = boxes[0]
        XCTAssertEqual(box.center.x, 1.2, accuracy: 1e-5)
        XCTAssertEqual(box.center.y, -0.625, accuracy: 1e-5)
        XCTAssertEqual(box.center.z, -3, accuracy: 1e-5)
        XCTAssertEqual(box.size.x, 1.2, accuracy: 1e-5)
        XCTAssertEqual(box.size.y, 0.75, accuracy: 1e-5)
        XCTAssertEqual(box.size.z, 0.7, accuracy: 1e-5)
        XCTAssertEqual(box.yaw, -0.3, accuracy: 1e-5)
        XCTAssertFalse(ZombieRoom.isWall(box))
        XCTAssertEqual(ZombieRoom.summary(of: boxes), "0 walls, 1 piece of furniture")
    }

    func testTopsNearTheFloorOrOverheadMakeNoObstacle() {
        let rug = top(kind: .unknown, center: simd_float3(0, 0.05, 0), width: 2, depth: 1.5)
        let shelf = top(kind: .unknown, center: simd_float3(0, 2.1, -3), width: 0.8, depth: 0.3)
        let seat = top(kind: .seat, center: simd_float3(0, 0.45, -2), width: 1.8, depth: 0.85)
        let coaster = top(kind: .unknown, center: simd_float3(0, 0.75, -2), width: 0.1, depth: 0.1)
        let boxes = ZombieRoom.obstacles(from: [rug, shelf, seat, coaster], floor: 0)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].size.y, 0.45, accuracy: 1e-5)
    }

    func testSampleRoomLoadsAndRoutesAroundTheSofa() throws {
        let file = try ZombieRoom.load(ZombieRoom.sampleName)
        XCTAssertEqual(file.name, "sample")
        XCTAssertEqual(ZombieRoom.summary(of: file.obstacles), "4 walls, 3 pieces of furniture")
        let boxes = ZombieRoom.obstacles(of: file, onFloor: -1)
        XCTAssertEqual(boxes.count, file.obstacles.count)
        XCTAssertEqual(boxes[0].center.y, file.obstacles[0].center.y - 1, accuracy: 1e-5)
        // The headset's spawn point to the head at the origin: the sofa is in the way, the room is not.
        let nav = ZombieNavigator(obstacles: boxes)
        let route = nav.route(from: simd_float3(0, -1, -4), to: simd_float3(0, -1, 0))
        XCTAssertFalse(route.direct)
        XCTAssertTrue(route.reachable)
        XCTAssertLessThan(route.length, 6)
    }

    func testBoundsCoverRotatedBoxesAndPoints() {
        // 4 m long along z at x = 10.
        let box = NavObstacle(center: simd_float3(10, 1, 0), size: simd_float3(4, 2, 0.1), yaw: .pi / 2)
        let bounds = ZombieNavigator.bounds(around: [box], including: [simd_float2(0, -12)], padding: 1, minimumHalfExtent: 8)
        XCTAssertEqual(bounds.min.x, -8, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.x, 11.05, accuracy: 1e-4)
        XCTAssertEqual(bounds.min.y, -13, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.y, 8, accuracy: 1e-5)
        // A route through that grid reaches a target far from the origin.
        let nav = ZombieNavigator(obstacles: [box], boundsMin: bounds.min, boundsMax: bounds.max)
        let route = nav.route(from: simd_float3(8, 0, 0), to: simd_float3(12, 0, 0))
        XCTAssertFalse(route.direct)
        XCTAssertTrue(route.reachable)
    }

    func testFootprintCornersRotate() {
        let box = NavObstacle(center: simd_float3(1, 0, 2), size: simd_float3(2, 1, 1), yaw: .pi / 2)
        let corners = box.footprintCorners
        XCTAssertEqual(corners.count, 4)
        for corner in corners {
            XCTAssertEqual(abs(corner.x - 1), 0.5, accuracy: 1e-5, "the 2 m side now runs along z")
            XCTAssertEqual(abs(corner.y - 2), 1, accuracy: 1e-5)
        }
    }

    func testLayoutFileKeepsTheFloorAndDefaultsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zombie-room-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("room.json")
        let box = NavObstacle(center: simd_float3(0, 0.3, -2), size: simd_float3(1, 0.6, 1), yaw: 0.2)
        try NavLayoutFile(name: "captured", obstacles: [box], floor: -0.02).write(to: url)
        let read = try NavLayoutFile.read(from: url)
        XCTAssertEqual(read.floor, -0.02)
        XCTAssertEqual(read.obstacles, [box])
        XCTAssertEqual(ZombieRoom.obstacles(of: read, onFloor: 0)[0].center.y, 0.32, accuracy: 1e-5)
        // A file from before the floor was recorded.
        let legacy = url.deletingLastPathComponent().appendingPathComponent("legacy.json")
        try Data("""
        {"name":"old","created":"2026-09-08T10:00:00Z","obstacles":[{"center":[0,0.5,0],"size":[1,1,1],"yaw":0}]}
        """.utf8).write(to: legacy)
        XCTAssertEqual(try NavLayoutFile.read(from: legacy).floor, 0)
    }
}

/// The spawn search: ahead of the player when clear, pulled back or
/// turned aside by the room.
final class ZombieSpawnTests: XCTestCase {
    let forward = simd_float2(0, -1)

    func testOpenFieldSpawnsAtTheDistance() {
        let nav = ZombieNavigator(obstacles: [NavObstacle(center: simd_float3(6, 0.5, 6), size: simd_float3(1, 1, 1))])
        let spawn = nav.spawnPoint(from: .zero, facing: forward, distance: 4)
        XCTAssertEqual(spawn.x, 0, accuracy: 1e-4)
        XCTAssertEqual(spawn.y, -4, accuracy: 1e-4)
    }

    func testWallAheadPullsTheSpawnBack() {
        // A wall across the way 2 m ahead: the spawn stops the radius short of it.
        let wall = NavObstacle(center: simd_float3(0, 1.3, -2), size: simd_float3(4, 2.6, 0.1))
        let nav = ZombieNavigator(obstacles: [wall])
        let spawn = nav.spawnPoint(from: .zero, facing: forward, distance: 4)
        XCTAssertEqual(spawn.x, 0, accuracy: 1e-4)
        XCTAssertEqual(spawn.y, -1.5, accuracy: 0.15)
        XCTAssertTrue(nav.isClear(from: .zero, to: spawn))
    }

    func testWallTooCloseTurnsTheSpawnAside() {
        // Facing a wall 1 m away: ahead leaves under 1.5 m, so another way
        // round — never through the wall.
        let wall = NavObstacle(center: simd_float3(0, 1.3, -1), size: simd_float3(6, 2.6, 0.1))
        let nav = ZombieNavigator(obstacles: [wall])
        let spawn = nav.spawnPoint(from: .zero, facing: forward, distance: 4)
        XCTAssertEqual(simd_length(spawn), 4, accuracy: 1e-3)
        XCTAssertGreaterThan(spawn.y, -0.6, "not beyond the wall")
        XCTAssertTrue(nav.isClear(from: .zero, to: spawn))
    }

    func testOriginInsideTheSandboxWallStillSpawnsAcrossTheArena() {
        // The Wall layout: the cube's origin sits inside the wall itself.
        let wall = NavObstacle(center: simd_float3(0, 0.75, 0), size: simd_float3(3.2, 1.5, 0.2))
        let nav = ZombieNavigator(obstacles: [wall])
        let spawn = nav.spawnPoint(from: .zero, facing: forward, distance: 2.5)
        XCTAssertEqual(spawn.x, 0, accuracy: 1e-4)
        XCTAssertEqual(spawn.y, -2.5, accuracy: 1e-4)
    }

    func testEnclosedOriginSpawnsInsideTheEnclosure() {
        let box: [NavObstacle] = [
            NavObstacle(center: simd_float3(0, 1, 1.2), size: simd_float3(2.6, 2, 0.1)),
            NavObstacle(center: simd_float3(0, 1, -1.2), size: simd_float3(2.6, 2, 0.1)),
            NavObstacle(center: simd_float3(1.2, 1, 0), size: simd_float3(0.1, 2, 2.6)),
            NavObstacle(center: simd_float3(-1.2, 1, 0), size: simd_float3(0.1, 2, 2.6)),
        ]
        let nav = ZombieNavigator(obstacles: box)
        let spawn = nav.spawnPoint(from: .zero, facing: forward, distance: 4)
        XCTAssertGreaterThan(simd_length(spawn), 0.3)
        XCTAssertLessThan(abs(spawn.x), 1.2)
        XCTAssertLessThan(abs(spawn.y), 1.2)
    }
}

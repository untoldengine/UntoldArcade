import CoolZombieKit
import simd
import XCTest

/// The scan mesh path: triangles into the occupancy grid, clusters into
/// boxes, with the planes' boxes taking precedence.
final class ZombieRoomScanTests: XCTestCase {
    typealias Triangle = (simd_float3, simd_float3, simd_float3)

    /// The twelve triangles of a box standing on the floor, turned `yaw`
    /// about the vertical axis like a `NavObstacle` (its length along
    /// `alongAxis`).
    func blockMesh(center: simd_float2, size: simd_float3, yaw: Float, floor: Float) -> [Triangle] {
        let box = NavObstacle(center: simd_float3(center.x, floor + size.y / 2, center.y), size: size, yaw: yaw)
        let corners = box.footprintCorners
        func at(_ corner: simd_float2, _ y: Float) -> simd_float3 { simd_float3(corner.x, y, corner.y) }
        let bottom = floor, top = floor + size.y
        var triangles: [Triangle] = []
        // Top and bottom.
        triangles.append((at(corners[0], top), at(corners[1], top), at(corners[2], top)))
        triangles.append((at(corners[0], top), at(corners[2], top), at(corners[3], top)))
        triangles.append((at(corners[0], bottom), at(corners[1], bottom), at(corners[2], bottom)))
        triangles.append((at(corners[0], bottom), at(corners[2], bottom), at(corners[3], bottom)))
        // Sides.
        for index in 0 ..< 4 {
            let a = corners[index], b = corners[(index + 1) % 4]
            triangles.append((at(a, bottom), at(b, bottom), at(b, top)))
            triangles.append((at(a, bottom), at(b, top), at(a, top)))
        }
        return triangles
    }

    func occupancy(_ triangles: [Triangle], floor: Float, rules: ZombieRoom.Rules = ZombieRoom.Rules()) -> RoomOccupancy {
        var grid = RoomOccupancy(cellSize: rules.occupancyCellSize)
        for (a, b, c) in triangles {
            grid.mark(a, b, c, lowest: floor + rules.minimumFurnitureTop, highest: floor + rules.maximumFurnitureTop)
        }
        return grid
    }

    func testTrianglesMarkOnlyTheBandAtWalkingHeight() {
        var grid = RoomOccupancy(cellSize: 0.1)
        // A floor triangle and a ceiling triangle: nothing.
        grid.mark(simd_float3(0, 0, 0), simd_float3(1, 0, 0), simd_float3(0, 0, 1), lowest: 0.15, highest: 1.9)
        grid.mark(simd_float3(0, 2.6, 0), simd_float3(1, 2.6, 0), simd_float3(0, 2.6, 1), lowest: 0.15, highest: 1.9)
        XCTAssertTrue(grid.isEmpty)
        // A vertical wall piece along x from 0 to 1 m at z = 2: a line of cells.
        grid.mark(simd_float3(0, 0, 2), simd_float3(1, 0, 2), simd_float3(1, 2.6, 2), lowest: 0.15, highest: 1.9)
        XCTAssertGreaterThanOrEqual(grid.cells.count, 10)
        XCTAssertLessThanOrEqual(grid.cells.count, 24, "a line, not a filled box")
        for (cell, height) in grid.cells {
            let center = grid.center(of: cell)
            XCTAssertEqual(center.y, 2, accuracy: 0.11, "cells hug the wall's line")
            XCTAssertGreaterThanOrEqual(center.x, -0.11)
            XCTAssertLessThanOrEqual(center.x, 1.11)
            XCTAssertEqual(height, 1.9, accuracy: 1e-5, "the top is clipped to the band")
        }
    }

    func testMergedPiecesKeepTheHighestTop() {
        let a = RoomOccupancy(cellSize: 0.1, cells: [RoomOccupancy.Cell(column: 1, row: 2): 0.5])
        let b = RoomOccupancy(cellSize: 0.1, cells: [RoomOccupancy.Cell(column: 1, row: 2): 0.9, RoomOccupancy.Cell(column: 3, row: 3): 0.3])
        let merged = RoomOccupancy.merged([a, b])
        XCTAssertEqual(merged.cells.count, 2)
        XCTAssertEqual(merged.cells[RoomOccupancy.Cell(column: 1, row: 2)], 0.9)
    }

    func testScannedSofaBecomesAnOrientedBox() {
        let floor: Float = -1
        let triangles = blockMesh(center: simd_float2(0.6, -2.4), size: simd_float3(1.8, 0.8, 0.85), yaw: 0.5, floor: floor)
        let boxes = ZombieRoom.furniture(from: occupancy(triangles, floor: floor), excluding: [], floor: floor)
        XCTAssertEqual(boxes.count, 1)
        let box = boxes[0]
        XCTAssertEqual(box.center.x, 0.6, accuracy: 0.08)
        XCTAssertEqual(box.center.z, -2.4, accuracy: 0.08)
        XCTAssertEqual(box.center.y, floor + 0.4, accuracy: 1e-4)
        XCTAssertEqual(box.size.y, 0.8, accuracy: 1e-4)
        // Within half a cell of the sofa; its long side may come out as x
        // or z, with the yaw a quarter turn apart.
        let long = max(box.size.x, box.size.z), short = min(box.size.x, box.size.z)
        XCTAssertEqual(long, 1.8, accuracy: 0.06)
        XCTAssertEqual(short, 0.85, accuracy: 0.06)
        let alongLong = box.size.x >= box.size.z ? box.alongAxis : simd_float2(-box.alongAxis.y, box.alongAxis.x)
        let expected = simd_float2(cos(0.5), -sin(0.5))
        XCTAssertEqual(abs(simd_dot(alongLong, expected)), 1, accuracy: 0.03, "the long side runs along the sofa")
        XCTAssertFalse(ZombieRoom.isWall(box))
    }

    func testScanUnderThePlanesBoxesMakesNoFurniture() {
        let floor: Float = 0
        // The scan of a wall (a thin tall block) and of a table (its top and legs).
        let wallScan = blockMesh(center: simd_float2(0, -3), size: simd_float3(4, 2.6, 0.02), yaw: 0, floor: floor)
        let tableScan = blockMesh(center: simd_float2(1.5, -1), size: simd_float3(1.2, 0.75, 0.7), yaw: 0.3, floor: floor)
        let grid = occupancy(wallScan + tableScan, floor: floor)
        let wallPlane = RoomSurface(kind: .wall, orientation: .vertical, center: simd_float3(0, 1.3, -3),
                                    axisU: simd_float3(1, 0, 0), axisV: simd_float3(0, 1, 0), width: 4, height: 2.6)
        let tablePlane = RoomSurface(kind: .table, orientation: .horizontal, center: simd_float3(1.5, 0.75, -1),
                                     axisU: simd_float3(cos(0.3), 0, -sin(0.3)), axisV: simd_float3(sin(0.3), 0, cos(0.3)),
                                     width: 1.2, height: 0.7)
        let known = ZombieRoom.obstacles(from: [wallPlane, tablePlane], scan: grid, floor: floor)
        XCTAssertEqual(known.planes.count, 2)
        XCTAssertTrue(known.scan.isEmpty, "the planes already account for the wall and the table")
        // Without the planes the scan supplies both.
        let unknown = ZombieRoom.obstacles(from: [], scan: grid, floor: floor)
        XCTAssertEqual(unknown.scan.count, 2)
        XCTAssertEqual(ZombieRoom.summary(of: unknown.planes + unknown.scan, scanned: unknown.scan.count),
                       "1 wall, 1 piece of furniture (2 from the scan)")
    }

    func testScanNoiseIsDropped() {
        var grid = RoomOccupancy(cellSize: 0.1)
        // One stray triangle: a couple of cells.
        grid.mark(simd_float3(2, 0.4, 2), simd_float3(2.05, 0.4, 2), simd_float3(2, 0.45, 2.05), lowest: 0.15, highest: 1.9)
        XCTAssertFalse(grid.isEmpty)
        XCTAssertTrue(ZombieRoom.furniture(from: grid, excluding: [], floor: 0).isEmpty)
    }

    func testMinimumAreaRectangleFollowsARotatedRectangle() {
        let box = NavObstacle(center: simd_float3(2, 0, -1), size: simd_float3(3, 1, 1), yaw: -0.7)
        let rectangle = ZombieRoom.minimumAreaRectangle(box.footprintCorners)
        XCTAssertEqual(rectangle.center.x, 2, accuracy: 1e-4)
        XCTAssertEqual(rectangle.center.y, -1, accuracy: 1e-4)
        let long = max(rectangle.size.x, rectangle.size.y), short = min(rectangle.size.x, rectangle.size.y)
        XCTAssertEqual(long, 3, accuracy: 1e-4)
        XCTAssertEqual(short, 1, accuracy: 1e-4)
        let fitted = NavObstacle(center: simd_float3(rectangle.center.x, 0, rectangle.center.y),
                                 size: simd_float3(rectangle.size.x, 1, rectangle.size.y), yaw: rectangle.yaw)
        // Same footprint: every original corner lies on the fitted box's edge.
        for corner in box.footprintCorners {
            XCTAssertTrue(fitted.contains(corner, margin: 1e-3))
            XCTAssertFalse(fitted.contains(corner, margin: -1e-3))
        }
    }
}

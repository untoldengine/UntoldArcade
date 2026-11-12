//
//  ZombieRoom.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd
import SwiftUI
import UntoldEngine

/// A flat surface found in the room — one of ARKit's plane anchors, reduced
/// to what navigation needs and free of ARKit types, so turning a room into
/// obstacles runs (and is tested) on the Mac as well as on the headset.
public struct RoomSurface: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case wall, door, window, floor, ceiling, table, seat, unknown
    }

    public enum Orientation: String, Sendable {
        case horizontal, vertical, slanted
    }

    public var id: UUID
    public var kind: Kind
    public var orientation: Orientation
    /// The centre of the surface's extent, in world metres.
    public var center: simd_float3
    /// World directions (unit length) of the extent's two axes: `axisU`
    /// spans `width`, `axisV` spans `height`. Which of the two lies flat
    /// is not fixed for a vertical surface.
    public var axisU: simd_float3
    public var axisV: simd_float3
    public var width: Float
    public var height: Float

    public init(id: UUID = UUID(), kind: Kind, orientation: Orientation, center: simd_float3,
                axisU: simd_float3, axisV: simd_float3, width: Float, height: Float)
    {
        self.id = id
        self.kind = kind
        self.orientation = orientation
        self.center = center
        self.axisU = simd_normalize(axisU)
        self.axisV = simd_normalize(axisV)
        self.width = abs(width)
        self.height = abs(height)
    }

    public var area: Float { width * height }
}

/// The room as the chase sees it. Surfaces become the boxes the zombie
/// routes around and plants its hands on; a room can be saved as a layout
/// file and replayed — in the Mac sandbox, or in the simulator, which
/// detects no surfaces of its own.
public enum ZombieRoom {
    /// How surfaces turn into obstacles.
    public struct Rules: Sendable {
        /// Walls are thin boxes: this deep front to back, the plane in the
        /// middle.
        public var wallThickness: Float = 0.1
        /// Vertical surfaces narrower or lower than this are fragments (a
        /// door frame, a picture, a chair back) and are dropped.
        public var minimumWallSpan: Float = 0.4
        /// Unclassified vertical surfaces count as walls only from this
        /// size (a wardrobe side, not a cushion).
        public var minimumUnknownWallSpan: Float = 0.8
        /// Horizontal surfaces closer than this to the floor are the floor,
        /// a rug or a step; above `maximumFurnitureTop` the zombie walks
        /// underneath.
        public var minimumFurnitureTop: Float = 0.15
        public var maximumFurnitureTop: Float = 1.9
        /// Horizontal surfaces smaller than this on either side are dropped.
        public var minimumFurnitureSpan: Float = 0.25
        /// The scan mesh: cells of the occupancy grid; clusters with fewer
        /// cells than this are noise (a first capture gave door frames and
        /// skirting as 1-4 cell slivers); cells this close to a box the
        /// planes gave belong to it and make no cluster — generous at walls,
        /// whose scan carries skirting, radiators and curtains, tighter at
        /// table tops so a chair beside one still counts.
        public var occupancyCellSize: Float = 0.1
        public var minimumScanCells: Int = 6
        public var scanWallMargin: Float = 0.3
        public var scanTopMargin: Float = 0.15

        public init() {}
    }

    /// The obstacles for a set of surfaces. Walls, doors and windows
    /// (vertical) become thin boxes the height of the surface; tables,
    /// seats and other horizontal tops above the floor become boxes from
    /// the floor up to the top — the zombie does not crawl under a table.
    /// Floors, ceilings and slanted surfaces make no obstacle.
    public static func obstacles(from surfaces: [RoomSurface], floor: Float, rules: Rules = Rules()) -> [NavObstacle] {
        var boxes: [NavObstacle] = []
        for surface in surfaces {
            switch surface.orientation {
            case .vertical:
                if let box = wall(from: surface, rules: rules) { boxes.append(box) }
            case .horizontal:
                if let box = furniture(from: surface, floor: floor, rules: rules) { boxes.append(box) }
            case .slanted:
                continue
            }
        }
        return boxes
    }

    static func wall(from surface: RoomSurface, rules: Rules) -> NavObstacle? {
        let minimum: Float
        switch surface.kind {
        case .wall, .door, .window: minimum = rules.minimumWallSpan
        case .unknown: minimum = rules.minimumUnknownWallSpan
        case .floor, .ceiling, .table, .seat: return nil
        }
        // The extent axis lying flattest runs along the wall; the other is
        // its height.
        let flatIsU = abs(surface.axisU.y) <= abs(surface.axisV.y)
        let along = flatIsU ? surface.axisU : surface.axisV
        let span = flatIsU ? surface.width : surface.height
        let rise = flatIsU ? surface.height : surface.width
        guard span >= minimum, rise >= minimum, let yaw = yaw(of: along) else { return nil }
        return NavObstacle(center: surface.center, size: simd_float3(span, rise, rules.wallThickness), yaw: yaw)
    }

    static func furniture(from surface: RoomSurface, floor: Float, rules: Rules) -> NavObstacle? {
        switch surface.kind {
        case .table, .seat, .unknown: break
        case .floor, .ceiling, .wall, .door, .window: return nil
        }
        let top = surface.center.y - floor
        guard top >= rules.minimumFurnitureTop, top <= rules.maximumFurnitureTop,
              surface.width >= rules.minimumFurnitureSpan, surface.height >= rules.minimumFurnitureSpan,
              let yaw = yaw(of: surface.axisU)
        else { return nil }
        let center = simd_float3(surface.center.x, floor + top / 2, surface.center.z)
        return NavObstacle(center: center, size: simd_float3(surface.width, top, surface.height), yaw: yaw)
    }

    /// Everything the room offers: the boxes the planes give, plus a box
    /// for every cluster of scanned geometry at walking height that those
    /// boxes do not already cover — a sofa's arms, a bed, a cabinet, a
    /// plant. Planes first: their extents are exact where the scan's are
    /// a cell coarse.
    public static func obstacles(from surfaces: [RoomSurface], scan: RoomOccupancy?, floor: Float,
                                 rules: Rules = Rules()) -> (planes: [NavObstacle], scan: [NavObstacle])
    {
        let planes = obstacles(from: surfaces, floor: floor, rules: rules)
        guard let scan, !scan.isEmpty else { return (planes, []) }
        return (planes, furniture(from: scan, excluding: planes, floor: floor, rules: rules))
    }

    /// Boxes for the clusters of occupied cells outside `boxes`: each
    /// cluster's smallest enclosing rectangle on the ground, from the
    /// floor up to the highest geometry in it. The rectangle is fitted to
    /// the cell centres and then shrunk by the marking reach — a cell is
    /// marked when geometry passes within 0.7 of a cell of its centre —
    /// which lands within half a cell of the scanned object's own size.
    public static func furniture(from occupancy: RoomOccupancy, excluding boxes: [NavObstacle], floor: Float,
                                 rules: Rules = Rules()) -> [NavObstacle]
    {
        let margins = boxes.map { isWall($0) ? rules.scanWallMargin : rules.scanTopMargin }
        let free = occupancy.cells.filter { cell, _ in
            let point = occupancy.center(of: cell)
            for (box, margin) in zip(boxes, margins) where box.contains(point, margin: margin) { return false }
            return true
        }
        var result: [NavObstacle] = []
        var visited = Set<RoomOccupancy.Cell>()
        let shrink = occupancy.cellSize * 1.4144
        for start in free.keys.sorted() where !visited.contains(start) {
            var cluster: [RoomOccupancy.Cell] = [start]
            var stack = [start]
            visited.insert(start)
            while let cell = stack.popLast() {
                for dr in Int32(-1) ... 1 {
                    for dc in Int32(-1) ... 1 where dr != 0 || dc != 0 {
                        let next = RoomOccupancy.Cell(column: cell.column + dc, row: cell.row + dr)
                        if free[next] != nil, visited.insert(next).inserted {
                            cluster.append(next)
                            stack.append(next)
                        }
                    }
                }
            }
            guard cluster.count >= rules.minimumScanCells,
                  let top = cluster.compactMap({ free[$0] }).max(), top - floor >= rules.minimumFurnitureTop
            else { continue }
            let rectangle = minimumAreaRectangle(cluster.map { occupancy.center(of: $0) })
            let size = simd_max(rectangle.size - shrink, simd_float2(repeating: occupancy.cellSize))
            let height = top - floor
            result.append(NavObstacle(center: simd_float3(rectangle.center.x, floor + height / 2, rectangle.center.y),
                                      size: simd_float3(size.x, height, size.y), yaw: rectangle.yaw))
        }
        return result.sorted { ($0.center.x, $0.center.z) < ($1.center.x, $1.center.z) }
    }

    /// The smallest-area rectangle around a set of ground points (rotating
    /// calipers over their convex hull): its centre, its sides and the yaw
    /// that puts `NavObstacle.alongAxis` along the first side.
    public static func minimumAreaRectangle(_ points: [simd_float2]) -> (center: simd_float2, size: simd_float2, yaw: Float) {
        let hull = convexHull(points)
        guard hull.count >= 2 else {
            return (hull.first ?? .zero, .zero, 0)
        }
        var best: (area: Float, center: simd_float2, size: simd_float2, yaw: Float)?
        for index in 0 ..< hull.count {
            let edge = hull[(index + 1) % hull.count] - hull[index]
            let length = simd_length(edge)
            guard length > 1e-6 else { continue }
            let u = edge / length
            let v = simd_float2(-u.y, u.x)
            var lowU = Float.infinity, highU = -Float.infinity, lowV = Float.infinity, highV = -Float.infinity
            for point in hull {
                let a = simd_dot(point, u), b = simd_dot(point, v)
                lowU = min(lowU, a); highU = max(highU, a)
                lowV = min(lowV, b); highV = max(highV, b)
            }
            let size = simd_float2(highU - lowU, highV - lowV)
            let area = size.x * size.y
            if best == nil || area < best!.area - 1e-7 {
                let center = u * (lowU + highU) / 2 + v * (lowV + highV) / 2
                best = (area, center, size, atan2(-u.y, u.x))
            }
        }
        guard let best else { return (hull[0], .zero, 0) }
        return (best.center, best.size, best.yaw)
    }

    /// Andrew's monotone chain: the hull counter-clockwise, no repeats.
    static func convexHull(_ points: [simd_float2]) -> [simd_float2] {
        let sorted = Array(Set(points.map { HashablePoint($0) })).map(\.point).sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: simd_float2, _ a: simd_float2, _ b: simd_float2) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [simd_float2] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        var upper: [simd_float2] = []
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    private struct HashablePoint: Hashable {
        let x: Float, y: Float
        init(_ p: simd_float2) { x = p.x; y = p.y }
        var point: simd_float2 { simd_float2(x, y) }
    }

    /// The obstacle yaw whose length axis runs along the direction's ground
    /// projection (`NavObstacle.alongAxis`).
    static func yaw(of direction: simd_float3) -> Float? {
        let flat = simd_float2(direction.x, direction.z)
        guard simd_length(flat) > 1e-3 else { return nil }
        return atan2(-flat.y, flat.x)
    }

    /// Walls are tall and thin; everything else is furniture.
    public static func isWall(_ box: NavObstacle) -> Bool {
        box.size.y >= 1.0 && min(box.size.x, box.size.z) <= 0.25
    }

    /// One line on a set of obstacles: "4 walls, 3 pieces of furniture",
    /// with how many of the boxes came from the scan when told.
    public static func summary(of obstacles: [NavObstacle], scanned: Int = 0) -> String {
        let walls = obstacles.filter { isWall($0) }.count
        let pieces = obstacles.count - walls
        var line = "\(walls) wall\(walls == 1 ? "" : "s"), \(pieces) piece\(pieces == 1 ? "" : "s") of furniture"
        if scanned > 0 { line += " (\(scanned) from the scan)" }
        return line
    }

    // MARK: - Layout files

    /// The room in the bundle: a living room around the origin with a sofa
    /// between the spawn point and the player, for the simulator and the
    /// Mac sandbox.
    public static let sampleName = "sample"

    /// A saved room: a name from the bundle's `Rooms/` folder, or a path.
    public static func load(_ nameOrPath: String) throws -> NavLayoutFile {
        if let url = bundledRoomURL(named: nameOrPath), FileManager.default.fileExists(atPath: url.path) {
            return try NavLayoutFile.read(from: url)
        }
        return try NavLayoutFile.read(from: URL(fileURLWithPath: (nameOrPath as NSString).expandingTildeInPath))
    }

    public static func bundledRoomURL(named name: String) -> URL? {
        guard !name.contains("/"), !name.hasSuffix(".json") else { return nil }
        return ZombieResources.baseURL?.appendingPathComponent("Rooms/\(name).json")
    }

    /// The layout's boxes with its floor moved to `floor` (a room captured
    /// on the device has its floor near zero; the simulator's is 1 m down).
    public static func obstacles(of layout: NavLayoutFile, onFloor floor: Float) -> [NavObstacle] {
        let lift = floor - layout.floor
        return layout.obstacles.map { box in
            var moved = box
            moved.center.y += lift
            return moved
        }
    }

    /// Writes the room to the app's Documents folder — where the Files app
    /// lists it when the app allows file sharing — and returns the file.
    @discardableResult
    public static func save(_ obstacles: [NavObstacle], floor: Float, name: String? = nil) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = name ?? "room_\(formatter.string(from: Date()))"
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = documents.appendingPathComponent("\(name).json")
        try NavLayoutFile(name: name, obstacles: obstacles, floor: floor).write(to: url)
        return url
    }
}

/// Where the room's scan mesh has geometry at walking height: a grid of
/// cells over the ground, each holding the top of what stands in it. On
/// the headset it is built from ARKit's scene reconstruction, one piece
/// per mesh anchor, and catches what plane detection has no plane for.
public struct RoomOccupancy: Sendable, Equatable {
    public struct Cell: Hashable, Comparable, Sendable {
        public var column: Int32
        public var row: Int32

        public init(column: Int32, row: Int32) {
            self.column = column
            self.row = row
        }

        public static func < (lhs: Cell, rhs: Cell) -> Bool {
            (lhs.row, lhs.column) < (rhs.row, rhs.column)
        }
    }

    public let cellSize: Float
    /// Occupied cells and the highest geometry in each (world height).
    public var cells: [Cell: Float]

    public init(cellSize: Float = 0.1, cells: [Cell: Float] = [:]) {
        self.cellSize = cellSize
        self.cells = cells
    }

    public var isEmpty: Bool { cells.isEmpty }

    public func cell(at point: simd_float2) -> Cell {
        Cell(column: Int32((point.x / cellSize).rounded(.down)), row: Int32((point.y / cellSize).rounded(.down)))
    }

    public func center(of cell: Cell) -> simd_float2 {
        simd_float2((Float(cell.column) + 0.5) * cellSize, (Float(cell.row) + 0.5) * cellSize)
    }

    /// Marks the cells under a triangle when any of it lies between
    /// `lowest` and `highest` (world heights): every cell whose centre is
    /// within half a diagonal of the triangle's ground projection, which
    /// for a vertical triangle is a line.
    public mutating func mark(_ a: simd_float3, _ b: simd_float3, _ c: simd_float3, lowest: Float, highest: Float) {
        let top = max(a.y, b.y, c.y), bottom = min(a.y, b.y, c.y)
        guard top >= lowest, bottom <= highest else { return }
        let height = min(top, highest)
        let pa = simd_float2(a.x, a.z), pb = simd_float2(b.x, b.z), pc = simd_float2(c.x, c.z)
        let low = cell(at: simd_min(simd_min(pa, pb), pc))
        let high = cell(at: simd_max(simd_max(pa, pb), pc))
        let reach = cellSize * 0.7072
        for row in low.row ... high.row {
            for column in low.column ... high.column {
                let key = Cell(column: column, row: row)
                guard RoomOccupancy.distance(from: center(of: key), toTriangle: pa, pb, pc) <= reach else { continue }
                cells[key] = max(cells[key] ?? -.infinity, height)
            }
        }
    }

    /// The union of several pieces (the mesh anchors), highest wins.
    public static func merged(_ pieces: [RoomOccupancy], cellSize: Float = 0.1) -> RoomOccupancy {
        var result = RoomOccupancy(cellSize: cellSize)
        for piece in pieces {
            result.cells.merge(piece.cells) { max($0, $1) }
        }
        return result
    }

    static func distance(from p: simd_float2, toTriangle a: simd_float2, _ b: simd_float2, _ c: simd_float2) -> Float {
        func cross(_ u: simd_float2, _ v: simd_float2) -> Float { u.x * v.y - u.y * v.x }
        let d1 = cross(b - a, p - a), d2 = cross(c - b, p - b), d3 = cross(a - c, p - c)
        let negative = d1 < 0 || d2 < 0 || d3 < 0
        let positive = d1 > 0 || d2 > 0 || d3 > 0
        if !(negative && positive), abs(cross(b - a, c - a)) > 1e-8 { return 0 }
        return min(distance(from: p, toSegment: a, b), distance(from: p, toSegment: b, c), distance(from: p, toSegment: c, a))
    }

    static func distance(from p: simd_float2, toSegment a: simd_float2, _ b: simd_float2) -> Float {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-12 else { return simd_distance(p, a) }
        let t = min(max(simd_dot(p - a, ab) / lengthSquared, 0), 1)
        return simd_distance(p, a + ab * t)
    }
}

/// Draws obstacles as boxes: the sandbox's layouts, and a saved or sample
/// room where there are no real walls to see — the simulator, or a debug
/// toggle on the device (translucent, so the real wall shows through).
public final class ZombieObstacleRenderer: @unchecked Sendable {
    private var entities: [EntityID] = []
    public private(set) var shown: [NavObstacle] = []

    public init() {}

    public var isShowing: Bool { !entities.isEmpty }

    /// Replaces the boxes on screen; the same boxes as last time cost
    /// nothing.
    public func show(_ obstacles: [NavObstacle], color: Color = Color(red: 0.62, green: 0.6, blue: 0.56), opacity: Double = 1) {
        if isShowing, obstacles == shown { return }
        clear()
        for (index, box) in obstacles.enumerated() {
            let entity = createEntity()
            setEntityName(entityId: entity, name: "Obstacle \(index)")
            setEntityMeshDirect(entityId: entity, meshes: BasicPrimitives.createCube(extent: 1), assetName: "obstacle\(index)")
            updateMaterialColor(entityId: entity, color: color.opacity(opacity))
            scaleTo(entityId: entity, scale: box.size)
            rotateTo(entityId: entity, rotation: simd_quatf(angle: box.yaw, axis: simd_float3(0, 1, 0)))
            translateTo(entityId: entity, position: box.center)
            entities.append(entity)
        }
        shown = obstacles
    }

    public func clear() {
        for entity in entities {
            destroyEntity(entityId: entity)
        }
        entities = []
        shown = []
    }
}

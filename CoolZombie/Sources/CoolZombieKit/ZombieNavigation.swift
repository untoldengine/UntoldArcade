//
//  ZombieNavigation.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

/// A box the zombie must walk around — a wall, a crate, a table — in world
/// metres, turned `yaw` radians about the vertical axis (zero = axis
/// aligned). Navigation is planar (XZ); the height matters for rendering
/// and for whether a wall is tall enough to lean on.
public struct NavObstacle: Sendable, Equatable, Codable {
    public var center: simd_float3
    public var size: simd_float3
    public var yaw: Float

    public init(center: simd_float3, size: simd_float3, yaw: Float = 0) {
        self.center = center
        self.size = simd_abs(size)
        self.yaw = yaw
    }

    /// An axis-aligned box from its corners.
    public init(min: simd_float3, max: simd_float3) {
        let lo = simd_min(min, max), hi = simd_max(min, max)
        self.init(center: (lo + hi) / 2, size: hi - lo)
    }

    /// Axis-aligned bounds; exact only for an unrotated box.
    public var min: simd_float3 { center - size / 2 }
    public var max: simd_float3 { center + size / 2 }

    /// The box's local X axis on the ground plane (its length direction).
    public var alongAxis: simd_float2 { simd_float2(cos(yaw), -sin(yaw)) }

    /// True when the ground point lies inside the box grown by `margin`
    /// on every side.
    public func contains(_ point: simd_float2, margin: Float = 0) -> Bool {
        let local = toLocal(point)
        let half = simd_float2(size.x, size.z) / 2 + margin
        return local.x > -half.x && local.x < half.x && local.y > -half.y && local.y < half.y
    }

    /// The box's four ground-plane corners (world XZ), in order around it.
    public var footprintCorners: [simd_float2] {
        let half = simd_float2(size.x, size.z) / 2
        return [simd_float2(-half.x, -half.y), simd_float2(half.x, -half.y),
                simd_float2(half.x, half.y), simd_float2(-half.x, half.y)].map(toWorld)
    }

    /// World XZ -> the box's frame (centre at the origin, unrotated).
    public func toLocal(_ point: simd_float2) -> simd_float2 {
        NavObstacle.rotate(point - simd_float2(center.x, center.z), by: -yaw)
    }

    public func toWorld(_ local: simd_float2) -> simd_float2 {
        NavObstacle.rotate(local, by: yaw) + simd_float2(center.x, center.z)
    }

    /// Rotates a ground-plane direction by `yaw` (a right-handed turn about
    /// the vertical axis).
    public func toWorldDirection(_ local: simd_float2) -> simd_float2 { NavObstacle.rotate(local, by: yaw) }
    public func toLocalDirection(_ world: simd_float2) -> simd_float2 { NavObstacle.rotate(world, by: -yaw) }

    static func rotate(_ v: simd_float2, by angle: Float) -> simd_float2 {
        let c = cos(angle), s = sin(angle)
        return simd_float2(v.x * c + v.y * s, -v.x * s + v.y * c)
    }
}

/// A steering route: `waypoints` are world points to reach in order (the
/// first is the immediate goal), `length` the distance along them.
public struct NavRoute: Sendable, Equatable {
    public var waypoints: [simd_float3]
    public var length: Float
    /// The destination is in a straight, clear line.
    public var direct: Bool
    /// A path exists; when false the route is the straight line anyway.
    public var reachable: Bool

    public var next: simd_float3? { waypoints.first }
}

/// The nearest obstacle a straight line enters: where it enters and the
/// face it enters through (normal pointing back toward the start).
public struct NavHit: Sendable, Equatable {
    public var obstacle: NavObstacle
    public var point: simd_float3
    public var normal: simd_float3
    public var distance: Float
}

/// A saved set of obstacles — a room captured on the headset, replayed in
/// the Mac sandbox or the simulator.
public struct NavLayoutFile: Codable, Sendable, Equatable {
    public var name: String
    public var created: Date
    /// World height of the floor the obstacles stand on.
    public var floor: Float
    public var obstacles: [NavObstacle]

    public init(name: String, obstacles: [NavObstacle], floor: Float = 0, created: Date = Date()) {
        self.name = name
        self.created = created
        self.floor = floor
        self.obstacles = obstacles
    }

    // Files written before the floor was recorded stand on zero.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        created = try container.decode(Date.self, forKey: .created)
        floor = try container.decodeIfPresent(Float.self, forKey: .floor) ?? 0
        obstacles = try container.decode([NavObstacle].self, forKey: .obstacles)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> NavLayoutFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NavLayoutFile.self, from: Data(contentsOf: url))
    }
}

/// Planar path planning around obstacles: A* on a cell grid with every
/// obstacle inflated by the character's radius, then string pulling so the
/// steering goal is the farthest waypoint in a straight clear line. Pure
/// geometry, no engine: the chase feeds the next waypoint to motion
/// matching as its goal direction and the route length as its distance.
public struct ZombieNavigator: Sendable {
    public let obstacles: [NavObstacle]
    public let boundsMin: simd_float2
    public let boundsMax: simd_float2
    public let cellSize: Float
    public let radius: Float

    private let columns: Int
    private let rows: Int
    private let blocked: [Bool]

    /// - Parameters:
    ///   - radius: how far the character's centre keeps from every obstacle.
    ///   - cellSize: grid resolution; a quarter metre is plenty for furniture.
    public init(obstacles: [NavObstacle],
                boundsMin: simd_float2 = simd_float2(-8, -8), boundsMax: simd_float2 = simd_float2(8, 8),
                cellSize: Float = 0.25, radius: Float = 0.4)
    {
        self.obstacles = obstacles
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.cellSize = cellSize
        self.radius = radius
        columns = max(1, Int(((boundsMax.x - boundsMin.x) / cellSize).rounded(.up)))
        rows = max(1, Int(((boundsMax.y - boundsMin.y) / cellSize).rounded(.up)))
        // A cell is blocked when its centre lies within an obstacle inflated
        // by the radius plus half a cell, so no cell touching one is walkable.
        let inflate = radius + cellSize / 2
        var blocked = [Bool](repeating: false, count: columns * rows)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let center = simd_float2(boundsMin.x + (Float(column) + 0.5) * cellSize,
                                         boundsMin.y + (Float(row) + 0.5) * cellSize)
                for box in obstacles where ZombieNavigator.contains(box, center, margin: inflate) {
                    blocked[row * columns + column] = true
                    break
                }
            }
        }
        self.blocked = blocked
    }

    /// A grid extent holding every obstacle and every one of `points` with
    /// `padding` to spare, and never smaller than `minimumHalfExtent` each
    /// way from the origin: a real room is not centred on the origin, and
    /// a house is wider than the sandbox's arena.
    public static func bounds(around obstacles: [NavObstacle], including points: [simd_float2] = [],
                              padding: Float = 3, minimumHalfExtent: Float = 8) -> (min: simd_float2, max: simd_float2)
    {
        var lo = simd_float2(repeating: -minimumHalfExtent)
        var hi = simd_float2(repeating: minimumHalfExtent)
        for corner in obstacles.flatMap(\.footprintCorners) + points {
            lo = simd_min(lo, corner - padding)
            hi = simd_max(hi, corner + padding)
        }
        return (lo, hi)
    }

    // MARK: - Queries

    /// True when the segment stays clear of every inflated obstacle.
    public func isClear(from: simd_float3, to: simd_float3) -> Bool {
        isClear(from: simd_float2(from.x, from.z), to: simd_float2(to.x, to.z))
    }

    public func isClear(from a: simd_float2, to b: simd_float2) -> Bool {
        let margin = radius - cellSize * 0.1 // grazing a corner is not a hit
        for box in obstacles where ZombieNavigator.entry(box, a, b, margin: margin) != nil {
            return false
        }
        return true
    }

    /// The first obstacle (not inflated) the segment runs into, if any.
    public func firstHit(from: simd_float3, to: simd_float3) -> NavHit? {
        let a = simd_float2(from.x, from.z), b = simd_float2(to.x, to.z)
        var best: (t: Float, normal: simd_float2, obstacle: NavObstacle)?
        for box in obstacles {
            if let hit = ZombieNavigator.entry(box, a, b, margin: 0), best == nil || hit.t < best!.t {
                best = (hit.t, hit.normal, box)
            }
        }
        guard let best else { return nil }
        let point = a + (b - a) * best.t
        return NavHit(obstacle: best.obstacle,
                      point: simd_float3(point.x, from.y, point.y),
                      normal: simd_float3(best.normal.x, 0, best.normal.y),
                      distance: simd_distance(a, b) * best.t)
    }

    /// Moves a position out of any inflated obstacle it has ended up in
    /// (root motion follows the clip, not the walls), along the shortest
    /// axis; corners take a second pass.
    public func pushOut(_ position: simd_float3) -> simd_float3 {
        pushOut(position, margin: radius)
    }

    /// The same, keeping only `margin` metres from the obstacles' faces
    /// (the contact approach stands closer to a wall than the radius).
    public func pushOut(_ position: simd_float3, margin: Float) -> simd_float3 {
        var p = simd_float2(position.x, position.z)
        for _ in 0 ..< 2 {
            for box in obstacles {
                let local = box.toLocal(p)
                let half = simd_float2(box.size.x, box.size.z) / 2 + margin
                guard abs(local.x) < half.x, abs(local.y) < half.y else { continue }
                let gaps = [(half.x - local.x, simd_float2(half.x, local.y)), (half.x + local.x, simd_float2(-half.x, local.y)),
                            (half.y - local.y, simd_float2(local.x, half.y)), (half.y + local.y, simd_float2(local.x, -half.y))]
                p = box.toWorld(gaps.min { $0.0 < $1.0 }!.1)
            }
        }
        return simd_float3(p.x, position.y, p.y)
    }

    /// A spawn point for the character relative to the player: `distance`
    /// from `origin` along `facing` when the way is clear, else the last
    /// clear point along that ray; and if that leaves it closer than
    /// `minimum`, the same along the other three directions, the farthest
    /// winning. The origin may sit in a wall's inflated zone (a player
    /// with their back to it) or even inside a box (the sandbox's cube in
    /// its wall): the first stretch of the ray is allowed to be blocked,
    /// but once clear the ray stops at the first thing it meets — never
    /// through a wall.
    public func spawnPoint(from origin: simd_float2, facing: simd_float2, distance: Float, minimum: Float = 1.5) -> simd_float2 {
        let forward = simd_length(facing) > 1e-4 ? simd_normalize(facing) : simd_float2(0, -1)
        let directions = [forward, simd_float2(forward.y, -forward.x), -forward, simd_float2(-forward.y, forward.x)]
        var best = origin + forward * min(minimum, distance)
        var bestReach: Float = 0
        for (index, direction) in directions.enumerated() {
            let reach = clearReach(from: origin, along: direction, upTo: distance)
            if reach > bestReach {
                bestReach = reach
                best = origin + direction * reach
            }
            if index == 0, reach >= minimum { break }
        }
        return best
    }

    /// How far a ray from `origin` stays clear, up to `limit`, probing
    /// every half cell. Blocked probes before the first clear one are
    /// skipped for up to `leadIn` metres.
    func clearReach(from origin: simd_float2, along direction: simd_float2, upTo limit: Float, leadIn: Float = 1.2) -> Float {
        let step = cellSize / 2
        var reach: Float = 0
        var start: simd_float2?
        var probe = step
        while probe <= limit + 1e-4 {
            let point = origin + direction * probe
            let lifted = simd_float3(point.x, 0, point.y)
            let free = pushOut(lifted) == lifted
            if let start {
                guard free, isClear(from: start, to: point) else { break }
                reach = probe
            } else if free {
                start = point
                reach = probe
            } else if probe > leadIn {
                break
            }
            probe += step
        }
        return reach
    }

    /// The route from `from` to `to`. Straight when the line is clear; else
    /// the string-pulled grid path; else (no path) the straight line,
    /// flagged unreachable so the caller can still steer at the target.
    public func route(from: simd_float3, to: simd_float3) -> NavRoute {
        let a = simd_float2(from.x, from.z), b = simd_float2(to.x, to.z)
        if isClear(from: a, to: b) {
            return NavRoute(waypoints: [to], length: simd_distance(a, b), direct: true, reachable: true)
        }
        guard let start = nearestFreeCell(to: a), let goal = nearestFreeCell(to: b),
              let cells = astar(from: start, to: goal)
        else {
            return NavRoute(waypoints: [to], length: simd_distance(a, b), direct: false, reachable: false)
        }
        // String pulling over the cell centres, ending at the exact target.
        var points = cells.dropFirst().map(center(of:))
        points.append(b)
        var pulled: [simd_float2] = []
        var anchor = a
        var index = 0
        while index < points.count {
            var farthest = index
            var probe = index + 1
            while probe < points.count, isClear(from: anchor, to: points[probe]) {
                farthest = probe; probe += 1
            }
            pulled.append(points[farthest])
            anchor = points[farthest]
            index = farthest + 1
        }
        var length: Float = 0
        var previous = a
        for point in pulled { length += simd_distance(previous, point); previous = point }
        let waypoints = pulled.map { simd_float3($0.x, to.y, $0.y) }
        return NavRoute(waypoints: waypoints, length: length, direct: false, reachable: true)
    }

    // MARK: - Oriented box tests

    private static func contains(_ box: NavObstacle, _ point: simd_float2, margin: Float) -> Bool {
        box.contains(point, margin: margin)
    }

    /// Slab test in the box's frame: the entry parameter along a-b and the
    /// world normal of the face entered (a start inside enters at t = 0
    /// through its nearest face).
    private static func entry(_ box: NavObstacle, _ a: simd_float2, _ b: simd_float2, margin: Float) -> (t: Float, normal: simd_float2)? {
        let half = simd_float2(box.size.x, box.size.z) / 2 + margin
        guard half.x > 0, half.y > 0 else { return nil }
        let la = box.toLocal(a), lb = box.toLocal(b)
        let d = lb - la
        var tmin: Float = 0, tmax: Float = 1
        var normal = simd_float2(0, 0)
        for axis in 0 ..< 2 {
            let origin = axis == 0 ? la.x : la.y, delta = axis == 0 ? d.x : d.y
            let extent = axis == 0 ? half.x : half.y
            if abs(delta) < 1e-6 {
                if origin <= -extent || origin >= extent { return nil }
            } else {
                var t1 = (-extent - origin) / delta, t2 = (extent - origin) / delta
                var n = axis == 0 ? simd_float2(-1, 0) : simd_float2(0, -1) // entering through the low face
                if t1 > t2 { swap(&t1, &t2); n = -n }
                if t1 > tmin { tmin = t1; normal = n }
                tmax = Swift.min(tmax, t2)
                if tmin > tmax { return nil }
            }
        }
        if normal == simd_float2(0, 0) {
            // Started inside: the nearest face.
            let gaps = [(la.x + half.x, simd_float2(-1, 0)), (half.x - la.x, simd_float2(1, 0)),
                        (la.y + half.y, simd_float2(0, -1)), (half.y - la.y, simd_float2(0, 1))]
            normal = gaps.min { $0.0 < $1.0 }!.1
        }
        return (tmin, box.toWorldDirection(normal))
    }

    // MARK: - Grid

    private struct Cell: Hashable { var column: Int; var row: Int }

    private func cell(at point: simd_float2) -> Cell {
        Cell(column: Swift.min(columns - 1, Swift.max(0, Int((point.x - boundsMin.x) / cellSize))),
             row: Swift.min(rows - 1, Swift.max(0, Int((point.y - boundsMin.y) / cellSize))))
    }

    private func center(of cell: Cell) -> simd_float2 {
        simd_float2(boundsMin.x + (Float(cell.column) + 0.5) * cellSize, boundsMin.y + (Float(cell.row) + 0.5) * cellSize)
    }

    private func isBlocked(_ cell: Cell) -> Bool {
        cell.column < 0 || cell.row < 0 || cell.column >= columns || cell.row >= rows || blocked[cell.row * columns + cell.column]
    }

    /// The cell under the point, or the nearest walkable one within a few
    /// cells (a character or target standing against a wall is inside the
    /// inflated zone).
    private func nearestFreeCell(to point: simd_float2) -> Cell? {
        let origin = cell(at: point)
        if !isBlocked(origin) { return origin }
        for ring in 1 ... 6 {
            var best: Cell?
            var bestDistance = Float.greatestFiniteMagnitude
            for dr in -ring ... ring {
                for dc in -ring ... ring where abs(dr) == ring || abs(dc) == ring {
                    let candidate = Cell(column: origin.column + dc, row: origin.row + dr)
                    guard !isBlocked(candidate) else { continue }
                    let distance = simd_distance(center(of: candidate), point)
                    if distance < bestDistance { bestDistance = distance; best = candidate }
                }
            }
            if let best { return best }
        }
        return nil
    }

    /// A* over eight neighbours, no corner cutting; returns the cells from
    /// start to goal inclusive.
    private func astar(from start: Cell, to goal: Cell) -> [Cell]? {
        func heuristic(_ c: Cell) -> Float {
            let dx = Float(abs(c.column - goal.column)), dy = Float(abs(c.row - goal.row))
            return Swift.max(dx, dy) + (Float(2).squareRoot() - 1) * Swift.min(dx, dy)
        }
        var open: [(f: Float, cell: Cell)] = [(heuristic(start), start)]
        var cameFrom: [Cell: Cell] = [:]
        var gScore: [Cell: Float] = [start: 0]
        var closed = Set<Cell>()
        let steps: [(Int, Int, Float)] = [(1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1),
                                         (1, 1, 1.41421356), (1, -1, 1.41421356), (-1, 1, 1.41421356), (-1, -1, 1.41421356)]
        while !open.isEmpty {
            // Small grids: a linear pick beats a heap's bookkeeping.
            var bestIndex = 0
            for i in 1 ..< open.count where open[i].f < open[bestIndex].f { bestIndex = i }
            let current = open.remove(at: bestIndex).cell
            if current == goal {
                var path = [current]
                var cursor = current
                while let previous = cameFrom[cursor] { path.append(previous); cursor = previous }
                return path.reversed()
            }
            if !closed.insert(current).inserted { continue }
            let g = gScore[current] ?? .greatestFiniteMagnitude
            for (dc, dr, cost) in steps {
                let next = Cell(column: current.column + dc, row: current.row + dr)
                if isBlocked(next) || closed.contains(next) { continue }
                if dc != 0, dr != 0,
                   isBlocked(Cell(column: current.column + dc, row: current.row)) || isBlocked(Cell(column: current.column, row: current.row + dr))
                {
                    continue // no squeezing diagonally between two blocked cells
                }
                let tentative = g + cost
                if tentative < gScore[next] ?? .greatestFiniteMagnitude {
                    gScore[next] = tentative
                    cameFrom[next] = current
                    open.append((tentative + heuristic(next), next))
                }
            }
        }
        return nil
    }
}

//
//  ZombieSpatialSession.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

#if os(visionOS)
    import ARKit

    /// visionOS adapter running the demo's own ARKitSession: world tracking
    /// for the player's head, plane detection for the room — the real
    /// floor the zombie stands on, and the walls and furniture it routes
    /// around (`ZombieRoom` turns the surfaces into obstacles) — scene
    /// reconstruction for whatever has no plane, rasterized per mesh
    /// anchor into an occupancy grid at walking height — and room
    /// tracking, so that planes and meshes seen through an open door stay
    /// out of the set once ARKit knows which room the player is in. The world
    /// origin's height is only the system's estimate of the floor and can
    /// sit a centimetre or two off; the detected floor plane is what the
    /// zombie should stand on. Fresh providers on every start: ARKit
    /// providers are one-shot.
    public final class ZombieSpatialSession: @unchecked Sendable {
        private let session = ARKitSession()
        private let lock = NSLock()
        private var runTask: Task<Void, Never>?
        private var worldTracking: WorldTrackingProvider?
        /// Every detected surface by anchor id, and a count of updates so a
        /// caller can tell whether anything changed since it last looked.
        private var surfaces: [UUID: RoomSurface] = [:]
        private var surfacesVersion = 0
        private var meshTask: Task<Void, Never>?
        /// The scan, one occupancy piece per mesh anchor, and a version.
        private var scanPieces: [UUID: RoomOccupancy] = [:]
        /// Vertices of the faces the scene mesh classifies as floor, per
        /// anchor: a second opinion on the floor height, independent of the
        /// plane detector's.
        private var floorPoints: [UUID: [simd_float3]] = [:]
        private var scanVersion = 0
        private var mergedScan: (occupancy: RoomOccupancy, version: Int)?
        private var roomTask: Task<Void, Never>?
        /// The anchors of the room the player is in, once room tracking
        /// has one; nil means everything counts.
        private var currentRoomPlanes: Set<UUID>?
        private var currentRoomMeshes: Set<UUID>?
        private let rules = ZombieRoom.Rules()

        public init() {}

        public static var isSupported: Bool {
            WorldTrackingProvider.isSupported
        }

        public static var isFloorDetectionSupported: Bool {
            PlaneDetectionProvider.isSupported
        }

        public static var isScanSupported: Bool {
            SceneReconstructionProvider.isSupported
        }

        public func start() {
            lock.withLock {
                guard runTask == nil, WorldTrackingProvider.isSupported else { return }
                let provider = WorldTrackingProvider()
                worldTracking = provider
                let planes = PlaneDetectionProvider.isSupported
                    ? PlaneDetectionProvider(alignments: [.horizontal, .vertical]) : nil
                let scan = SceneReconstructionProvider.isSupported ? SceneReconstructionProvider() : nil
                let rooms = RoomTrackingProvider.isSupported ? RoomTrackingProvider() : nil
                runTask = Task { [weak self] in
                    guard let self else { return }
                    var providers: [any DataProvider] = [provider]
                    if let planes { providers.append(planes) }
                    if let scan { providers.append(scan) }
                    if let rooms { providers.append(rooms) }
                    do {
                        try await session.run(providers)
                    } catch {
                        print("CoolZombie: ARKit session failed to run — \(error)")
                        lock.withLock { worldTracking = nil }
                        return
                    }
                    if let scan {
                        let task = Task { [weak self] in
                            for await update in scan.anchorUpdates {
                                guard let self, !Task.isCancelled else { break }
                                handle(meshUpdate: update)
                            }
                        }
                        lock.withLock { meshTask = task }
                    }
                    if let rooms {
                        let task = Task { [weak self] in
                            for await update in rooms.anchorUpdates {
                                guard let self, !Task.isCancelled else { break }
                                handle(roomUpdate: update)
                            }
                        }
                        lock.withLock { roomTask = task }
                    }
                    guard let planes else { return }
                    for await update in planes.anchorUpdates {
                        guard !Task.isCancelled else { break }
                        handle(planeUpdate: update)
                    }
                }
            }
        }

        public func stop() {
            let tasks = lock.withLock { () -> [Task<Void, Never>?] in
                let tasks = [runTask, meshTask, roomTask]
                runTask = nil
                meshTask = nil
                roomTask = nil
                worldTracking = nil
                surfaces.removeAll()
                surfacesVersion += 1
                scanPieces.removeAll()
                mergedScan = nil
                scanVersion += 1
                currentRoomPlanes = nil
                currentRoomMeshes = nil
                return tasks
            }
            for task in tasks { task?.cancel() }
            session.stop()
        }

        /// The player's head position in world space, or nil until tracking
        /// runs.
        public func headPosition() -> simd_float3? {
            headPose()?.position
        }

        /// The player's head: where it is and the way it looks (the
        /// device's -Z), or nil until tracking runs. The world origin is
        /// wherever tracking last started or was recentred — not where the
        /// app opened — so anything placed "in front of the player" must
        /// start from this, not from the origin.
        public func headPose() -> (position: simd_float3, forward: simd_float3)? {
            let provider = lock.withLock { worldTracking }
            guard let provider, provider.state == .running,
                  let anchor = provider.queryDeviceAnchor(atTimestamp: ProcessInfo.processInfo.systemUptime)
            else { return nil }
            let transform = anchor.originFromAnchorTransform
            return (simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
                    -simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        }

        /// World height of the largest detected floor plane, or nil until
        /// one has been classified.
        public func floorHeight() -> Float? {
            floorPlane()?.center.y
        }

        /// The largest detected floor plane itself — the one `floorHeight`
        /// reads — for showing where the headset thinks the floor is.
        public func floorPlane() -> RoomSurface? {
            lock.withLock {
                surfaces.values.filter { $0.kind == .floor }.max { $0.area < $1.area }
            }
        }

        /// Every surface detected so far in the player's room, with a
        /// version that changes on every addition, refinement or removal.
        public func roomSurfaces() -> (surfaces: [RoomSurface], version: Int) {
            lock.withLock {
                let inRoom = surfaces.filter { currentRoomPlanes?.contains($0.key) ?? true }
                return (Array(inRoom.values), surfacesVersion)
            }
        }

        /// The scan of the player's room so far as one occupancy grid (nil
        /// before any mesh has arrived), with a version that changes on
        /// every mesh update.
        public func roomScan() -> (occupancy: RoomOccupancy?, version: Int) {
            lock.withLock {
                let inRoom = scanPieces.filter { currentRoomMeshes?.contains($0.key) ?? true }
                guard !inRoom.isEmpty else { return (nil, scanVersion) }
                if let mergedScan, mergedScan.version == scanVersion {
                    return (mergedScan.occupancy, scanVersion)
                }
                let merged = RoomOccupancy.merged(Array(inRoom.values), cellSize: rules.occupancyCellSize)
                mergedScan = (merged, scanVersion)
                return (merged, scanVersion)
            }
        }

        /// Keeps the anchor lists of the room the player is in; both
        /// versions move so the callers re-read.
        private func handle(roomUpdate update: AnchorUpdate<RoomAnchor>) {
            let anchor = update.anchor
            lock.withLock {
                switch update.event {
                case .removed:
                    guard anchor.isCurrentRoom else { return }
                    currentRoomPlanes = nil
                    currentRoomMeshes = nil
                case .added, .updated:
                    guard anchor.isCurrentRoom else { return }
                    currentRoomPlanes = Set(anchor.planeAnchorIDs)
                    currentRoomMeshes = Set(anchor.meshAnchorIDs)
                }
                surfacesVersion += 1
                scanVersion += 1
                mergedScan = nil
            }
        }

        /// Rasterizes the anchor's mesh into its occupancy piece. The band
        /// of heights that count follows the floor known at the time; the
        /// floor barely moves once detected.
        private func handle(meshUpdate update: AnchorUpdate<MeshAnchor>) {
            let anchor = update.anchor
            switch update.event {
            case .removed:
                lock.withLock {
                    scanPieces.removeValue(forKey: anchor.id)
                    floorPoints.removeValue(forKey: anchor.id)
                    scanVersion += 1
                }
            case .added, .updated:
                let floor = floorHeight() ?? 0
                let piece = RoomOccupancy(anchor, lowest: floor + rules.minimumFurnitureTop,
                                          highest: floor + rules.maximumFurnitureTop, cellSize: rules.occupancyCellSize)
                let points = Self.floorVertices(of: anchor, cap: 3000)
                lock.withLock {
                    scanPieces[anchor.id] = piece
                    floorPoints[anchor.id] = points
                    scanVersion += 1
                }
            }
        }

        /// The floor's height from the scene mesh: the median height of the
        /// floor-classified mesh vertices within `radius` of `point`, or nil
        /// with fewer than twenty of them. The plane detector's height and
        /// this one disagree by the plane's bias, which is what a sole that
        /// floats or sinks a centimetre on a right-looking plane is made of.
        public func meshFloorHeight(near point: simd_float3, radius: Float = 1.0) -> Float? {
            let heights = lock.withLock { floorPoints.values.flatMap { $0 } }
                .filter { simd_distance(simd_float2($0.x, $0.z), simd_float2(point.x, point.z)) <= radius }
                .map(\.y)
            guard heights.count >= 20 else { return nil }
            return heights.sorted()[heights.count / 2]
        }

        /// World positions of the vertices of the faces classified as floor,
        /// at most `cap` faces sampled evenly.
        private static func floorVertices(of anchor: MeshAnchor, cap: Int) -> [simd_float3] {
            let geometry = anchor.geometry
            guard let classifications = geometry.classifications, classifications.format == .uchar,
                  geometry.faces.primitive == .triangle, geometry.vertices.format == .float3, geometry.faces.count > 0
            else { return [] }
            let vertices = geometry.vertices, faces = geometry.faces
            let transform = anchor.originFromAnchorTransform
            let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
            let indexBase = faces.buffer.contents()
            let classBase = classifications.buffer.contents().advanced(by: classifications.offset)
            func vertex(_ index: Int) -> simd_float3 {
                let floats = vertexBase.advanced(by: index * vertices.stride).assumingMemoryBound(to: Float.self)
                let world = transform * simd_float4(floats[0], floats[1], floats[2], 1)
                return simd_float3(world.x, world.y, world.z)
            }
            func index(_ position: Int) -> Int {
                faces.bytesPerIndex == 4
                    ? Int(indexBase.advanced(by: position * 4).assumingMemoryBound(to: UInt32.self).pointee)
                    : Int(indexBase.advanced(by: position * 2).assumingMemoryBound(to: UInt16.self).pointee)
            }
            let step = max(1, faces.count / cap)
            var points: [simd_float3] = []
            for face in stride(from: 0, to: faces.count, by: step) {
                let raw = Int(classBase.advanced(by: face * classifications.stride).assumingMemoryBound(to: UInt8.self).pointee)
                guard MeshAnchor.MeshClassification(rawValue: raw) == .floor else { continue }
                points.append(vertex(index(face * 3)))
                points.append(vertex(index(face * 3 + 1)))
                points.append(vertex(index(face * 3 + 2)))
            }
            return points
        }

        private func handle(planeUpdate update: AnchorUpdate<PlaneAnchor>) {
            let anchor = update.anchor
            lock.withLock {
                switch update.event {
                case .removed:
                    surfaces.removeValue(forKey: anchor.id)
                case .added, .updated:
                    surfaces[anchor.id] = RoomSurface(anchor)
                }
                surfacesVersion += 1
            }
        }
    }

    extension RoomOccupancy {
        /// The anchor's triangles, in world space, marked into a fresh grid.
        init(_ anchor: MeshAnchor, lowest: Float, highest: Float, cellSize: Float) {
            self.init(cellSize: cellSize)
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            let faces = geometry.faces
            guard faces.primitive == .triangle, vertices.format == .float3, faces.count > 0 else { return }
            let transform = anchor.originFromAnchorTransform
            let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
            let indexBase = faces.buffer.contents()
            func vertex(_ index: Int) -> simd_float3 {
                let floats = vertexBase.advanced(by: index * vertices.stride).assumingMemoryBound(to: Float.self)
                let world = transform * simd_float4(floats[0], floats[1], floats[2], 1)
                return simd_float3(world.x, world.y, world.z)
            }
            func index(_ position: Int) -> Int {
                faces.bytesPerIndex == 4
                    ? Int(indexBase.advanced(by: position * 4).assumingMemoryBound(to: UInt32.self).pointee)
                    : Int(indexBase.advanced(by: position * 2).assumingMemoryBound(to: UInt16.self).pointee)
            }
            for face in 0 ..< faces.count {
                mark(vertex(index(face * 3)), vertex(index(face * 3 + 1)), vertex(index(face * 3 + 2)),
                     lowest: lowest, highest: highest)
            }
        }
    }

    extension RoomSurface {
        /// The plane's extent in world space: the extent transform's
        /// origin is its centre, its X and Y axes span the width and
        /// height, +Z is the normal.
        init(_ anchor: PlaneAnchor) {
            let extent = anchor.geometry.extent
            let transform = anchor.originFromAnchorTransform * extent.anchorFromExtentTransform
            let kind: Kind = switch anchor.classification {
            case .wall: .wall
            case .door: .door
            case .window: .window
            case .floor: .floor
            case .ceiling: .ceiling
            case .table: .table
            case .seat: .seat
            default: .unknown
            }
            let orientation: Orientation = switch anchor.alignment {
            case .horizontal: .horizontal
            case .vertical: .vertical
            default: .slanted
            }
            self.init(
                id: anchor.id, kind: kind, orientation: orientation,
                center: simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
                axisU: simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                axisV: simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                width: extent.width, height: extent.height
            )
        }
    }
#endif

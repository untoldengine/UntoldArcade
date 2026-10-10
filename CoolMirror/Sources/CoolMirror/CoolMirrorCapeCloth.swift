//
//  CoolMirrorCapeCloth.swift
//  CoolMirror
//
//  The cape's cloth topology, built from a cape mesh's rest geometry and
//  skin: pure and testable without a GPU or a physics world. Welds the
//  mesh's vertices into particles (by position and normal, so a
//  double-sided cape keeps its two layers instead of collapsing into
//  duplicate, opposite triangles that break bend constraints), drops
//  degenerate and duplicate faces, skins every particle to the current
//  joints for the starting shape, and picks the collar particles to pin.
//  `coarsen(spacing:)` then replaces the particles with a sparser set
//  (one per cell of the rest-space grid) and binds every mesh vertex to
//  the coarse face it lies on, so the solver runs on a few hundred
//  particles while the artist's mesh keeps every vertex.
//

import Foundation
import simd

struct CoolMirrorCapeCloth {
    struct JointFrame {
        var position: simd_float3
        var rotation: simd_quatf
    }

    struct PinBinding {
        var joint: Int
        var weight: Float
        /// Rest offset in the joint's rest frame.
        var offset: simd_float3
    }

    /// How a mesh vertex follows the particles: a point on a particle
    /// triangle (barycentric weights) plus an offset in that triangle's
    /// frame (its first edge, the in-plane perpendicular, the normal). A
    /// vertex that is a particle itself binds to it alone.
    struct VertexBinding {
        var particles: SIMD3<UInt32>
        var weights: simd_float3
        var local: simd_float3
        /// −1 for a vertex on the back of the sheet (a double-sided cape).
        var normalSign: Float
    }

    struct Stats: CustomStringConvertible {
        var meshVertices = 0
        var fineParticles = 0
        var particles = 0
        var facesIn = 0
        var facesDuplicate = 0
        var facesDegenerate = 0
        var facesFolded = 0
        var particlesOrphaned = 0
        var faces = 0
        var pinned = 0
        var nonManifoldEdges = 0
        var minEdge: Float = .greatestFiniteMagnitude
        var maxEdge: Float = 0

        var bindingError: Float = 0

        var description: String {
            let coarse = fineParticles == particles ? "" : String(format: " (coarsened from %d, %d folded faces and %d orphaned particles dropped, binding error %.2f mm)", fineParticles, facesFolded, particlesOrphaned, bindingError * 1000)
            return String(format: "%d mesh vertices → %d particles%@, %d faces (%d duplicate, %d degenerate dropped), %d pinned, %d non-manifold edges, edges %.1f–%.1f mm",
                          meshVertices, particles, coarse, faces, facesDuplicate, facesDegenerate, pinned, nonManifoldEdges, minEdge * 1000, maxEdge * 1000)
        }
    }

    /// Particle rest positions (the space of the input positions).
    var particleRest: [simd_float3]
    /// Where each particle starts, in world space (skinned to the current pose).
    var startWorld: [simd_float3]
    /// Rest normals of the particles (the welded vertices' own).
    var particleNormals: [simd_float3]
    /// Binding of every vertex in `vertexIds`.
    var vertexBindings: [VertexBinding]
    /// The welded mesh vertex (before any coarsening) of every vertex in
    /// `vertexIds`, and each welded vertex's neighbours over the mesh
    /// edges: the mesh's own connectivity, for spreading a per-vertex
    /// correction over its surroundings.
    var meshVertexOfVertex: [UInt32]
    var meshNeighbours: [[UInt32]]
    /// The mesh vertices of the cape slot (sorted).
    var vertexIds: [UInt32]
    var faces: [SIMD3<UInt32>]
    var inverseMasses: [Float]
    var pinned: [UInt32]
    var pinBindings: [[PinBinding]]
    var stats: Stats
    private var restJoints: [JointFrame]
    private var particleMass: Float

    static let weldTolerance: Float = 1e-4
    /// Vertices closer than the tolerance still stay apart when their
    /// normals disagree by more than this (a double-sided sheet's layers).
    static let weldNormalDot: Float = 0.5
    static let degenerateArea: Float = 1e-9

    /// `positions`/`normals`/`jointIndices`/`jointWeights` are per mesh
    /// vertex at rest; `triangles` index them; `restJoints` are the
    /// skeleton's rest frames in the same space as `positions`, `joints`
    /// its current frames in the space the cloth simulates in (world);
    /// `collarJoints` the joints a pinned vertex must be skinned to by at
    /// least `collarWeight`. Rest data in world units (the entity's
    /// transform applied) keeps the pin offsets in metres.
    init(
        positions: [simd_float3], normals: [simd_float3], triangles: [UInt32],
        jointIndices: [simd_ushort4], jointWeights: [simd_float4],
        restJoints: [JointFrame], joints: [JointFrame], collarJoints: Set<Int>, collarWeight: Float,
        particleMass: Float
    ) {
        var stats = Stats()
        stats.meshVertices = positions.count
        let vertexIds = Array(Set(triangles)).sorted()

        // Weld.
        var particleOfMeshVertex: [UInt32: UInt32] = [:]
        var particleRest: [simd_float3] = []
        var particleNormal: [simd_float3] = []
        var particleSource: [Int] = []
        var buckets: [SIMD3<Int32>: [UInt32]] = [:]
        let cell: Float = 1e-3
        var particleOfVertex: [UInt32] = []
        particleOfVertex.reserveCapacity(vertexIds.count)
        for id in vertexIds {
            let p = positions[Int(id)]
            let n = id < normals.count ? normals[Int(id)] : simd_float3(0, 0, 1)
            let key = SIMD3<Int32>(Int32((p.x / cell).rounded()), Int32((p.y / cell).rounded()), Int32((p.z / cell).rounded()))
            var found: UInt32?
            for candidate in buckets[key, default: []]
                where simd_length(particleRest[Int(candidate)] - p) <= Self.weldTolerance
                && simd_dot(particleNormal[Int(candidate)], n) >= Self.weldNormalDot
            {
                found = candidate
                break
            }
            let particle: UInt32
            if let found {
                particle = found
            } else {
                particle = UInt32(particleRest.count)
                particleRest.append(p)
                particleNormal.append(n)
                particleSource.append(Int(id))
                buckets[key, default: []].append(particle)
            }
            particleOfMeshVertex[id] = particle
            particleOfVertex.append(particle)
        }
        stats.particles = particleRest.count

        // Faces: welded, without degenerate or duplicate ones.
        var faces: [SIMD3<UInt32>] = []
        var seen = Set<SIMD3<UInt32>>()
        var edgeUse: [SIMD2<UInt32>: Int] = [:]
        for t in stride(from: 0, to: triangles.count - 2, by: 3) {
            stats.facesIn += 1
            guard let a = particleOfMeshVertex[triangles[t]], let b = particleOfMeshVertex[triangles[t + 1]], let c = particleOfMeshVertex[triangles[t + 2]] else { continue }
            guard a != b, b != c, a != c else {
                stats.facesDegenerate += 1
                continue
            }
            let area = simd_length(simd_cross(particleRest[Int(b)] - particleRest[Int(a)], particleRest[Int(c)] - particleRest[Int(a)])) * 0.5
            guard area > Self.degenerateArea else {
                stats.facesDegenerate += 1
                continue
            }
            let key = SIMD3<UInt32>([a, b, c].sorted())
            guard seen.insert(key).inserted else {
                stats.facesDuplicate += 1
                continue
            }
            faces.append(SIMD3(a, b, c))
            for (u, v) in [(a, b), (b, c), (c, a)] {
                let e = SIMD2<UInt32>(min(u, v), max(u, v))
                edgeUse[e, default: 0] += 1
                let length = simd_length(particleRest[Int(u)] - particleRest[Int(v)])
                stats.minEdge = min(stats.minEdge, length)
                stats.maxEdge = max(stats.maxEdge, length)
            }
        }
        stats.faces = faces.count
        stats.nonManifoldEdges = edgeUse.values.filter { $0 > 2 }.count
        var neighbours = [[UInt32]](repeating: [], count: particleRest.count)
        for edge in edgeUse.keys {
            neighbours[Int(edge.x)].append(edge.y)
            neighbours[Int(edge.y)].append(edge.x)
        }

        // Skin: start shape and collar pins.
        var inverseMasses = [Float](repeating: 1 / particleMass, count: particleRest.count)
        var startWorld = particleRest
        var pinned: [UInt32] = []
        var pinBindings: [[PinBinding]] = []
        let hasSkin = jointIndices.count == positions.count && jointWeights.count == positions.count
        if hasSkin {
            for (particle, source) in particleSource.enumerated() {
                let ids = jointIndices[source]
                let weights = jointWeights[source]
                let entries: [(Int, Float)] = [(Int(ids.x), weights.x), (Int(ids.y), weights.y), (Int(ids.z), weights.z), (Int(ids.w), weights.w)]
                var bindings: [PinBinding] = []
                for (joint, weight) in entries where weight > 1e-3 && joint < restJoints.count && joint < joints.count {
                    let rest = restJoints[joint]
                    bindings.append(PinBinding(joint: joint, weight: weight, offset: rest.rotation.inverse.act(particleRest[particle] - rest.position)))
                }
                guard !bindings.isEmpty else { continue }
                var skinned = simd_float3.zero
                var total: Float = 0
                for binding in bindings {
                    let joint = joints[binding.joint]
                    skinned += binding.weight * (joint.position + joint.rotation.act(binding.offset))
                    total += binding.weight
                }
                if total > 0 {
                    startWorld[particle] = skinned / total
                }
                let collar = entries.filter { collarJoints.contains($0.0) }.reduce(Float(0)) { $0 + $1.1 }
                guard collar >= collarWeight else { continue }
                inverseMasses[particle] = 0
                pinned.append(UInt32(particle))
                pinBindings.append(bindings)
            }
        }
        if pinned.isEmpty {
            let sorted = particleRest.indices.sorted { particleRest[$0].y > particleRest[$1].y }
            for particle in sorted.prefix(max(1, particleRest.count / 10)) {
                inverseMasses[particle] = 0
                pinned.append(UInt32(particle))
                pinBindings.append([])
            }
        }
        stats.pinned = pinned.count

        stats.fineParticles = particleRest.count
        self.particleRest = particleRest
        self.startWorld = startWorld
        particleNormals = particleNormal
        vertexBindings = particleOfVertex.map { VertexBinding(particles: SIMD3(repeating: $0), weights: simd_float3(1, 0, 0), local: .zero, normalSign: 1) }
        meshVertexOfVertex = particleOfVertex
        meshNeighbours = neighbours
        self.vertexIds = vertexIds
        self.restJoints = restJoints
        self.particleMass = particleMass
        self.faces = faces
        self.inverseMasses = inverseMasses
        self.pinned = pinned
        self.pinBindings = pinBindings
        self.stats = stats
    }

    // MARK: - Coarsening

    /// Replaces the particles with one per `spacing`-sized cell of the
    /// rest-space grid (the cell's centroid, its members' mass, pinned
    /// when most of its members are) and the faces with the surviving
    /// distinct cell triangles, then binds every mesh vertex to the
    /// nearest coarse face touching its cell. A double-sided sheet's two
    /// layers fall into the same cells: one simulated layer, both drawn.
    mutating func coarsen(spacing: Float) {
        guard spacing > 0, !particleRest.isEmpty else { return }
        let fineCount = particleRest.count
        let pinnedSet = Set(pinned)
        var pinBindingOfFine: [Int: [PinBinding]] = [:]
        for (slot, particle) in pinned.enumerated() {
            pinBindingOfFine[Int(particle)] = pinBindings[slot]
        }

        // Cells → coarse particles. The grid hangs off the mesh's own
        // corner so the topology is the mesh's, wherever the character
        // stands.
        var coarseOfCell: [SIMD3<Int32>: UInt32] = [:]
        var coarseOfFine = [UInt32](repeating: 0, count: fineCount)
        var members: [[Int]] = []
        let corner = particleRest.reduce(particleRest[0]) { simd_min($0, $1) }
        for fine in 0 ..< fineCount {
            let p = (particleRest[fine] - corner) / spacing
            let key = SIMD3<Int32>(Int32(p.x.rounded(.down)), Int32(p.y.rounded(.down)), Int32(p.z.rounded(.down)))
            let coarse: UInt32
            if let existing = coarseOfCell[key] {
                coarse = existing
            } else {
                coarse = UInt32(members.count)
                coarseOfCell[key] = coarse
                members.append([])
            }
            coarseOfFine[fine] = coarse
            members[Int(coarse)].append(fine)
        }
        guard members.count < fineCount, !faces.isEmpty else { return }

        var coarseRest: [simd_float3] = []
        var coarseStart: [simd_float3] = []
        var coarseInverseMass: [Float] = []
        var coarsePinned: [UInt32] = []
        var coarsePinBindings: [[PinBinding]] = []
        for (coarse, fines) in members.enumerated() {
            let rest = fines.reduce(simd_float3.zero) { $0 + particleRest[$1] } / Float(fines.count)
            let start = fines.reduce(simd_float3.zero) { $0 + startWorld[$1] } / Float(fines.count)
            coarseRest.append(rest)
            coarseStart.append(start)
            let pinnedMembers = fines.filter { pinnedSet.contains(UInt32($0)) }
            if pinnedMembers.count * 2 >= fines.count,
               let anchor = pinnedMembers.min(by: { simd_length_squared(particleRest[$0] - rest) < simd_length_squared(particleRest[$1] - rest) }),
               let bindings = pinBindingOfFine[anchor]
            {
                // The anchor's bindings, re-offset to the centroid.
                let shifted = bindings.map { binding -> PinBinding in
                    guard binding.joint < restJoints.count else { return binding }
                    var moved = binding
                    moved.offset = binding.offset + restJoints[binding.joint].rotation.inverse.act(rest - particleRest[anchor])
                    return moved
                }
                coarseInverseMass.append(0)
                coarsePinned.append(UInt32(coarse))
                coarsePinBindings.append(shifted)
            } else {
                // One mass for every free particle: a cell holding thirty
                // welded vertices next to one holding a single vertex would
                // otherwise be a mass ratio the few solver iterations cannot
                // converge across, and the cloth stretches.
                coarseInverseMass.append(1 / particleMass)
            }
        }

        // Faces on the coarse particles.
        var coarseFaces: [SIMD3<UInt32>] = []
        var seen = Set<SIMD3<UInt32>>()
        var edgeUse: [SIMD2<UInt32>: Int] = [:]
        var facesOfCoarse = [[Int]](repeating: [], count: members.count)
        var minEdge: Float = .greatestFiniteMagnitude
        var maxEdge: Float = 0
        for face in faces {
            let a = coarseOfFine[Int(face.x)], b = coarseOfFine[Int(face.y)], c = coarseOfFine[Int(face.z)]
            guard a != b, b != c, a != c else { continue }
            let area = simd_length(simd_cross(coarseRest[Int(b)] - coarseRest[Int(a)], coarseRest[Int(c)] - coarseRest[Int(a)])) * 0.5
            guard area > 0.02 * spacing * spacing else { continue }
            let key = SIMD3<UInt32>([a, b, c].sorted())
            guard seen.insert(key).inserted else { continue }
            // Cells fold neighbouring triangles onto one another; a third
            // face on an edge is such a fold, and its bend constraints
            // fight the other two. Keep the surface two-manifold.
            let edges = [(a, b), (b, c), (c, a)].map { SIMD2<UInt32>(min($0.0, $0.1), max($0.0, $0.1)) }
            guard edges.allSatisfy({ edgeUse[$0, default: 0] < 2 }) else {
                stats.facesFolded += 1
                continue
            }
            for coarse in [a, b, c] {
                facesOfCoarse[Int(coarse)].append(coarseFaces.count)
            }
            coarseFaces.append(SIMD3(a, b, c))
            for edge in edges {
                edgeUse[edge, default: 0] += 1
                let (u, v) = (edge.x, edge.y)
                let length = simd_length(coarseRest[Int(u)] - coarseRest[Int(v)])
                minEdge = min(minEdge, length)
                maxEdge = max(maxEdge, length)
            }
        }

        // A particle no face survived on has no constraints: it would
        // free-fall out of the cape at the speed cap. Its cell's
        // vertices bind to the nearest face instead, and it is compacted
        // away.
        var newIndex = [UInt32?](repeating: nil, count: members.count)
        var kept: [Int] = []
        for coarse in members.indices where !facesOfCoarse[coarse].isEmpty {
            newIndex[coarse] = UInt32(kept.count)
            kept.append(coarse)
        }
        stats.particlesOrphaned = members.count - kept.count
        if kept.count < members.count {
            var remappedFaces: [SIMD3<UInt32>] = []
            remappedFaces.reserveCapacity(coarseFaces.count)
            for face in coarseFaces {
                remappedFaces.append(SIMD3(newIndex[Int(face.x)]!, newIndex[Int(face.y)]!, newIndex[Int(face.z)]!))
            }
            coarseFaces = remappedFaces
            var remappedPinned: [UInt32] = []
            var remappedPinBindings: [[PinBinding]] = []
            for (slot, particle) in coarsePinned.enumerated() {
                guard let index = newIndex[Int(particle)] else { continue }
                remappedPinned.append(index)
                remappedPinBindings.append(coarsePinBindings[slot])
            }
            coarsePinned = remappedPinned
            coarsePinBindings = remappedPinBindings
            coarseRest = kept.map { coarseRest[$0] }
            coarseStart = kept.map { coarseStart[$0] }
            coarseInverseMass = kept.map { coarseInverseMass[$0] }
            facesOfCoarse = kept.map { facesOfCoarse[$0] }
            members = kept.map { members[$0] }
            for fine in 0 ..< fineCount {
                // An orphaned cell's vertices search every face below.
                coarseOfFine[fine] = newIndex[Int(coarseOfFine[fine])] ?? UInt32.max
            }
        }

        // Rest normals of the coarse particles, from their faces.
        var coarseNormals = [simd_float3](repeating: .zero, count: members.count)
        for face in coarseFaces {
            let n = simd_cross(coarseRest[Int(face.y)] - coarseRest[Int(face.x)], coarseRest[Int(face.z)] - coarseRest[Int(face.x)])
            coarseNormals[Int(face.x)] += n
            coarseNormals[Int(face.y)] += n
            coarseNormals[Int(face.z)] += n
        }
        for (coarse, fines) in members.enumerated() {
            if simd_length_squared(coarseNormals[coarse]) > 1e-12 {
                coarseNormals[coarse] = simd_normalize(coarseNormals[coarse])
            } else {
                coarseNormals[coarse] = particleNormals[fines[0]]
            }
        }

        // Bind every fine particle to the nearest coarse face of its cell.
        var bindingOfFine: [VertexBinding] = []
        bindingOfFine.reserveCapacity(fineCount)
        var worstError: Float = 0
        for fine in 0 ..< fineCount {
            let p = particleRest[fine]
            let coarse = coarseOfFine[fine]
            // The faces touching the cell; an orphaned cell searches every face.
            let candidates = coarse == UInt32.max ? Array(coarseFaces.indices) : facesOfCoarse[Int(coarse)]
            var best: (face: SIMD3<UInt32>, weights: simd_float3, distance: Float)?
            for index in candidates {
                let face = coarseFaces[index]
                let (weights, distance) = Self.closestPoint(on: (coarseRest[Int(face.x)], coarseRest[Int(face.y)], coarseRest[Int(face.z)]), to: p)
                if best == nil || distance < best!.distance {
                    best = (face, weights, distance)
                }
            }
            let binding: VertexBinding
            let reference = coarse == UInt32.max ? best.map { coarseNormals[Int($0.face.x)] } ?? particleNormals[fine] : coarseNormals[Int(coarse)]
            let sign: Float = simd_dot(particleNormals[fine], reference) < 0 ? -1 : 1
            if let best {
                let frame = Self.frame(coarseRest[Int(best.face.x)], coarseRest[Int(best.face.y)], coarseRest[Int(best.face.z)])
                let base = best.weights.x * coarseRest[Int(best.face.x)] + best.weights.y * coarseRest[Int(best.face.y)] + best.weights.z * coarseRest[Int(best.face.z)]
                let d = p - base
                binding = VertexBinding(
                    particles: best.face, weights: best.weights,
                    local: simd_float3(simd_dot(d, frame.0), simd_dot(d, frame.1), simd_dot(d, frame.2)), normalSign: sign
                )
            } else {
                // No face at all (a cloth of lone particles): ride the particle.
                let anchor = coarse == UInt32.max ? 0 : coarse
                let d = p - coarseRest[Int(anchor)]
                binding = VertexBinding(particles: SIMD3(repeating: anchor), weights: simd_float3(1, 0, 0), local: simd_float3(0, 0, simd_dot(d, coarseNormals[Int(anchor)])), normalSign: sign)
            }
            bindingOfFine.append(binding)
        }
        // Verify the rest pose comes back.
        let (rebuilt, _) = Self.deformed(bindings: bindingOfFine, particles: coarseRest, faces: coarseFaces)
        for fine in 0 ..< fineCount {
            worstError = max(worstError, simd_length(rebuilt[fine] - particleRest[fine]))
        }

        vertexBindings = vertexBindings.map { bindingOfFine[Int($0.particles.x)] }
        particleRest = coarseRest
        startWorld = coarseStart
        particleNormals = coarseNormals
        faces = coarseFaces
        inverseMasses = coarseInverseMass
        pinned = coarsePinned
        pinBindings = coarsePinBindings
        stats.particles = coarseRest.count
        stats.faces = coarseFaces.count
        stats.pinned = coarsePinned.count
        stats.nonManifoldEdges = edgeUse.values.filter { $0 > 2 }.count
        stats.minEdge = minEdge
        stats.maxEdge = maxEdge
        stats.bindingError = worstError
    }

    /// Spreads per-vertex displacements over the mesh: a vertex's
    /// displacement grows to `share` of its largest neighbour's where
    /// that is larger, never shrinks, over `passes` rings. A lone vertex
    /// pushed out of the body by centimetres is a spike; with its first
    /// ring lifted to 70 % and the second to 49 % it is a bump.
    func spread(_ displacements: inout [simd_float3], passes: Int = 2, share: Float = 0.7) {
        guard displacements.count == meshVertexOfVertex.count, !meshNeighbours.isEmpty else { return }
        var perMesh = [simd_float3](repeating: .zero, count: meshNeighbours.count)
        for (slot, mesh) in meshVertexOfVertex.enumerated() where simd_length_squared(displacements[slot]) > simd_length_squared(perMesh[Int(mesh)]) {
            perMesh[Int(mesh)] = displacements[slot]
        }
        for _ in 0 ..< passes {
            var next = perMesh
            for (mesh, neighbours) in meshNeighbours.enumerated() where !neighbours.isEmpty {
                var largest = simd_float3.zero
                for n in neighbours where simd_length_squared(perMesh[Int(n)]) > simd_length_squared(largest) {
                    largest = perMesh[Int(n)]
                }
                largest *= share
                if simd_length_squared(largest) > simd_length_squared(perMesh[mesh]) {
                    next[mesh] = largest
                }
            }
            perMesh = next
        }
        for (slot, mesh) in meshVertexOfVertex.enumerated() {
            displacements[slot] = perMesh[Int(mesh)]
        }
    }

    /// The mesh vertices (positions and unit normals, in the particles'
    /// space) for the current particle positions.
    func deformedVertices(particles: [simd_float3]) -> (positions: [simd_float3], normals: [simd_float3]) {
        Self.deformed(bindings: vertexBindings, particles: particles, faces: faces)
    }

    private static func deformed(bindings: [VertexBinding], particles: [simd_float3], faces: [SIMD3<UInt32>]) -> ([simd_float3], [simd_float3]) {
        var smooth = [simd_float3](repeating: .zero, count: particles.count)
        for face in faces {
            let n = simd_cross(particles[Int(face.y)] - particles[Int(face.x)], particles[Int(face.z)] - particles[Int(face.x)])
            smooth[Int(face.x)] += n
            smooth[Int(face.y)] += n
            smooth[Int(face.z)] += n
        }
        var positions: [simd_float3] = []
        var normals: [simd_float3] = []
        positions.reserveCapacity(bindings.count)
        normals.reserveCapacity(bindings.count)
        for binding in bindings {
            let a = particles[Int(binding.particles.x)], b = particles[Int(binding.particles.y)], c = particles[Int(binding.particles.z)]
            var n = binding.weights.x * smooth[Int(binding.particles.x)] + binding.weights.y * smooth[Int(binding.particles.y)] + binding.weights.z * smooth[Int(binding.particles.z)]
            n = simd_length_squared(n) > 1e-12 ? simd_normalize(n) : simd_float3(0, 0, 1)
            var p = binding.weights.x * a + binding.weights.y * b + binding.weights.z * c
            if binding.particles.x != binding.particles.y {
                let frame = frame(a, b, c)
                p += binding.local.x * frame.0 + binding.local.y * frame.1 + binding.local.z * frame.2
            } else {
                p += binding.local.z * n
            }
            positions.append(p)
            normals.append(binding.normalSign * n)
        }
        return (positions, normals)
    }

    /// A triangle's frame: its first edge, the in-plane perpendicular, the normal.
    private static func frame(_ a: simd_float3, _ b: simd_float3, _ c: simd_float3) -> (simd_float3, simd_float3, simd_float3) {
        let ab = b - a
        var e1 = simd_length_squared(ab) > 1e-12 ? simd_normalize(ab) : simd_float3(1, 0, 0)
        var n = simd_cross(ab, c - a)
        n = simd_length_squared(n) > 1e-14 ? simd_normalize(n) : simd_float3(0, 0, 1)
        if abs(simd_dot(e1, n)) > 0.999 { e1 = simd_float3(0, 1, 0) }
        return (e1, simd_cross(n, e1), n)
    }

    /// Barycentric weights of the point of the triangle closest to `p`,
    /// and its distance.
    static func closestPoint(on triangle: (simd_float3, simd_float3, simd_float3), to p: simd_float3) -> (simd_float3, Float) {
        let (a, b, c) = triangle
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return (simd_float3(1, 0, 0), simd_length(ap)) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return (simd_float3(0, 1, 0), simd_length(bp)) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / max(d1 - d3, 1e-12)
            return (simd_float3(1 - v, v, 0), simd_length(p - (a + v * ab)))
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return (simd_float3(0, 0, 1), simd_length(cp)) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / max(d2 - d6, 1e-12)
            return (simd_float3(1 - w, 0, w), simd_length(p - (a + w * ac)))
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            let w = (d4 - d3) / max((d4 - d3) + (d5 - d6), 1e-12)
            return (simd_float3(0, 1 - w, w), simd_length(p - (b + w * (c - b))))
        }
        let denom = 1 / max(va + vb + vc, 1e-20)
        let v = vb * denom, w = vc * denom
        return (simd_float3(1 - v - w, v, w), simd_length(p - (a + ab * v + ac * w)))
    }

    /// A capsule collider the cloth must start outside of.
    struct Capsule {
        var start: simd_float3
        var end: simd_float3
        var radius: Float
    }

    /// Moves every free starting position out of the capsules (plus a
    /// margin): an overlap at creation is resolved by Jolt in one step
    /// with a huge velocity, which is what threw the cape across the room.
    mutating func pushStartOut(of capsules: [Capsule], margin: Float) {
        let pinnedSet = Set(pinned)
        for particle in startWorld.indices where !pinnedSet.contains(UInt32(particle)) {
            var p = startWorld[particle]
            for capsule in capsules {
                let axis = capsule.end - capsule.start
                let lengthSquared = max(simd_length_squared(axis), 1e-8)
                let t = simd_clamp(simd_dot(p - capsule.start, axis) / lengthSquared, 0, 1)
                let closest = capsule.start + axis * t
                let d = p - closest
                let distance = simd_length(d)
                let wanted = capsule.radius + margin
                if distance < wanted {
                    p = distance > 1e-6 ? closest + d / distance * wanted : closest + simd_float3(0, 0, -wanted)
                }
            }
            startWorld[particle] = p
        }
    }

    /// World targets of the pinned particles for the current joints.
    func pinTargets(joints: [JointFrame]) -> [simd_float3] {
        pinBindings.map { bindings in
            var target = simd_float3.zero
            var total: Float = 0
            for binding in bindings where binding.joint < joints.count {
                let joint = joints[binding.joint]
                target += binding.weight * (joint.position + joint.rotation.act(binding.offset))
                total += binding.weight
            }
            return total > 0 ? target / total : .zero
        }
    }
}

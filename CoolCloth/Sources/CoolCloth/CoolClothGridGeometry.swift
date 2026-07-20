import simd

/// Index topology for the cloth grid (vertex positions come from the simulation
/// texture, fetched by vertex id, so only an index buffer is needed) plus the
/// demo ball mesh.
struct CoolClothGridGeometry {
    static let gridSize = CoolClothSimulation.gridSize
    static let vertexCount = gridSize * gridSize
    static let indexCount = (gridSize - 1) * (gridSize - 1) * 6
    static let indexBufferLength = indexCount * MemoryLayout<UInt32>.stride

    static let ballStacks = 24
    static let ballSlices = 24
    static let ballVertexCount = ballStacks * ballSlices * 6
    static let ballBufferLength = ballVertexCount * MemoryLayout<SIMD3<Float>>.stride

    let indices: [UInt32]
    let ballVertices: [SIMD3<Float>]

    static func make() -> CoolClothGridGeometry {
        CoolClothGridGeometry(indices: makeIndices(), ballVertices: makeBallVertices())
    }

    private static func makeIndices() -> [UInt32] {
        let n = gridSize
        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)
        for row in 0 ..< (n - 1) {
            for column in 0 ..< (n - 1) {
                let a = UInt32(row * n + column)
                let b = a + 1
                let c = UInt32((row + 1) * n + column)
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return indices
    }

    private static func makeBallVertices() -> [SIMD3<Float>] {
        func point(stack: Int, slice: Int) -> SIMD3<Float> {
            let v = Float(stack) / Float(ballStacks)
            let u = Float(slice) / Float(ballSlices)
            let phi = v * .pi
            let theta = u * 2 * .pi
            return SIMD3<Float>(
                sin(phi) * cos(theta),
                cos(phi),
                sin(phi) * sin(theta)
            )
        }

        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(ballVertexCount)
        for stack in 0 ..< ballStacks {
            for slice in 0 ..< ballSlices {
                let p0 = point(stack: stack, slice: slice)
                let p1 = point(stack: stack + 1, slice: slice)
                let p2 = point(stack: stack + 1, slice: slice + 1)
                let p3 = point(stack: stack, slice: slice + 1)
                vertices.append(contentsOf: [p0, p1, p2, p0, p2, p3])
            }
        }
        return vertices
    }
}

import simd

struct CoolWaterSceneGeometry {
    static let sphereStacks = 24
    static let sphereSlices = 24
    static let poolVertexCount = 30
    static let sphereVertexCount = sphereStacks * sphereSlices * 6
    static let poolBufferLength = poolVertexCount * MemoryLayout<SIMD3<Float>>.stride
    static let sphereBufferLength = sphereVertexCount * MemoryLayout<SIMD3<Float>>.stride

    let poolVertices: [SIMD3<Float>]
    let sphereVertices: [SIMD3<Float>]

    static func make() -> CoolWaterSceneGeometry {
        CoolWaterSceneGeometry(
            poolVertices: makePoolVertices(),
            sphereVertices: makeSphereVertices()
        )
    }

    private static func makePoolVertices() -> [SIMD3<Float>] {
        let corners = [
            SIMD3<Float>(-1, -1, -1), SIMD3<Float>(1, -1, -1),
            SIMD3<Float>(1, -1, 1), SIMD3<Float>(-1, -1, 1),
            SIMD3<Float>(-1, 1, -1), SIMD3<Float>(1, 1, -1),
            SIMD3<Float>(1, 1, 1), SIMD3<Float>(-1, 1, 1),
        ]
        func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> [SIMD3<Float>] {
            [corners[a], corners[b], corners[c], corners[a], corners[c], corners[d]]
        }
        return quad(4, 5, 6, 7)
            + quad(0, 4, 7, 3)
            + quad(1, 2, 6, 5)
            + quad(0, 1, 5, 4)
            + quad(3, 7, 6, 2)
    }

    private static func makeSphereVertices() -> [SIMD3<Float>] {
        func point(stack: Int, slice: Int) -> SIMD3<Float> {
            let v = Float(stack) / Float(sphereStacks)
            let u = Float(slice) / Float(sphereSlices)
            let phi = v * .pi
            let theta = u * 2 * .pi
            return SIMD3<Float>(
                sin(phi) * cos(theta),
                cos(phi),
                sin(phi) * sin(theta)
            )
        }

        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(sphereVertexCount)
        for stack in 0 ..< sphereStacks {
            for slice in 0 ..< sphereSlices {
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

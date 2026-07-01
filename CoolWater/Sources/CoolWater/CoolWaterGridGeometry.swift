import simd

struct CoolWaterGridGeometry {
    static let detail = 200
    static let vertexCount = (detail + 1) * (detail + 1)
    static let indexCount = detail * detail * 6
    static let vertexBufferLength = vertexCount * MemoryLayout<SIMD3<Float>>.stride
    static let indexBufferLength = indexCount * MemoryLayout<UInt32>.stride

    let vertices: [SIMD3<Float>]
    let indices: [UInt32]

    static func make() -> CoolWaterGridGeometry {
        let rowSize = detail + 1
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(vertexCount)
        for row in 0 ... detail {
            for column in 0 ... detail {
                let x = Float(column) / Float(detail) * 2 - 1
                let y = Float(row) / Float(detail) * 2 - 1
                vertices.append(SIMD3<Float>(x, y, 0))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)
        for row in 0 ..< detail {
            for column in 0 ..< detail {
                let a = UInt32(row * rowSize + column)
                let b = a + 1
                let c = UInt32((row + 1) * rowSize + column)
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return CoolWaterGridGeometry(vertices: vertices, indices: indices)
    }
}

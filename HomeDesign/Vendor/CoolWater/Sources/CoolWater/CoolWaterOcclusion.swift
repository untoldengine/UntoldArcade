import Foundation
import Metal
import simd

/// Indexed world mesh used to write real-scene depth before CoolWater geometry.
public struct CoolWaterOcclusionMesh: @unchecked Sendable {
    public let vertexBuffer: MTLBuffer
    public let vertexOffset: Int
    public let vertexStride: Int
    public let indexBuffer: MTLBuffer
    public let indexOffset: Int
    public let indexCount: Int
    public let indexType: MTLIndexType
    public let transform: simd_float4x4

    public init(
        vertexBuffer: MTLBuffer,
        vertexOffset: Int,
        vertexStride: Int,
        indexBuffer: MTLBuffer,
        indexOffset: Int,
        indexCount: Int,
        indexType: MTLIndexType,
        transform: simd_float4x4
    ) {
        self.vertexBuffer = vertexBuffer
        self.vertexOffset = vertexOffset
        self.vertexStride = vertexStride
        self.indexBuffer = indexBuffer
        self.indexOffset = indexOffset
        self.indexCount = indexCount
        self.indexType = indexType
        self.transform = transform
    }
}

final class CoolWaterOcclusionStore: @unchecked Sendable {
    static let shared = CoolWaterOcclusionStore()

    private let lock = NSLock()
    private var meshes: [CoolWaterOcclusionMesh] = []

    private init() {}

    func setMeshes(_ meshes: [CoolWaterOcclusionMesh]) {
        lock.withLock { self.meshes = meshes }
    }

    func snapshot() -> [CoolWaterOcclusionMesh] {
        lock.withLock { meshes }
    }
}

public func setCoolWaterOcclusionMeshes(_ meshes: [CoolWaterOcclusionMesh]) {
    CoolWaterOcclusionStore.shared.setMeshes(meshes)
}

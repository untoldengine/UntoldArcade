import Foundation
import Metal
import simd

/// Indexed world mesh used to write real-scene depth before CoolCloth geometry.
public struct CoolClothOcclusionMesh: @unchecked Sendable {
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

final class CoolClothOcclusionStore: @unchecked Sendable {
    static let shared = CoolClothOcclusionStore()

    private let lock = NSLock()
    private var meshes: [CoolClothOcclusionMesh] = []
    private var enabled = true

    private init() {}

    func setMeshes(_ meshes: [CoolClothOcclusionMesh]) {
        lock.withLock { self.meshes = meshes }
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
    }

    func snapshot() -> [CoolClothOcclusionMesh] {
        lock.withLock { enabled ? meshes : [] }
    }
}

public func setCoolClothOcclusionMeshes(_ meshes: [CoolClothOcclusionMesh]) {
    CoolClothOcclusionStore.shared.setMeshes(meshes)
}

/// Debug/diagnostic switch: when disabled the real-scene depth pre-pass is
/// skipped entirely, so nothing in the real room can hide the cloth.
public func setCoolClothOcclusionEnabled(_ enabled: Bool) {
    CoolClothOcclusionStore.shared.setEnabled(enabled)
}

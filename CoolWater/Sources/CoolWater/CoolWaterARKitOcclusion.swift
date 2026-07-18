#if os(visionOS)
import ARKit
import Foundation
import Metal

/// Optional visionOS adapter that streams ARKit reconstruction meshes to CoolWater.
public final class CoolWaterARKitOcclusionProvider: @unchecked Sendable {
    private let session = ARKitSession()
    private let provider = SceneReconstructionProvider()
    private let lock = NSLock()
    private var meshesByID: [UUID: CoolWaterOcclusionMesh] = [:]
    private var updateTask: Task<Void, Never>?

    public init() {}

    public static var isSupported: Bool {
        SceneReconstructionProvider.isSupported
    }

    public func start() {
        guard Self.isSupported else { return }
        lock.withLock {
            guard updateTask == nil else { return }
            updateTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await session.run([provider])
                } catch {
                    self.clearTask()
                    return
                }
                for await update in provider.anchorUpdates {
                    guard !Task.isCancelled else { break }
                    self.handle(update)
                }
                self.clearTask()
            }
        }
    }

    public func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let task = updateTask
            updateTask = nil
            meshesByID.removeAll()
            return task
        }
        task?.cancel()
        setCoolWaterOcclusionMeshes([])
    }

    private func handle(_ update: AnchorUpdate<MeshAnchor>) {
        let anchor = update.anchor
        lock.withLock {
            switch update.event {
            case .removed:
                meshesByID.removeValue(forKey: anchor.id)
            case .added, .updated:
                let geometry = anchor.geometry
                let faces = geometry.faces
                let normals = geometry.normals
                meshesByID[anchor.id] = CoolWaterOcclusionMesh(
                    vertexBuffer: geometry.vertices.buffer,
                    vertexOffset: geometry.vertices.offset,
                    vertexStride: geometry.vertices.stride,
                    indexBuffer: faces.buffer,
                    indexOffset: 0,
                    indexCount: faces.count * 3,
                    indexType: faces.bytesPerIndex == 2 ? .uint16 : .uint32,
                    transform: anchor.originFromAnchorTransform,
                    normalBuffer: normals.buffer,
                    normalOffset: normals.offset,
                    normalStride: normals.stride
                )
            }
            setCoolWaterOcclusionMeshes(Array(meshesByID.values))
        }
    }

    private func clearTask() {
        lock.withLock { updateTask = nil }
    }
}
#endif

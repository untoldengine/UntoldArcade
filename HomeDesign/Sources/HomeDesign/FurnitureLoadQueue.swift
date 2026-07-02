//
//  FurnitureLoadQueue.swift
//  HomeDesign
//

import Foundation

// Thread-safe single-slot queue bridging SwiftUI (main thread) to the XR game loop.
// SwiftUI enqueues a model name; the game loop dequeues it on the next update tick.
final class FurnitureLoadQueue {
    static let shared = FurnitureLoadQueue()

    private let lock = NSLock()
    private var _pendingModelName: String?

    init() {}

    func enqueue(_ modelName: String) {
        lock.withLock { _pendingModelName = modelName }
    }

    func dequeue() -> String? {
        lock.withLock {
            defer { _pendingModelName = nil }
            return _pendingModelName
        }
    }
}

//
//  FurnitureLoadQueue.swift
//  HomeDesign
//

import Foundation

// Thread-safe FIFO queue bridging SwiftUI (main thread) to the XR game loop.
// SwiftUI enqueues a model name per catalog tap; the game loop dequeues one
// per update tick that isn't already mid-placement. A single-slot mailbox
// would silently drop earlier taps whenever two catalog items were queued
// before the render thread caught up — FIFO ensures every tap is honored.
final class FurnitureLoadQueue {
    static let shared = FurnitureLoadQueue()

    private let lock = NSLock()
    private var _pendingModelNames: [String] = []

    init() {}

    func enqueue(_ modelName: String) {
        lock.withLock { _pendingModelNames.append(modelName) }
    }

    func dequeue() -> String? {
        lock.withLock {
            guard !_pendingModelNames.isEmpty else { return nil }
            return _pendingModelNames.removeFirst()
        }
    }
}

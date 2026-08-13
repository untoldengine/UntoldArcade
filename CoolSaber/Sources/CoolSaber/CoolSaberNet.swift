import Foundation
import simd

/// Wire types for the SharePlay duel. Kept free of GroupActivities imports so
/// they build and test on any host; the example app owns the transport.
public enum SaberHand: UInt8, Codable, Sendable, CaseIterable {
    case left
    case right
}

/// One blade as sent over the wire, in the sender's immersive-space frame.
public struct SaberBladeWire: Codable, Equatable, Sendable {
    public var hilt: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var length: Float
    public var ignited: Bool

    public init(
        hilt: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        direction: SIMD3<Float> = SIMD3<Float>(0, 0, -1),
        length: Float = 0,
        ignited: Bool = false
    ) {
        self.hilt = hilt
        self.direction = direction
        self.length = length
        self.ignited = ignited
    }
}

/// High-rate pose update, sent unreliably (~45 Hz). `sequence` lets the
/// receiver drop out-of-order packets; `timestamp` is sender uptime, used only
/// for staleness on the receiving side.
public struct SaberPosePacket: Codable, Equatable, Sendable {
    public var sequence: UInt32
    public var timestamp: TimeInterval
    public var left: SaberBladeWire
    public var right: SaberBladeWire

    public init(
        sequence: UInt32,
        timestamp: TimeInterval,
        left: SaberBladeWire,
        right: SaberBladeWire
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.left = left
        self.right = right
    }
}

/// Low-rate events, sent reliably.
public enum SaberEvent: Codable, Equatable, Sendable {
    case ignite(hand: SaberHand, ignited: Bool, color: SIMD3<Float>)
    case clash(position: SIMD3<Float>, intensity: Float)
}

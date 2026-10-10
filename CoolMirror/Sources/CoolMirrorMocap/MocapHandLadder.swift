//
//  MocapHandLadder.swift
//  CoolMirrorMocap
//
//  Which device says where a hand is. The headset sees the hands to the
//  millimetre while its cameras have them, which is most of the time, the
//  arms hanging included; behind the back, overhead or in a turn it loses
//  them, often for a few tenths of a second at the edge of its view. The
//  phone sees them all the time and puts them 10 to 25 cm off, mostly in
//  depth. So each hand follows the headset while it is seen and the phone
//  while it is not, and no change of source shows:
//
//  - A loss is bridged first: for a moment the hand carries on the way it
//    was going, and a hand back within that moment never left.
//  - Past that the phone takes over where the hand is, not where the phone
//    has it: the difference is carried and let go of slowly.
//  - Coming back, the hand must be seen for a moment before the headset
//    has it again (a flicker at the edge is no return), and what is left
//    of the difference goes fast: the headset is right.
//
//  Everything is measured from the head, the one point both devices
//  have: what the phone gets wrong about where the body is does not reach
//  the hands. The headset measures the wearer, the phone fits a skeleton
//  of its own size: how much larger is learnt while both see a hand. Pure
//  and testable.
//

import Foundation
import simd

public struct MocapHandLadder: Sendable {
    public enum Source: Sendable, Equatable {
        case headset
        /// The headset lost the hand a moment ago; it carries on.
        case bridge
        case phone
    }

    public struct Input: Sendable {
        /// From the joint the head turns on to the wrist as the headset
        /// sees it, in the axes of the phone's positions (mirrored and
        /// turned like them), in metres of the wearer; nil while the
        /// headset does not see the hand.
        public var headset: simd_float3?
        /// From the head to the hand as the phone has them.
        public var phone: simd_float3?

        public init(headset: simd_float3?, phone: simd_float3?) {
            self.headset = headset
            self.phone = phone
        }
    }

    public struct Output: Sendable, Equatable {
        /// From the head to the hand, in the phone's metres.
        public var position: simd_float3
        public var source: Source
    }

    /// How long a lost hand carries on before the phone takes over (s).
    public var bridge: TimeInterval = 0.1
    /// Halflife of the speed it carries on with (s).
    public var bridgeHalflife: Float = 0.06
    /// How long a hand must be seen before the headset has it back (s).
    public var returnDelay: TimeInterval = 0.15
    /// Halflife of the difference carried into the phone's hand (s).
    public var phoneHalflife: Float = 0.5
    /// Halflife of what is left of it when the headset takes over (s).
    public var headsetHalflife: Float = 0.05
    /// The fastest the difference is made up (m/s): the phone can have a
    /// hand half a metre off, and a hand that crosses that in a tenth of
    /// a second is a jump by another name.
    public var catchUpSpeed: Float = 2
    /// Halflife of the learning of the phone's scale (s).
    public var scaleHalflife: Float = 3
    /// A frame further than this from the last one starts over (s).
    public var maxGap: TimeInterval = 0.5

    /// The phone's metres per metre of the wearer's.
    public private(set) var scale: Float = 1

    private struct Hand {
        var source: Source = .phone
        /// Output minus what the source says; decays.
        var residual = simd_float3.zero
        var output: simd_float3?
        /// The headset's hand when last seen, its speed, and when.
        var seen: simd_float3?
        var velocity = simd_float3.zero
        var lastSeen: TimeInterval?
        /// Since when it has been seen without a break.
        var seenSince: TimeInterval?
    }

    private var hands: [MocapJoint: Hand] = [:]
    private var lastTime: TimeInterval?

    public init() {}

    /// The source each hand follows.
    public var sources: [MocapJoint: Source] {
        hands.mapValues(\.source)
    }

    /// - inputs: by the rig's hand.
    public mutating func update(_ inputs: [MocapJoint: Input], time: TimeInterval) -> [MocapJoint: Output] {
        var dt: Float = 0
        if let lastTime {
            if time - lastTime > maxGap || time < lastTime {
                reset()
            } else {
                dt = Float(time - lastTime)
            }
        }
        lastTime = time
        func decay(_ halflife: Float) -> Float {
            dt > 0 ? exp(-0.693_147_18 * dt / max(halflife, 1e-4)) : 1
        }

        // The phone's scale, from the hands both see: how far each is
        // from the head, one against the other.
        var phone: Float = 0, seen: Float = 0
        for input in inputs.values {
            guard let headset = input.headset, let hand = input.phone else { continue }
            phone += simd_length(hand)
            seen += simd_length(headset)
        }
        if seen > 0.2, dt > 0 {
            let measured = min(max(phone / seen, 0.8), 1.3)
            scale += (measured - scale) * (1 - decay(scaleHalflife))
        }

        var outputs: [MocapJoint: Output] = [:]
        for (joint, input) in inputs {
            var hand = hands[joint] ?? Hand()
            let headset = input.headset.map { $0 * scale }

            // What the headset says, and for how long it has.
            if let headset {
                if let last = hand.seen, let lastSeen = hand.lastSeen, time > lastSeen, time - lastSeen < bridge {
                    let measured = (headset - last) / Float(time - lastSeen)
                    hand.velocity += (measured - hand.velocity) * 0.5
                } else {
                    hand.velocity = .zero
                }
                hand.seen = headset
                hand.lastSeen = time
                hand.seenSince = hand.seenSince ?? time
            } else {
                hand.seenSince = nil
            }

            // The source, and what it says.
            var source = hand.source
            switch hand.source {
            case .headset, .bridge:
                if headset != nil {
                    source = .headset
                } else if let lastSeen = hand.lastSeen, time - lastSeen <= bridge {
                    source = .bridge
                } else {
                    source = .phone
                }
            case .phone:
                if let since = hand.seenSince, time - since >= returnDelay || hand.output == nil || input.phone == nil {
                    source = .headset
                }
            }
            var said: simd_float3?
            switch source {
            case .headset:
                said = headset
            case .bridge:
                if var carried = hand.seen {
                    carried += hand.velocity * dt
                    hand.velocity *= decay(bridgeHalflife)
                    hand.seen = carried
                    said = carried
                }
            case .phone:
                said = input.phone
            }
            guard let said else {
                // Nobody sees it: what is kept is what the headset knew.
                hand.source = .phone
                hand.output = nil
                hand.residual = .zero
                hands[joint] = hand
                continue
            }

            // A change of source shows nowhere: the difference is
            // carried, and goes at the pace of the source it went to.
            if source != hand.source || hand.output == nil {
                let continuing = (hand.source == .headset && source == .bridge) || (hand.source == .bridge && source == .headset)
                if let output = hand.output, !continuing || hand.source == .bridge {
                    hand.residual = output - said
                } else if hand.output == nil {
                    hand.residual = .zero
                }
                hand.source = source
            } else {
                let kept = hand.residual * decay(source == .phone ? phoneHalflife : headsetHalflife)
                let given = simd_length(hand.residual - kept)
                if given > catchUpSpeed * dt, given > 0 {
                    hand.residual -= (hand.residual - kept) / given * catchUpSpeed * dt
                } else {
                    hand.residual = kept
                }
            }
            let position = said + hand.residual
            hand.output = position
            hands[joint] = hand
            outputs[joint] = Output(position: position, source: source)
        }
        for joint in hands.keys where inputs[joint] == nil {
            hands[joint] = nil
        }
        return outputs
    }

    public mutating func reset() {
        hands.removeAll()
        lastTime = nil
    }
}

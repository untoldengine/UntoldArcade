//
//  CoolBowlingFrameCycle.swift
//  CoolBowling
//
//  The two-ball frame as a clock-driven state machine, kept apart from the
//  entities so it can be tested with a synthetic clock. A ball ends when the
//  pit (or the dead-ball rule) says so; the ball comes back down the return
//  after `returnDelay`, and the pins are judged after `settleDelay`: a
//  strike or the second ball re-racks, otherwise the deadwood is cleared.
//

import Foundation

public struct CoolBowlingFrameCycle: Sendable {
    public enum Action: Equatable, Sendable {
        case returnBall
        case resolve
    }

    public enum Resolution: Equatable, Sendable {
        case rerack
        case sweep
    }

    public private(set) var frame = 1
    public private(set) var ballInFrame = 1
    public private(set) var ballEndedAt: TimeInterval?
    private var returned = false
    public let returnDelay: TimeInterval
    public let settleDelay: TimeInterval

    public init(returnDelay: TimeInterval = 0.7, settleDelay: TimeInterval = 2.0) {
        self.returnDelay = returnDelay
        self.settleDelay = settleDelay
    }

    /// A ball is on its way back and the pins are settling.
    public var isBallEnded: Bool {
        ballEndedAt != nil
    }

    /// Ten down on the first ball is a strike; on the second, a spare.
    public var isFirstBall: Bool {
        ballInFrame == 1
    }

    /// The ball is done (in the pit, dead on the lane, lost). Ignored while
    /// a ball is already ending. Returns whether it started a cycle.
    @discardableResult
    public mutating func endBall(at now: TimeInterval) -> Bool {
        guard ballEndedAt == nil else { return false }
        ballEndedAt = now
        returned = false
        return true
    }

    /// What is due now: the return once, then the resolution, which ends
    /// the cycle.
    public mutating func tick(now: TimeInterval) -> [Action] {
        guard let endedAt = ballEndedAt else { return [] }
        var actions: [Action] = []
        if !returned, now >= endedAt + returnDelay {
            returned = true
            actions.append(.returnBall)
        }
        if now >= endedAt + settleDelay {
            ballEndedAt = nil
            actions.append(.resolve)
        }
        return actions
    }

    /// Judges the settled pins and moves the frame on.
    public mutating func resolve(pinsDown: Int, pinCount: Int = 10) -> Resolution {
        if pinsDown >= pinCount || ballInFrame >= 2 {
            frame += 1
            ballInFrame = 1
            return .rerack
        }
        ballInFrame = 2
        return .sweep
    }

    /// A manual return (the New ball button) during a cycle stands in for
    /// the automatic one; the resolution still comes.
    public mutating func ballReturnedManually() {
        if ballEndedAt != nil {
            returned = true
        }
    }

    /// A manual re-rack (the Reset pins button) starts a new frame and
    /// drops any pending resolution.
    public mutating func rerackedManually() {
        ballEndedAt = nil
        returned = false
        frame += 1
        ballInFrame = 1
    }

    public mutating func reset() {
        self = CoolBowlingFrameCycle(returnDelay: returnDelay, settleDelay: settleDelay)
    }
}

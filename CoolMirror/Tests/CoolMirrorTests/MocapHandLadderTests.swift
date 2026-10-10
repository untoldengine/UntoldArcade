//
//  MocapHandLadderTests.swift
//  CoolMirrorTests
//
//  Which device says where a hand is, and that a change of it never shows.
//

@testable import CoolMirrorMocap
import simd
import XCTest

final class MocapHandLadderTests: XCTestCase {
    private static let dt = 0.01

    /// The hand as the headset sees it, from the head: a slow circle in
    /// front of the chest.
    private static func seen(_ time: Double) -> simd_float3 {
        simd_float3(0.25 + 0.1 * Float(cos(time * 2)), -0.4 + 0.1 * Float(sin(time * 2)), 0.3)
    }

    /// The phone has it 15 cm further back and a little to the side.
    private static func phone(_ time: Double) -> simd_float3 {
        seen(time) + simd_float3(0.04, -0.02, -0.15)
    }

    /// Runs the ladder over `seconds`, the headset seeing the hand
    /// whenever `isSeen` says so; per step the time, the output and the
    /// source.
    private func run(
        _ ladder: inout MocapHandLadder, seconds: Double, isSeen: (Double) -> Bool, phoneSeesIt: Bool = true
    ) -> [(time: Double, output: MocapHandLadder.Output?)] {
        var steps: [(time: Double, output: MocapHandLadder.Output?)] = []
        for index in 0 ... Int((seconds / Self.dt).rounded()) {
            let time = Double(index) * Self.dt
            let input = MocapHandLadder.Input(headset: isSeen(time) ? Self.seen(time) : nil, phone: phoneSeesIt ? Self.phone(time) : nil)
            let outputs = ladder.update([.leftHand: input], time: time)
            steps.append((time, outputs[.leftHand]))
        }
        return steps
    }

    private static func largestStep(_ steps: [(time: Double, output: MocapHandLadder.Output?)]) -> Float {
        zip(steps, steps.dropFirst()).compactMap { a, b in
            guard let from = a.output, let to = b.output else { return nil }
            return simd_distance(from.position, to.position)
        }.max() ?? 0
    }

    /// The hand itself moves 2 mm a step.
    private static let ownStep: Float = 0.1 * 2 * Float(dt)

    private func fixedScale() -> MocapHandLadder {
        var ladder = MocapHandLadder()
        // These tests are about the sources: the phone's skeleton is the
        // wearer's size and nothing is to be learnt.
        ladder.scaleHalflife = 1e9
        return ladder
    }

    func testAHandTheHeadsetSeesIsWhereTheHeadsetHasIt() throws {
        var ladder = fixedScale()
        let steps = run(&ladder, seconds: 2) { _ in true }

        for step in steps {
            let output = try XCTUnwrap(step.output)
            XCTAssertEqual(output.source, .headset)
            XCTAssertLessThan(simd_distance(output.position, Self.seen(step.time)), 1e-5)
        }
    }

    func testAHandOnlyThePhoneSeesIsWhereThePhoneHasIt() throws {
        var ladder = fixedScale()
        let steps = run(&ladder, seconds: 1) { _ in false }

        for step in steps {
            let output = try XCTUnwrap(step.output)
            XCTAssertEqual(output.source, .phone)
            XCTAssertLessThan(simd_distance(output.position, Self.phone(step.time)), 1e-5)
        }
    }

    func testAHandNobodySeesIsNowhere() {
        var ladder = fixedScale()
        let steps = run(&ladder, seconds: 1, isSeen: { $0 < 0.5 }, phoneSeesIt: false)

        XCTAssertNotNil(steps[40].output)
        // It carries on for the length of the bridge, then it is gone.
        XCTAssertNil(steps[70].output)
        XCTAssertNil(steps.last?.output)
    }

    func testAShortLossIsBridgedAndThePhoneNeverTakesOver() throws {
        var ladder = fixedScale()
        let steps = run(&ladder, seconds: 2) { $0 < 1 || $0 > 1.07 }

        XCTAssertFalse(steps.contains { $0.output?.source == .phone })
        XCTAssertTrue(steps.contains { $0.output?.source == .bridge })
        XCTAssertLessThan(Self.largestStep(steps), Self.ownStep * 2)
        // Through the gap the hand carried on the way it went.
        let middle = try XCTUnwrap(steps[103].output)
        XCTAssertLessThan(simd_distance(middle.position, Self.seen(1.03)), 0.003)
    }

    func testALongLossHandsOverToThePhoneWithoutAJump() throws {
        var ladder = fixedScale()
        let steps = run(&ladder, seconds: 5) { $0 < 1 }

        XCTAssertEqual(steps[99].output?.source, .headset)
        XCTAssertEqual(steps[105].output?.source, .bridge)
        XCTAssertEqual(steps[115].output?.source, .phone)
        // The phone has the hand 16 cm from where it is; no step shows it.
        XCTAssertLessThan(Self.largestStep(steps), Self.ownStep * 2.5)
        // A tenth of a second in, the hand is still where it was...
        let early = try XCTUnwrap(steps[120].output)
        XCTAssertGreaterThan(simd_distance(early.position, Self.phone(1.2)), 0.12)
        // ...and seconds later where the phone has it.
        let late = try XCTUnwrap(steps[500].output)
        XCTAssertLessThan(simd_distance(late.position, Self.phone(5)), 0.002)
    }

    func testAFlickerAtTheEdgeIsNoReturn() {
        var ladder = fixedScale()
        // Lost at 1 s; seen for a twentieth of a second at 2 s.
        let steps = run(&ladder, seconds: 3) { $0 < 1 || ($0 >= 2 && $0 < 2.05) }

        XCTAssertTrue(steps.filter { $0.time > 1.2 }.allSatisfy { $0.output?.source == .phone })
        XCTAssertLessThan(Self.largestStep(steps), Self.ownStep * 2.5)
    }

    func testTheHeadsetTakesTheHandBackFastAndWithoutAJump() throws {
        var ladder = fixedScale()
        // Lost from 1 s to 4 s.
        let steps = run(&ladder, seconds: 5) { $0 < 1 || $0 >= 4 }

        XCTAssertEqual(steps[410].output?.source, .phone, "seen for a tenth of a second: not yet")
        XCTAssertEqual(steps[416].output?.source, .headset)
        // 16 cm to make up: fast, and no faster than a hand moves.
        XCTAssertLessThan(Self.largestStep(steps), 0.025)
        let settled = try XCTUnwrap(steps[450].output)
        XCTAssertLessThan(simd_distance(settled.position, Self.seen(4.5)), 0.003)
    }

    func testThePhonesScaleIsLearntWhileBothSeeTheHand() {
        var ladder = MocapHandLadder()
        for index in 0 ... 1500 {
            let time = Double(index) * Self.dt
            // The phone's skeleton is a tenth larger than the wearer.
            let input = MocapHandLadder.Input(headset: Self.seen(time), phone: Self.seen(time) * 1.1)
            _ = ladder.update([.leftHand: input], time: time)
        }

        XCTAssertEqual(ladder.scale, 1.1, accuracy: 0.01)
    }

    func testEachHandHasItsOwnSource() {
        var ladder = fixedScale()
        var outputs: [MocapJoint: MocapHandLadder.Output] = [:]
        for index in 0 ... 100 {
            let time = Double(index) * Self.dt
            outputs = ladder.update([
                .leftHand: .init(headset: Self.seen(time), phone: Self.phone(time)),
                .rightHand: .init(headset: nil, phone: Self.phone(time) * simd_float3(-1, 1, 1)),
            ], time: time)
        }

        XCTAssertEqual(outputs[.leftHand]?.source, .headset)
        XCTAssertEqual(outputs[.rightHand]?.source, .phone)
        XCTAssertEqual(ladder.sources, [.leftHand: .headset, .rightHand: .phone])
    }
}

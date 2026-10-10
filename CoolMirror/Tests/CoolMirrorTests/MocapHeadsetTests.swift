//
//  MocapHeadsetTests.swift
//  CoolMirrorTests
//
//  The headset's head and hands in the recordings.
//

@testable import CoolMirrorMocap
import simd
import XCTest

final class MocapHeadsetTests: XCTestCase {
    private static func hand(tracked: Bool, at position: simd_float3) -> MocapHandSample {
        var hand = MocapHandSample(
            isTracked: tracked,
            wrist: MocapPose(position: position, rotation: simd_quatf(angle: 0.7, axis: simd_normalize(simd_float3(1, 2, 3))))
        )
        for (index, joint) in MocapHandJoint.allCases.enumerated() {
            hand.joints[joint] = simd_float3(Float(index) * 0.007, -0.0123 * Float(index % 5), 0.0301 - Float(index) * 0.002)
        }
        return hand
    }

    private static func sample(at time: Double, frameTime: Double? = 12.5, left: Bool = true, right: Bool = true) -> MocapHeadsetSample {
        MocapHeadsetSample(
            time: time, frameTime: frameTime,
            head: MocapPose(position: simd_float3(0.1, 1.62, -0.3 + Float(time) * 0.01), rotation: simd_quatf(angle: 0.3, axis: simd_float3(0, 1, 0))),
            hands: [.left: hand(tracked: left, at: simd_float3(-0.2, 1.1, -0.4)), .right: hand(tracked: right, at: simd_float3(0.2, 1.2, -0.35))]
        )
    }

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("headset-\(UUID().uuidString).cmr")
    }

    func testASampleSurvivesItsWireForm() throws {
        let sample = Self.sample(at: 801_234_567.25, left: true, right: false)
        let decoded = try XCTUnwrap(MocapHeadsetSample(data: sample.encode()))

        XCTAssertEqual(decoded.time, sample.time)
        XCTAssertEqual(decoded.frameTime, sample.frameTime)
        XCTAssertEqual(decoded.head, sample.head)
        XCTAssertEqual(decoded.hands.count, 2)
        for side in MocapHandSide.allCases {
            let hand = try XCTUnwrap(decoded.hands[side]), original = try XCTUnwrap(sample.hands[side])
            XCTAssertEqual(hand.isTracked, original.isTracked)
            XCTAssertEqual(hand.wrist, original.wrist)
            XCTAssertEqual(hand.joints.count, MocapHandJoint.allCases.count)
            for joint in MocapHandJoint.allCases {
                // Stored in steps of a hundredth of a millimetre.
                XCTAssertLessThan(try simd_distance(XCTUnwrap(hand.joints[joint]), XCTUnwrap(original.joints[joint])), 1e-5)
            }
        }
    }

    func testASampleWithoutHeadHandsOrFrameSurvivesToo() throws {
        let sample = MocapHeadsetSample(time: 3)
        let decoded = try XCTUnwrap(MocapHeadsetSample(data: sample.encode()))

        XCTAssertEqual(decoded, sample)
        XCTAssertLessThan(sample.encode().count, 20)
    }

    func testACutSampleIsRefused() {
        let data = Self.sample(at: 1).encode()

        XCTAssertNil(MocapHeadsetSample(data: data.prefix(data.count - 3)))
        XCTAssertNil(MocapHeadsetSample(data: Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])))
    }

    func testAJointIsPlacedInTheWorldThroughItsWrist() throws {
        let wrist = MocapPose(position: simd_float3(1, 2, 3), rotation: simd_quatf(angle: .pi / 2, axis: simd_float3(0, 1, 0)))
        let hand = MocapHandSample(isTracked: true, wrist: wrist, joints: [.indexFingerTip: simd_float3(0, 0, 0.1)])

        // A quarter turn about y takes the wrist's z onto the world's x.
        XCTAssertLessThan(try simd_distance(XCTUnwrap(hand.position(of: .indexFingerTip)), simd_float3(1.1, 2, 3)), 1e-6)
        XCTAssertNil(hand.position(of: .thumbTip))
    }

    func testAPoseComesFromATransformAndGoesBack() {
        let pose = MocapPose(position: simd_float3(0.3, -1, 2), rotation: simd_quatf(angle: 1.1, axis: simd_normalize(simd_float3(1, 1, 0))))
        let back = MocapPose(pose.matrix)

        XCTAssertLessThan(simd_distance(back.position, pose.position), 1e-6)
        XCTAssertGreaterThan(abs(simd_dot(back.rotation.vector, pose.rotation.vector)), 0.99999)
    }

    func testARecordingKeepsFramesMarkersAndHeadsetSamplesInOneFile() throws {
        let url = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try MocapRecordingWriter(url: url)
        var frame = MocapFrame(sequence: 1, timestamp: 10, isTracked: true, rootPosition: simd_float3(0, 1, 0), rotations: [.hips: simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))])
        writer.mark("Stand still", at: 10)
        writer.append(Self.sample(at: 100, frameTime: nil))
        writer.append(frame)
        writer.append(Self.sample(at: 100.011, frameTime: 10))
        writer.append(Self.sample(at: 100.022, frameTime: 10))
        frame.sequence = 2
        frame.timestamp = 10.016
        writer.append(frame)
        writer.append(Self.sample(at: 100.033, frameTime: 10.016))
        writer.close()

        XCTAssertEqual(writer.frameCount, 2)
        XCTAssertEqual(writer.headsetSampleCount, 4)
        let all = try MocapRecording.readAll(url: url)
        XCTAssertEqual(all.frames.map(\.sequence), [1, 2])
        XCTAssertEqual(all.markers, [MocapRecording.Marker(time: 10, label: "Stand still")])
        XCTAssertEqual(all.headset.map(\.time), [100, 100.011, 100.022, 100.033])
        XCTAssertEqual(all.headset.map(\.frameTime), [nil, 10, 10, 10.016])
        // The frames alone, as before.
        XCTAssertEqual(try MocapRecording.read(url: url).count, 2)
    }

    func testTheSamplesOfAStretchAreThoseTakenWhileItsFramesShowed() {
        let samples = [8.0, 9.9, 10, 12, 14.99, 15, 20].enumerated().map { Self.sample(at: 100 + Double($0.offset), frameTime: $0.element) }
            + [Self.sample(at: 99, frameTime: nil)]

        XCTAssertEqual(MocapRecording.headset(samples, from: 10, to: 15).map(\.frameTime), [10, 12, 14.99])
    }

    func testTheReportSaysHowMuchEachHandWasSeenAndHowOftenLost() {
        // The left hand is lost twice; the right one never seen.
        let seen = [true, true, false, false, true, true, false, true, true, true]
        let samples = seen.enumerated().map { Self.sample(at: Double($0.offset) / 90, left: $0.element, right: false) }
        let report = MocapRecording.report(headset: samples)

        XCTAssertTrue(report.contains("10 samples"), report)
        XCTAssertTrue(report.contains("left hand: seen 70% of the time, lost 2 time(s)"), report)
        XCTAssertTrue(report.contains("right hand: seen 0% of the time, lost 0 time(s)"), report)
        XCTAssertTrue(report.contains("head: range"), report)
    }
}

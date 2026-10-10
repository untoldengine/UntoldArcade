//
//  MocapReplayTests.swift
//  CoolMirrorTests
//
//  Real sessions recorded on the headset (Recordings/*.cmr: every frame
//  the iPhone sent, with a marker per guided step), replayed through the
//  smoothing filter the mirror uses. What the wearer saw jump must stay
//  steady here.
//

@testable import CoolMirror
@testable import CoolMirrorMocap
import simd
import XCTest

final class MocapReplayTests: XCTestCase {
    private static func recording(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Recordings/\(name).cmr")
    }

    /// The mirror's smoothing options for the panel's default sliders.
    private static var options: MocapSmoothingOptions {
        var options = MocapSmoothingOptions()
        options.bodyCutoff = 8 * powf(0.03, 0.4)
        options.legCutoff = 8 * powf(0.03, 0.6)
        options.rootCutoff = options.legCutoff * 0.6
        return options
    }

    private struct Replay {
        var raw: [MocapFrame]
        var filtered: [MocapFrame]
        var markers: [MocapRecording.Marker]

        func stretch(_ label: String) -> Range<Int> {
            let sorted = markers.sorted { $0.time < $1.time }
            guard let index = sorted.firstIndex(where: { $0.label.hasPrefix(label) }) else { return 0 ..< 0 }
            let start = sorted[index].time
            let end = index + 1 < sorted.count ? sorted[index + 1].time : .infinity
            let first = raw.firstIndex { $0.timestamp >= start } ?? raw.count
            let last = raw.firstIndex { $0.timestamp >= end } ?? raw.count
            return first ..< last
        }
    }

    private func replay(_ name: String) throws -> Replay? {
        let url = Self.recording(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let all = try MocapRecording.readAll(url: url)
        var filter = MocapPoseFilter()
        let options = Self.options
        let filtered = all.frames.map { filter.filter($0, at: $0.timestamp, options: options) }
        return Replay(raw: all.frames, filtered: filtered, markers: all.markers)
    }

    /// Hip heading in world space, degrees.
    private static func heading(_ frame: MocapFrame) -> Float? {
        MocapPoseFilter.bodyYaw(of: frame).map { $0 * 180 / .pi }
    }

    /// Headings unwrapped so a range across ±180° reads right.
    private static func headings(_ frames: ArraySlice<MocapFrame>) -> [Float] {
        var out: [Float] = []
        for frame in frames {
            guard let h = heading(frame) else { continue }
            if let last = out.last {
                var d = h - last
                while d > 180 {
                    d -= 360
                }
                while d < -180 {
                    d += 360
                }
                out.append(last + d)
            } else {
                out.append(h)
            }
        }
        return out
    }

    private static func range(_ values: [Float]) -> Float {
        (values.max() ?? 0) - (values.min() ?? 0)
    }

    private static func largestStep(_ values: [Float]) -> Float {
        zip(values.dropFirst(), values).map { abs($0 - $1) }.max() ?? 0
    }

    /// Session of 2026-09-27: standing still the tracker's hip heading
    /// wandered 23° and its root 3 mm a frame; raising the arms turned the
    /// whole skeleton 37° in one frame for three seconds, and back; a real
    /// turn of about 100° to the left and back was made on the spot.
    func testSessionStaysSteadyWhereTheWearerDidAndFollowsTheRealTurn() throws {
        guard let session = try replay("session-20260927-190849") else { throw XCTSkip("recording not present") }
        XCTAssertEqual(session.raw.count, 2689)

        // Standing still: the heading stays within a few degrees and never steps.
        let still = session.stretch("Stand still, arms down")
        let stillRaw = Self.headings(session.raw[still]), stillFiltered = Self.headings(session.filtered[still])
        XCTAssertGreaterThan(Self.range(stillRaw), 20, "the tracker did wander")
        XCTAssertLessThan(Self.range(stillFiltered), 12, "the character does not")
        XCTAssertLessThan(Self.largestStep(stillFiltered), 1.0, "no visible step while standing still")

        // Raising the arms: the 37° flip is held, nothing steps by more than a few degrees.
        let arms = session.stretch("Raise both arms")
        let armsRaw = Self.headings(session.raw[arms]), armsFiltered = Self.headings(session.filtered[arms])
        XCTAssertGreaterThan(Self.largestStep(armsRaw), 30, "the tracker did flip")
        XCTAssertLessThan(Self.largestStep(armsFiltered), 5, "the character never flips")
        // During the three seconds the tracker sat 37° off, the character kept its heading.
        let t0 = session.raw[0].timestamp
        let during = session.raw.indices.filter { session.raw[$0].timestamp - t0 > 22.6 && session.raw[$0].timestamp - t0 < 25.3 }
        let before = session.raw.indices.filter { session.raw[$0].timestamp - t0 > 21.5 && session.raw[$0].timestamp - t0 < 22.4 }
        let heldHeadings = during.compactMap { Self.heading(session.filtered[$0]) }
        let beforeMean = before.compactMap { Self.heading(session.filtered[$0]) }.reduce(0, +) / Float(max(before.count, 1))
        for h in heldHeadings {
            XCTAssertLessThan(abs(h - beforeMean), 4, "held through the flip")
        }

        // The real turn is followed almost in full.
        let turn = session.stretch("Turn to your left")
        let turnRaw = Self.headings(session.raw[turn]), turnFiltered = Self.headings(session.filtered[turn])
        XCTAssertGreaterThan(Self.range(turnRaw), 90)
        // (The last twenty degrees of this turn came slowly, at 10°/s, and
        // are followed only after two seconds: the price of not following
        // the tracker's wander with the arms up, which drifts at that rate.)
        XCTAssertGreaterThan(Self.range(turnFiltered), 0.7 * Self.range(turnRaw), "a real turn is not a glitch")

        // Nowhere does the heading step by more than a few degrees between frames.
        let whole = Self.headings(session.filtered[...])
        XCTAssertLessThan(Self.largestStep(whole), 9)
    }

    /// Session of 2026-09-27, latest: the tracker's heading drifted 27°
    /// and back over three seconds with the arms going up, at 20°/s, with
    /// both feet on the floor; a real 70° turn on the spot at 45°/s.
    func testThirdSessionIgnoresTheArmsUpWanderAndFollowsTheTurn() throws {
        guard let session = try replay("session-20260927-202923") else { throw XCTSkip("recording not present") }

        let still = session.stretch("Stand still, arms down")
        XCTAssertLessThan(Self.range(Self.headings(session.filtered[still])), 6)
        XCTAssertLessThan(Self.largestStep(Self.headings(session.filtered[still])), 0.5)

        // With the arms going up (20–24 s) the tracker wandered 27°; the character stays put.
        let t0 = session.raw[0].timestamp
        let wander = session.raw.indices.filter { session.raw[$0].timestamp - t0 > 20 && session.raw[$0].timestamp - t0 < 24 }
        let wanderRaw = Self.headings(ArraySlice(wander.map { session.raw[$0] }))
        let wanderFiltered = Self.headings(ArraySlice(wander.map { session.filtered[$0] }))
        XCTAssertGreaterThan(Self.range(wanderRaw), 20, "the tracker did wander")
        XCTAssertLessThan(Self.range(wanderFiltered), 12, "the character does not")

        // The turn on the spot is followed, within a few frames.
        let turn = session.stretch("Turn to your left")
        XCTAssertGreaterThan(Self.range(Self.headings(session.filtered[turn])), 50)
        XCTAssertLessThan(Self.largestStep(Self.headings(session.filtered[turn])), 4)
    }

    /// Session of 2026-09-27, later: ten frames the tracker lost (they
    /// once let the raw skeleton through for a frame, a 29° spike); the
    /// tracker's heading toggling between two readings 30° apart while
    /// the arms went up; a fast turn back to the phone that the tracker
    /// reported as a snap and that must still be followed.
    func testSecondSessionHasNoSpikesAndFollowsTheTurnBack() throws {
        guard let session = try replay("session-20260927-200725") else { throw XCTSkip("recording not present") }
        XCTAssertEqual(session.raw.filter { !$0.isTracked }.count, 10)

        let still = session.stretch("Stand still, arms down")
        XCTAssertLessThan(Self.range(Self.headings(session.filtered[still])), 12)
        XCTAssertLessThan(Self.largestStep(Self.headings(session.filtered[still])), 1.0)

        let arms = session.stretch("Raise both arms")
        XCTAssertGreaterThan(Self.largestStep(Self.headings(session.raw[arms])), 15, "the tracker did snap")
        XCTAssertLessThan(Self.largestStep(Self.headings(session.filtered[arms])), 6, "the character never snaps")
        // The hands never jump either (the lost frames used to throw them 40 cm).
        var largestHandStep: Float = 0
        for index in arms.dropFirst() {
            for joint in [MocapJoint.leftHand, .rightHand] {
                guard let a = session.filtered[index - 1].positions[joint], let b = session.filtered[index].positions[joint],
                      let ra = session.filtered[index - 1].rotations[.root], let rb = session.filtered[index].rotations[.root]
                else { continue }
                let wa = ra.act(a) + session.filtered[index - 1].rootPosition, wb = rb.act(b) + session.filtered[index].rootPosition
                largestHandStep = max(largestHandStep, simd_length(wb - wa))
            }
        }
        XCTAssertLessThan(largestHandStep, 0.08)

        // The turn: a real 50° turn left and the fast turn back are followed.
        let turn = session.stretch("Turn to your left")
        XCTAssertGreaterThan(Self.range(Self.headings(session.filtered[turn])), 40)

        // Nowhere does the heading step by more than the rate limit allows
        // (the fast turn back runs at it).
        let whole = Self.headings(session.filtered[...])
        XCTAssertLessThan(Self.largestStep(whole), 12)
    }

    // MARK: - Arm reach

    /// The hands' reach targets over a stretch, for a character with
    /// wider shoulders, a longer torso and longer arms than the wearer,
    /// standing as calibrated: per frame the step of each target and of
    /// the captured hand it follows.
    private func reachSteps(_ session: Replay, _ stretch: Range<Int>) throws -> (target: [Float], hand: [Float], scale: Float) {
        let retargeter = MocapRetargeter(mapping: MocapRigMapping(joints: [:], rootJoint: "hips"))
        let calibration = try XCTUnwrap(session.filtered[stretch].first { $0.isTracked })
        retargeter.calibrate(with: calibration)
        let standing = try XCTUnwrap(retargeter.retarget(calibration)).capturedJointPositions
        var rig: [MocapJoint: simd_float3] = [:]
        for joint in MocapArmReach.joints {
            let p = try XCTUnwrap(standing[joint])
            rig[joint] = simd_float3(p.x * 1.3, p.y * 1.1, p.z)
        }
        func armLength(_ positions: [MocapJoint: simd_float3], _ arm: (shoulder: MocapJoint, elbow: MocapJoint, hand: MocapJoint)) -> Float {
            simd_distance(positions[arm.shoulder]!, positions[arm.elbow]!) + simd_distance(positions[arm.elbow]!, positions[arm.hand]!)
        }
        let scale: Float = 1.25
        var lengths: [MocapJoint: Float] = [:]
        for arm in MocapArmReach.arms {
            lengths[arm.shoulder] = armLength(standing, arm) * scale
        }

        let solver = MocapArmReach()
        var previous: (targets: [MocapJoint: simd_float3], hands: [MocapJoint: simd_float3])?
        var targetSteps: [Float] = [], handSteps: [Float] = []
        for frame in session.filtered[stretch] where frame.isTracked {
            let captured = try XCTUnwrap(retargeter.retarget(frame)).capturedJointPositions
            let targets = solver.targets(captured: captured, rig: rig, rigArmLength: lengths)
            var hands: [MocapJoint: simd_float3] = [:]
            for arm in MocapArmReach.arms {
                hands[arm.shoulder] = captured[arm.hand]
            }
            if let previous {
                for arm in MocapArmReach.arms {
                    guard let a = targets[arm.shoulder], let b = previous.targets[arm.shoulder],
                          let c = hands[arm.shoulder], let d = previous.hands[arm.shoulder]
                    else { continue }
                    targetSteps.append(simd_distance(a, b))
                    handSteps.append(simd_distance(c, d))
                }
            }
            previous = (targets, hands)
        }
        return (targetSteps, handSteps, scale)
    }

    /// Raising the arms takes the hands from beside the hips past the
    /// chest and the head: the anchors hand over all the way, and the
    /// targets must move like the hands do, scaled to the character's
    /// reach, without adding steps of their own.
    func testReachTargetsMoveLikeTheCapturedHands() throws {
        guard let session = try replay("session-20260927-190849") else { throw XCTSkip("recording not present") }
        for label in ["Stand still, arms down", "Raise both arms"] {
            let steps = try reachSteps(session, session.stretch(label))
            XCTAssertGreaterThan(steps.target.count, 100)
            let target = steps.target.sorted(), hand = steps.hand.sorted()
            let allowed = steps.scale * 1.1
            XCTAssertLessThan(try XCTUnwrap(target.last), try XCTUnwrap(hand.last) * allowed, label)
            XCTAssertLessThan(target[target.count * 99 / 100], hand[hand.count * 99 / 100] * allowed, label)
            XCTAssertLessThan(target.reduce(0, +), hand.reduce(0, +) * allowed, label)
        }
    }

    // MARK: - Body anchor

    private struct Anchored {
        /// Per frame, across the floor: the hips with the body held by
        /// head and feet, the hips with the planted foot alone holding it
        /// (the head then swings by what the phone imagines), the head in
        /// that case, the head as the headset would have it, and how far
        /// the legs reach to the held feet.
        var hips: [simd_float2] = []
        var footHeldHead: [simd_float2] = []
        var head: [simd_float2] = []
        var legReach: [Float] = []
        var times: [TimeInterval] = []

        /// How fast the hips move under the head, per frame (m/s).
        var hipSpeeds: [Float] {
            (1 ..< max(hips.count, 1)).map { i in
                let dt = Float(max(times[i] - times[i - 1], 1.0 / 60))
                return simd_distance(hips[i] - head[i], hips[i - 1] - head[i - 1]) / dt
            }
        }

        /// The fastest a held foot crept, over half a second or more (m/s).
        var pinSpeed: Float = 0
        var tilt: [Float] = []
    }

    /// One update of the mirror: the phone's frame it showed, filtered,
    /// and the headset's pose then (nil in the sessions recorded before
    /// the headset was).
    private struct Tick {
        var time: TimeInterval
        var frame: MocapFrame
        var headset: simd_float4x4?
        var hands: [MocapHandSide: MocapHandSample] = [:]
    }

    /// A stretch of a session recorded before the headset was. The head
    /// is simulated: where the phone saw it, averaged over a second either
    /// side (what the phone gets wrong about the body's depth wanders much
    /// faster than a standing head moves).
    private func anchored(_ session: Replay, _ stretch: Range<Int>) throws -> Anchored {
        try anchored(session.filtered[stretch].filter(\.isTracked).map { Tick(time: $0.timestamp, frame: $0) })
    }

    /// A session recorded with the headset, as the mirror ran it: one
    /// update per frame the headset rendered, showing the newest frame of
    /// the phone's, filtered at the headset's clock.
    private func ticks(_ name: String) throws -> (ticks: [Tick], frameTimes: [Double], markers: [MocapRecording.Marker])? {
        let url = Self.recording(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let all = try MocapRecording.readAll(url: url)
        var frames: [Double: MocapFrame] = [:]
        for frame in all.frames {
            frames[frame.timestamp] = frame
        }
        var filter = MocapPoseFilter()
        let options = Self.options
        var ticks: [Tick] = []
        var times: [Double] = []
        for sample in all.headset {
            guard let time = sample.frameTime, let frame = frames[time], let head = sample.head else { continue }
            let filtered = filter.filter(frame, at: sample.time, options: options)
            guard filtered.isTracked else { continue }
            ticks.append(Tick(time: sample.time, frame: filtered, headset: head.matrix, hands: sample.hands))
            times.append(time)
        }
        return (ticks, times, all.markers.sorted { $0.time < $1.time })
    }

    /// The updates of a marked stretch.
    private func stretch(_ label: String, of session: (ticks: [Tick], frameTimes: [Double], markers: [MocapRecording.Marker])) -> [Tick] {
        guard let index = session.markers.firstIndex(where: { $0.label.hasPrefix(label) }) else { return [] }
        let start = session.markers[index].time
        let end = index + 1 < session.markers.count ? session.markers[index + 1].time : .infinity
        return zip(session.ticks, session.frameTimes).filter { $0.1 >= start && $0.1 < end }.map(\.0)
    }

    /// Replays updates with a character of the wearer's own proportions,
    /// calibrated on the first.
    private func anchored(_ ticks: [Tick]) throws -> Anchored {
        let frames = ticks.map(\.frame)
        let calibration = try XCTUnwrap(frames.first)
        var track = MocapHeadTrack()
        if let headset = ticks.first?.headset {
            track.calibrate(with: headset)
        }
        var names: [MocapJoint: String] = [:]
        for joint in MocapJoint.allCases {
            names[joint] = "\(joint)"
        }
        let retargeter = MocapRetargeter(mapping: MocapRigMapping(joints: names, rootJoint: "hips"))
        retargeter.calibrate(with: calibration)
        let standing = try XCTUnwrap(retargeter.retarget(calibration)).capturedJointPositions
        // The character stands as the wearer did, feet level on the floor.
        var rest: [MocapJoint: simd_float3] = [:]
        for (joint, position) in standing {
            rest[driven(joint)] = position
        }
        var byName: [String: simd_float3] = [:]
        for (joint, position) in rest {
            byName["\(joint)"] = position
        }
        retargeter.rigRestPositions = byName
        let restRoot = try XCTUnwrap(rest[.hips])
        let share = MocapBodyAnchor.hipShare(rest: rest)

        struct Sample {
            var time: TimeInterval
            var pose: MocapBodyAnchor.Pose
            var head: simd_float3
            var feet: [MocapJoint: simd_float3]
            var root: simd_float3
            /// How far the headset says the head went, in the rig's space.
            var moved: simd_float3?
        }
        var samples: [Sample] = []
        for tick in ticks {
            let frame = tick.frame
            let result = try XCTUnwrap(retargeter.retarget(frame))
            var deltas: [MocapJoint: simd_quatf] = [:]
            for (joint, name) in names {
                deltas[joint] = result.worldRotationDeltas[name]
            }
            guard let pose = MocapBodyAnchor.pose(rest: rest, deltas: deltas),
                  let head = result.capturedJointPositions[.head]
            else { continue }
            var feet: [MocapJoint: simd_float3] = [:]
            for foot in MocapFootAnchor.feet {
                feet[foot] = result.capturedJointPositions[driven(foot)]
            }
            var moved = tick.headset.flatMap { track.displacement(of: $0) }
            if MocapRetargetOptions().mirror {
                moved?.x *= -1
            }
            samples.append(Sample(time: tick.time, pose: pose, head: head, feet: feet, root: result.rootTranslationDelta, moved: moved))
        }

        func flat(_ v: simd_float3) -> simd_float2 {
            simd_float2(v.x, v.z)
        }
        var out = Anchored()
        var foot = MocapFootAnchor()
        var body = MocapBodyAnchor()
        var shown: [MocapJoint: simd_float3] = [:]
        var first: [MocapJoint: (position: simd_float3, time: TimeInterval)] = [:]
        var held: (foot: MocapJoint, position: simd_float3)?
        var headRest: simd_float3?
        for sample in samples {
            let head: simd_float3
            if let moved = sample.moved {
                // As the mirror does: the first update continues where
                // the phone's root is.
                let rest = headRest ?? restRoot + sample.pose.head + simd_float3(sample.root.x, 0, sample.root.z) - simd_float3(moved.x, 0, moved.z)
                headRest = rest
                head = rest + moved
            } else {
                let near = samples.filter { abs($0.time - sample.time) <= 1 }
                head = near.reduce(simd_float3.zero) { $0 + $1.head } / Float(near.count)
            }
            var floor: [MocapJoint: Float] = [:]
            for joint in MocapFootAnchor.feet {
                floor[joint] = rest[joint]?.y
            }
            _ = foot.update(captured: sample.feet, root: sample.root, rig: shown, floor: floor, time: sample.time, horizontal: false)
            let output = body.update(
                pose: sample.pose, restRoot: restRoot, head: head, planted: foot.planted,
                composed: shown, hipShare: share, time: sample.time
            )
            // What is shown: the pose's feet, pulled to their holds.
            for joint in MocapFootAnchor.feet {
                guard let leg = sample.pose.feet[joint] else { continue }
                var position = restRoot + output.root + leg
                if let pin = output.pins[joint] {
                    let reach = flat(pin.position) - flat(position)
                    out.legReach.append(simd_length(reach) * pin.weight)
                    position.x += reach.x * pin.weight
                    position.z += reach.y * pin.weight
                    if pin.held, let start = first[joint] {
                        out.pinSpeed = max(out.pinSpeed, simd_distance(flat(pin.position), flat(start.position)) / Float(max(sample.time - start.time, 0.5)))
                    } else if pin.held {
                        first[joint] = (pin.position, sample.time)
                    } else {
                        first[joint] = nil
                    }
                } else {
                    first[joint] = nil
                }
                shown[joint] = position
            }
            out.hips.append(flat(restRoot + output.root))
            out.times.append(sample.time)
            out.head.append(flat(head))
            out.tilt.append(output.torsoTilt.angle * 180 / .pi)

            // Today: the planted foot alone holds the body.
            if held == nil || !foot.planted.contains(held!.foot) {
                held = nil
                if let joint = MocapFootAnchor.feet.first(where: { foot.planted.contains($0) }), let leg = sample.pose.feet[joint] {
                    let last = out.footHeldHead.last.map { simd_float3($0.x, 0, $0.y) } ?? head
                    held = (joint, last - sample.pose.head + leg)
                }
            }
            if let held, let leg = sample.pose.feet[held.foot] {
                out.footHeldHead.append(flat(held.position - leg + sample.pose.head))
            } else {
                out.footHeldHead.append(out.footHeldHead.last ?? flat(head))
            }
        }
        return out
    }

    /// The captured joint that drives a rig joint (or the other way
    /// round): the opposite one, in a mirror.
    private func driven(_ joint: MocapJoint) -> MocapJoint {
        MocapRetargetOptions().mirror ? joint.mirrored : joint
    }

    private static func span(_ points: [simd_float2]) -> Float {
        guard let first = points.first else { return 0 }
        var low = first, high = first
        for point in points {
            low = simd_min(low, point)
            high = simd_max(high, point)
        }
        return simd_length(high - low)
    }

    /// Standing still, the planted foot alone lets the head swing by what
    /// the phone imagines about the body's depth (16 to 18 cm in these
    /// sessions). Held at both ends the head is the headset's, the feet
    /// creep a centimetre a second at most, and what is left for the
    /// hips, the torso and the legs to make up is small.
    func testStandingStillTheBodyIsHeldBetweenHeadAndFeet() throws {
        for name in ["session-20260927-190849", "session-20260927-200725", "session-20260927-202923"] {
            guard let session = try replay(name) else { throw XCTSkip("recording not present") }
            let run = try anchored(session, session.stretch("Stand still, arms down"))
            XCTAssertGreaterThan(run.hips.count, 400, name)
            XCTAssertGreaterThan(Self.span(run.footHeldHead), 0.15, "\(name): held by the foot alone the head swings")
            XCTAssertLessThan(Self.span(run.hips), 0.09, name)
            let reach = run.legReach.sorted()
            XCTAssertLessThan(reach[reach.count * 95 / 100], 0.06, name)
            XCTAssertLessThan(try XCTUnwrap(run.tilt.max()), 4, name)
            XCTAssertLessThan(run.pinSpeed, 0.0101, name)
            let speeds = run.hipSpeeds.sorted()
            XCTAssertLessThan(speeds[speeds.count * 95 / 100], 0.15, name)
        }
    }

    /// Whatever the wearer does (a foot lifted, the arms raised while the
    /// tracker flips, steps, a turn), the corrections stay those of a
    /// lean: the legs reach a hand's width at most, the torso tilts a few
    /// degrees, and a held foot never slides.
    func testTheCorrectionsStayThoseOfALean() throws {
        for name in ["session-20260927-190849", "session-20260927-200725", "session-20260927-202923"] {
            guard let session = try replay(name) else { throw XCTSkip("recording not present") }
            for label in ["Lift your LEFT", "Put it down", "Raise both arms", "Take two steps", "Turn to your left"] {
                let run = try anchored(session, session.stretch(label))
                let note = "\(name) \(label)"
                XCTAssertGreaterThan(run.hips.count, 200, note)
                XCTAssertLessThan(try XCTUnwrap(run.legReach.max()), 0.2, note)
                XCTAssertLessThan(try XCTUnwrap(run.tilt.max()), 10, note)
                XCTAssertLessThan(run.pinSpeed, 0.0101, note)
            }
        }
    }

    // MARK: - With the headset

    /// Session of 2026-09-28, the first recorded with the headset: ten
    /// guided steps, the phone's frames and the headset's head and hands
    /// at every frame it rendered.
    private static let withHeadset = "session-20260928-201728"

    func testTheRecordingHoldsWhatTheHeadsetSaw() throws {
        let url = Self.recording(Self.withHeadset)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("recording not present") }
        let all = try MocapRecording.readAll(url: url)
        XCTAssertEqual(all.frames.count, 3937)
        XCTAssertEqual(all.markers.count, 10)
        XCTAssertEqual(all.headset.count, 6606)
        XCTAssertTrue(all.headset.allSatisfy { $0.head != nil })
        // A sample every hundredth of a second, each naming a frame of the phone's.
        let steps = zip(all.headset.dropFirst(), all.headset).map { $0.time - $1.time }
        XCTAssertLessThan(try XCTUnwrap(steps.max()), 0.015)
        let times = Set(all.frames.map(\.timestamp))
        // (The first few name the frame that was showing when the
        // recording started, which is not in it.)
        let first = try XCTUnwrap(all.frames.first).timestamp
        XCTAssertTrue(all.headset.compactMap(\.frameTime).allSatisfy { times.contains($0) || $0 < first })
        XCTAssertLessThan(all.headset.filter { $0.frameTime.map { $0 < first } ?? true }.count, 10)

        // Arms down, looking ahead: the headset sees both hands, 70 cm
        // below it. Behind the back it loses them, and keeps them
        // in the samples where it last saw them.
        let markers = all.markers.sorted { $0.time < $1.time }
        let last = MocapRecording.headset(all.headset, from: markers[9].time, to: .infinity)
        XCTAssertTrue(last.allSatisfy { $0.hands[.left]?.isTracked == true && $0.hands[.right]?.isTracked == true })
        for sample in last {
            let head = try XCTUnwrap(sample.head), wrist = try XCTUnwrap(sample.hands[.left]).wrist
            XCTAssertEqual(wrist.position.y - head.position.y, -0.72, accuracy: 0.05)
        }
        let behind = MocapRecording.headset(all.headset, from: markers[7].time + 3, to: markers[8].time)
        XCTAssertGreaterThan(behind.count, 400)
        XCTAssertTrue(behind.allSatisfy { sample in
            MocapHandSide.allCases.allSatisfy { sample.hands[$0].map { !$0.isTracked } ?? false }
        })
    }

    /// The head's travel as the headset has it and as the phone has it,
    /// both in the calibrated body's axes: along `axis` over a stretch,
    /// how they correlate and the phone's travel per metre of the
    /// headset's.
    private func agreement(_ ticks: [Tick], calibration: Tick, axis: KeyPath<simd_float3, Float>) throws -> (correlation: Float, slope: Float, headset: Float, phone: Float) {
        let retargeter = MocapRetargeter(mapping: MocapRigMapping(joints: [:], rootJoint: "hips"))
        retargeter.options.mirror = false
        retargeter.calibrate(with: calibration.frame)
        var track = MocapHeadTrack()
        try track.calibrate(with: XCTUnwrap(calibration.headset))
        var headset: [Float] = [], phone: [Float] = []
        for tick in ticks {
            guard let pose = tick.headset, let moved = track.displacement(of: pose),
                  let head = retargeter.retarget(tick.frame)?.capturedJointPositions[.head]
            else { continue }
            headset.append(moved[keyPath: axis])
            phone.append(head[keyPath: axis])
        }
        let meanHeadset = headset.reduce(0, +) / Float(headset.count), meanPhone = phone.reduce(0, +) / Float(phone.count)
        var both: Float = 0, a: Float = 0, b: Float = 0
        for (h, p) in zip(headset, phone) {
            both += (h - meanHeadset) * (p - meanPhone)
            a += (h - meanHeadset) * (h - meanHeadset)
            b += (p - meanPhone) * (p - meanPhone)
        }
        return try (
            both / max((a * b).squareRoot(), 1e-9), both / max(a, 1e-9),
            XCTUnwrap(headset.max()) - XCTUnwrap(headset.min()), XCTUnwrap(phone.max()) - XCTUnwrap(phone.min())
        )
    }

    /// Where the wearer really moves, the two agree on the way: shifting
    /// the weight to lift a foot goes sideways for both, stepping toward
    /// the phone goes forward for both. How far, the phone overstates.
    /// Where the wearer stands still, the headset says so (the head stays
    /// within 3 cm) and the phone has it wander three times that.
    func testTheHeadsetAndThePhoneAgreeOnWhichWayTheHeadGoes() throws {
        guard let session = try ticks(Self.withHeadset) else { throw XCTSkip("recording not present") }
        let calibration = try XCTUnwrap(stretch("Stand still, arms down", of: session).first)

        let sideways = try agreement(stretch("Put it down", of: session), calibration: calibration, axis: \.x)
        XCTAssertGreaterThan(sideways.headset, 0.3)
        XCTAssertGreaterThan(sideways.correlation, 0.95)
        XCTAssertEqual(sideways.slope, 1.2, accuracy: 0.3)

        let forward = try agreement(stretch("Take two steps", of: session), calibration: calibration, axis: \.z)
        XCTAssertGreaterThan(forward.headset, 0.6)
        XCTAssertGreaterThan(forward.correlation, 0.9)
        XCTAssertEqual(forward.slope, 1.1, accuracy: 0.3)

        let still = try agreement(stretch("Stand still, arms down", of: session), calibration: calibration, axis: \.z)
        XCTAssertLessThan(still.headset, 0.03)
        XCTAssertGreaterThan(still.phone, 0.05)
        // Raising the arms moves the head 4 cm; the phone makes it 45.
        let arms = try agreement(stretch("Raise both arms", of: session), calibration: calibration, axis: \.z)
        XCTAssertLessThan(arms.headset, 0.05)
        XCTAssertGreaterThan(arms.phone, 0.4)
    }

    /// Standing still with the head the headset recorded: it stays within
    /// 3 cm, where the planted foot alone would have let it swing 15. The
    /// hips keep a wander of the phone's, in depth (it cannot tell how
    /// far the hips are from it), the legs and the torso make up the rest.
    func testStandingStillWithTheHeadsetsHead() throws {
        guard let session = try ticks(Self.withHeadset) else { throw XCTSkip("recording not present") }
        let run = try anchored(stretch("Stand still, arms down", of: session))
        XCTAssertGreaterThan(run.hips.count, 700)
        XCTAssertLessThan(Self.span(run.head), 0.03)
        XCTAssertGreaterThan(Self.span(run.footHeldHead), 0.12)
        XCTAssertLessThan(Self.span(run.hips), 0.1)
        let sideways = zip(run.hips, run.head).map { $0.x - $1.x }
        XCTAssertLessThan(try XCTUnwrap(sideways.max()) - XCTUnwrap(sideways.min()), 0.04)
        let reach = run.legReach.sorted()
        XCTAssertLessThan(reach[reach.count * 95 / 100], 0.08)
        XCTAssertLessThan(try XCTUnwrap(run.tilt.max()), 5)
        XCTAssertLessThan(run.pinSpeed, 0.0101)
    }

    func testTheCorrectionsStayThoseOfALeanWithTheHeadsetsHead() throws {
        guard let session = try ticks(Self.withHeadset) else { throw XCTSkip("recording not present") }
        for marker in session.markers.dropFirst().dropLast() {
            let run = try anchored(stretch(marker.label, of: session))
            XCTAssertGreaterThan(run.hips.count, 400, marker.label)
            XCTAssertLessThan(try XCTUnwrap(run.legReach.max()), 0.2, marker.label)
            XCTAssertLessThan(try XCTUnwrap(run.tilt.max()), 12, marker.label)
            XCTAssertLessThan(run.pinSpeed, 0.0101, marker.label)
        }
    }

    // MARK: - Hands

    private struct HandRun {
        var outputs: [MocapJoint: [MocapHandLadder.Output]] = [:]
        /// Per update and hand, from the head: where the headset has it
        /// (nil while it does not see it) and where the phone has it.
        var headset: [MocapJoint: [simd_float3?]] = [:]
        var phone: [MocapJoint: [simd_float3]] = [:]
        var times: [TimeInterval] = []
        var scale: Float = 1
    }

    /// The whole session through the ladder, as the mirror runs it.
    private func hands(_ session: (ticks: [Tick], frameTimes: [Double], markers: [MocapRecording.Marker])) throws -> HandRun {
        let retargeter = MocapRetargeter(mapping: MocapRigMapping(joints: [:], rootJoint: "hips"))
        let calibration = try XCTUnwrap(session.ticks.first)
        retargeter.calibrate(with: calibration.frame)
        var track = MocapHeadTrack()
        try track.calibrate(with: XCTUnwrap(calibration.headset))
        var ladder = MocapHandLadder()
        var run = HandRun()
        for tick in session.ticks {
            guard let pose = tick.headset, let captured = retargeter.retarget(tick.frame)?.capturedJointPositions,
                  let head = captured[.head]
            else { continue }
            var inputs: [MocapJoint: MocapHandLadder.Input] = [:]
            for (joint, side) in [(MocapJoint.leftHand, MocapHandSide.right), (.rightHand, .left)] {
                guard let phone = captured[driven(joint)] else { continue }
                var seen: simd_float3?
                if let hand = tick.hands[side], hand.isTracked {
                    var v = track.inBodyAxes(hand.wrist.position - track.joint(pose))
                    v.x = -v.x
                    seen = v
                }
                inputs[joint] = .init(headset: seen, phone: phone - head)
                run.phone[joint, default: []].append(phone - head)
            }
            let outputs = ladder.update(inputs, time: tick.time)
            guard outputs.count == 2 else { continue }
            for (joint, output) in outputs {
                run.outputs[joint, default: []].append(output)
                run.headset[joint, default: []].append(inputs[joint]?.headset.map { $0 * ladder.scale })
            }
            run.times.append(tick.time)
        }
        run.scale = ladder.scale
        return run
    }

    /// The hands of the session with the headset: it lost them 24 times,
    /// behind the back, in the turn and for tenths of a second at the
    /// edge of its view. Through every change of source the character's
    /// hands move no faster than the hands did; while the headset sees a
    /// hand, the hand is where the headset has it.
    func testTheHandsChangeSourceWithoutShowingIt() throws {
        guard let session = try ticks(Self.withHeadset) else { throw XCTSkip("recording not present") }
        let run = try hands(session)
        XCTAssertGreaterThan(run.times.count, 6000)
        // The phone's skeleton is a tenth larger than the wearer.
        XCTAssertEqual(run.scale, 1.1, accuracy: 0.05)

        var losses = 0, handovers = 0
        for joint in [MocapJoint.leftHand, .rightHand] {
            let outputs = try XCTUnwrap(run.outputs[joint]), headset = try XCTUnwrap(run.headset[joint])
            var changed = 0
            var onHeadset = 0
            var ownStep: Float = 0
            for index in 1 ..< outputs.count {
                let step = simd_distance(outputs[index].position, outputs[index - 1].position)
                if let now = headset[index], let before = headset[index - 1] {
                    ownStep = max(ownStep, simd_distance(now, before))
                } else if headset[index - 1] != nil {
                    losses += 1
                }
                if outputs[index].source != outputs[index - 1].source {
                    changed = index
                    handovers += 1
                    XCTAssertLessThan(step, 0.015, "\(joint) at \(run.times[index] - run.times[0]) s")
                }
                guard outputs[index].source != .phone else { continue }
                onHeadset += 1
                // No faster than the hand itself went at its fastest,
                // give or take what a handover has left to make up.
                XCTAssertLessThan(step, 0.06, "\(joint) at \(run.times[index] - run.times[0]) s")
                if index - changed > 50, outputs[index].source == .headset, let seen = headset[index] {
                    XCTAssertLessThan(simd_distance(outputs[index].position, seen), 0.01)
                }
            }
            XCTAssertGreaterThan(ownStep, 0.025, "the hands did move")
            XCTAssertGreaterThan(Float(onHeadset) / Float(outputs.count), 0.55)
        }
        XCTAssertEqual(losses, 24)
        XCTAssertGreaterThan(handovers, 40)
    }

    // MARK: - Legs

    /// The bend of the rig's knees over a stretch (degrees, left and
    /// right), for a rig of the wearer's proportions whose legs are
    /// straight at rest, calibrated on `calibration`.
    private func kneeBends(_ ticks: [Tick], calibration: Tick) throws -> [(left: Float, right: Float)] {
        var names: [MocapJoint: String] = [:]
        for joint in MocapJoint.allCases {
            names[joint] = "\(joint)"
        }
        let retargeter = MocapRetargeter(mapping: MocapRigMapping(joints: names, rootJoint: "hips"))
        retargeter.calibrate(with: calibration.frame)
        let standing = try XCTUnwrap(retargeter.retarget(calibration.frame)).capturedJointPositions
        var rest: [MocapJoint: simd_float3] = [:]
        for (joint, position) in standing {
            rest[driven(joint)] = position
        }
        let legs: [(hip: MocapJoint, knee: MocapJoint, ankle: MocapJoint)] = [(.leftUpLeg, .leftLeg, .leftFoot), (.rightUpLeg, .rightLeg, .rightFoot)]
        for leg in legs {
            let hip = try XCTUnwrap(rest[leg.hip]), knee = try XCTUnwrap(rest[leg.knee]), ankle = try XCTUnwrap(rest[leg.ankle])
            let straightKnee = hip - simd_float3(0, simd_distance(hip, knee), 0)
            rest[leg.knee] = straightKnee
            rest[leg.ankle] = straightKnee - simd_float3(0, simd_distance(knee, ankle), 0)
        }
        var byName: [String: simd_float3] = [:]
        for (joint, position) in rest {
            byName["\(joint)"] = position
        }
        retargeter.rigRestPositions = byName

        return try ticks.map { tick in
            let deltas = try XCTUnwrap(retargeter.retarget(tick.frame)).worldRotationDeltas
            let bends = try legs.map { leg -> Float in
                let thigh = try XCTUnwrap(deltas["\(leg.hip)"]), shin = try XCTUnwrap(deltas["\(leg.knee)"])
                let down = simd_float3(0, -1, 0)
                return acos(min(max(simd_dot(thigh.act(down), shin.act(down)), -1), 1)) * 180 / .pi
            }
            return (bends[0], bends[1])
        }
    }

    /// The phone has a wearer who stands straight on knees bent 25°. The
    /// character's legs are straight when the wearer's are, and bend when
    /// the wearer lifts a foot.
    func testTheCharacterStandsOnStraightLegsWhenTheWearerDoes() throws {
        guard let session = try ticks(Self.withHeadset) else { throw XCTSkip("recording not present") }
        let calibration = try XCTUnwrap(stretch("Stand still, arms down", of: session).dropFirst(100).first)

        // The last step of the session, a minute after the calibration.
        let last = try XCTUnwrap(session.markers.last)
        let still = zip(session.ticks, session.frameTimes).filter { $0.1 >= last.time }.map(\.0)
        let standing = try kneeBends(still, calibration: calibration)
        XCTAssertGreaterThan(standing.count, 300)
        XCTAssertLessThan(try XCTUnwrap(standing.map(\.left).max()), 8)
        XCTAssertLessThan(try XCTUnwrap(standing.map(\.right).max()), 8)

        // The wearer's left foot is the character's right, in the mirror.
        let lifting = try kneeBends(stretch("Lift your LEFT", of: session), calibration: calibration)
        XCTAssertGreaterThan(try XCTUnwrap(lifting.map(\.right).max()), 50)
        XCTAssertLessThan(try XCTUnwrap(lifting.map(\.left).max()), 12)
    }

    // MARK: - Fingers

    /// The hands shaped from the headset's joints over the recorded
    /// session, with the wearer's own open hand (the last step, hands
    /// hanging relaxed) as the rig's rest: at rest nothing turns, holding
    /// the hands up in front every bone is driven, and from one rendered
    /// frame to the next no bone turns by more than a hand does.
    func testTheFingersFollowTheHeadsetWithoutSteps() throws {
        guard let session = try ticks(Self.withHeadset) else { throw XCTSkip("recording not present") }
        let names = ["thumb", "index", "middle", "ring", "pinky"]
        let rig = MocapHandRig(hand: "hand", fingers: names.map { f in (1 ... 3).map { "\(f)\($0)" } }, tips: names.map { "\($0)Tip" })
        var track = MocapHeadTrack()
        try track.calibrate(with: XCTUnwrap(session.ticks.first?.headset))
        func captured(_ hand: MocapHandSample) -> [MocapHandJoint: simd_float3] {
            MocapHandRetarget.modelSpace(hand, bodyAxes: track.inBodyAxes, mirror: false, flipFacing: false)
        }
        // The rest: the wearer's right hand, open, in the last step.
        let still = stretch("Stand still", of: session).dropFirst(100)
        let open = try XCTUnwrap(still.first?.hands[.right])
        XCTAssertTrue(open.isTracked)
        var rest: [String: simd_float3] = [:]
        let openJoints = captured(open)
        rest["hand"] = openJoints[.wrist]
        for (index, (finger, joints)) in zip(rig.fingers, MocapHandRig.fingerJoints).enumerated() {
            for segment in 0 ..< 3 {
                rest[finger[segment]] = openJoints[joints[segment]]
            }
            rest[names[index] + "Tip"] = openJoints[joints[3]]
        }
        func turn(_ a: simd_quatf, _ b: simd_quatf) -> Float {
            let angle = simd_normalize(a * b.inverse).angle
            return min(angle, 2 * .pi - angle)
        }
        let atRest = MocapHandRetarget.deltas(captured: openJoints, rig: rig, rest: rest)
        XCTAssertEqual(atRest.count, 16)
        XCTAssertLessThan(try XCTUnwrap(atRest.values.map(\.angle).max()), 1e-3)

        var previous: [String: simd_quatf]?
        var largestStep: Float = 0
        var driven = 0, seen = 0
        var curls: [Float] = []
        for tick in stretch("Hold your hands in front", of: session) {
            guard let hand = tick.hands[.right], hand.isTracked else {
                previous = nil
                continue
            }
            seen += 1
            let deltas = MocapHandRetarget.deltas(captured: captured(hand), rig: rig, rest: rest)
            if deltas.count == 16 {
                driven += 1
            }
            if let previous {
                for (joint, delta) in deltas {
                    guard let before = previous[joint] else { continue }
                    largestStep = max(largestStep, turn(delta, before))
                }
            }
            if let hand = deltas["hand"], let index = deltas["index1"] {
                curls.append(turn(index, hand) * 180 / .pi)
            }
            previous = deltas
        }
        XCTAssertGreaterThan(seen, 300)
        XCTAssertEqual(driven, seen, "every bone driven whenever the hand is seen")
        XCTAssertLessThan(largestStep * 180 / .pi, 25, "degrees between rendered frames")
        // The index finger bent at its knuckle relative to the open hand,
        // and not past what a finger can do.
        XCTAssertLessThan(try XCTUnwrap(curls.max()), 120)
    }
}

@testable import CoolSaber
import simd
import XCTest

final class CoolSaberMathTests: XCTestCase {
    // MARK: - Segment-segment distance

    func testPerpendicularCrossingSegments() {
        // X-aligned at y=0 and Z-aligned at y=0.3 crossing above its middle.
        let result = CoolSaberMath.segmentSegmentClosest(
            SIMD3(-1, 0, 0), SIMD3(1, 0, 0),
            SIMD3(0, 0.3, -1), SIMD3(0, 0.3, 1)
        )
        XCTAssertEqual(result.distance, 0.3, accuracy: 1e-5)
        XCTAssertEqual(result.pointA, SIMD3(0, 0, 0))
        XCTAssertEqual(result.pointB, SIMD3(0, 0.3, 0))
    }

    func testIntersectingSegmentsHaveZeroDistance() {
        let result = CoolSaberMath.segmentSegmentClosest(
            SIMD3(-1, 0, 0), SIMD3(1, 0, 0),
            SIMD3(0, -1, 0), SIMD3(0, 1, 0)
        )
        XCTAssertEqual(result.distance, 0, accuracy: 1e-5)
    }

    func testParallelOverlappingSegments() {
        let result = CoolSaberMath.segmentSegmentClosest(
            SIMD3(0, 0, 0), SIMD3(2, 0, 0),
            SIMD3(1, 0.5, 0), SIMD3(3, 0.5, 0)
        )
        XCTAssertEqual(result.distance, 0.5, accuracy: 1e-5)
    }

    func testCollinearDisjointSegments() {
        let result = CoolSaberMath.segmentSegmentClosest(
            SIMD3(0, 0, 0), SIMD3(1, 0, 0),
            SIMD3(3, 0, 0), SIMD3(4, 0, 0)
        )
        XCTAssertEqual(result.distance, 2, accuracy: 1e-5)
        XCTAssertEqual(result.pointA, SIMD3(1, 0, 0))
        XCTAssertEqual(result.pointB, SIMD3(3, 0, 0))
    }

    func testDegenerateSegmentsArePoints() {
        // Retracted blade: both segments zero-length.
        let result = CoolSaberMath.segmentSegmentClosest(
            SIMD3(0, 1, 0), SIMD3(0, 1, 0),
            SIMD3(0, 2, 0), SIMD3(0, 2, 0)
        )
        XCTAssertEqual(result.distance, 1, accuracy: 1e-5)

        // One point, one segment: closest point is interior.
        let mixed = CoolSaberMath.segmentSegmentClosest(
            SIMD3(0.5, 1, 0), SIMD3(0.5, 1, 0),
            SIMD3(0, 0, 0), SIMD3(1, 0, 0)
        )
        XCTAssertEqual(mixed.distance, 1, accuracy: 1e-5)
        XCTAssertEqual(mixed.pointB, SIMD3(0.5, 0, 0))
    }

    func testEndpointClosestCase() {
        let result = CoolSaberMath.segmentSegmentClosest(
            SIMD3(0, 0, 0), SIMD3(1, 0, 0),
            SIMD3(2, 1, 0), SIMD3(3, 2, 0)
        )
        XCTAssertEqual(result.pointA, SIMD3(1, 0, 0))
        XCTAssertEqual(result.pointB, SIMD3(2, 1, 0))
        XCTAssertEqual(result.distance, sqrt(2), accuracy: 1e-5)
    }

    func testSymmetry() {
        let a0 = SIMD3<Float>(-0.4, 1.2, -0.8)
        let a1 = SIMD3<Float>(0.5, 1.9, -1.1)
        let b0 = SIMD3<Float>(0.2, 1.0, -0.6)
        let b1 = SIMD3<Float>(-0.3, 2.0, -1.4)
        let ab = CoolSaberMath.segmentSegmentClosest(a0, a1, b0, b1)
        let ba = CoolSaberMath.segmentSegmentClosest(b0, b1, a0, a1)
        XCTAssertEqual(ab.distance, ba.distance, accuracy: 1e-5)
    }

    // MARK: - Ignition animator

    func testIgnitionReachesFullLengthInDuration() {
        var ignition = CoolSaberIgnition()
        let dt: Float = 1.0 / 90.0
        var elapsed: Float = 0
        while ignition.progress < 1, elapsed < 5 {
            ignition.update(deltaTime: dt, ignited: true)
            elapsed += dt
        }
        XCTAssertEqual(elapsed, ignition.igniteDuration, accuracy: 2 * dt)
        XCTAssertEqual(ignition.easedProgress, 1, accuracy: 1e-5)
    }

    func testRetractIsSlowerThanIgnite() {
        var ignition = CoolSaberIgnition()
        ignition.progress = 1
        let dt: Float = 1.0 / 90.0
        var elapsed: Float = 0
        while ignition.progress > 0, elapsed < 5 {
            ignition.update(deltaTime: dt, ignited: false)
            elapsed += dt
        }
        XCTAssertEqual(elapsed, ignition.retractDuration, accuracy: 2 * dt)
        XCTAssertGreaterThan(ignition.retractDuration, ignition.igniteDuration)
    }

    func testIgnitionClamps() {
        var ignition = CoolSaberIgnition()
        ignition.update(deltaTime: 100, ignited: true)
        XCTAssertEqual(ignition.progress, 1)
        ignition.update(deltaTime: 100, ignited: false)
        XCTAssertEqual(ignition.progress, 0)
    }

    // MARK: - Clash detector

    func testClashFiresOnceOnApproach() {
        var detector = CoolSaberClashDetector(triggerDistance: 0.05)
        let dt: Float = 1.0 / 90.0
        XCTAssertFalse(detector.update(pairKey: 0, distance: 0.5, deltaTime: dt))
        XCTAssertTrue(detector.update(pairKey: 0, distance: 0.03, deltaTime: dt))
        // Still touching: no re-fire.
        XCTAssertFalse(detector.update(pairKey: 0, distance: 0.02, deltaTime: dt))
        XCTAssertFalse(detector.update(pairKey: 0, distance: 0.04, deltaTime: dt))
    }

    func testClashRequiresReleaseBeyondHysteresis() {
        var detector = CoolSaberClashDetector(triggerDistance: 0.05)
        let dt: Float = 1.0 / 90.0
        XCTAssertTrue(detector.update(pairKey: 0, distance: 0.03, deltaTime: dt))
        // Separates a little, but not past trigger * releaseFactor: still "in contact".
        XCTAssertFalse(detector.update(pairKey: 0, distance: 0.06, deltaTime: dt))
        XCTAssertFalse(detector.update(pairKey: 0, distance: 0.03, deltaTime: dt))
        // Clean release then re-approach (after cooldown) fires again.
        XCTAssertFalse(detector.update(pairKey: 0, distance: 0.2, deltaTime: 1.0))
        XCTAssertTrue(detector.update(pairKey: 0, distance: 0.03, deltaTime: dt))
    }

    func testClashCooldownBlocksImmediateRefire() {
        var detector = CoolSaberClashDetector(triggerDistance: 0.05)
        XCTAssertTrue(detector.update(pairKey: 0, distance: 0.03, deltaTime: 0.01))
        // Release and re-approach within the cooldown window.
        XCTAssertFalse(detector.update(pairKey: 0, distance: 0.2, deltaTime: 0.01))
        XCTAssertFalse(detector.update(pairKey: 0, distance: 0.03, deltaTime: 0.01))
    }

    func testClashPairsAreIndependent() {
        var detector = CoolSaberClashDetector(triggerDistance: 0.05)
        XCTAssertTrue(detector.update(pairKey: 1, distance: 0.03, deltaTime: 0.01))
        XCTAssertTrue(detector.update(pairKey: 2, distance: 0.03, deltaTime: 0.01))
    }
}

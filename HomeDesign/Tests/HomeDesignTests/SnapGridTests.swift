//
//  SnapGridTests.swift
//  HomeDesignTests
//

import XCTest
import simd
@testable import HomeDesign

final class SnapGridTests: XCTestCase {

    // MARK: - Basic snapping

    func testPositionAlreadyOnGrid_IsUnchanged() {
        let pos = simd_float3(1.0, 0.0, 2.0)
        let result = snapToGrid(pos)
        XCTAssertEqual(result.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.z, 2.0, accuracy: 0.001)
    }

    func testPositionBelowMidpoint_RoundsDown() {
        // 0.2 / 0.5 = 0.4 → round(0.4) = 0 → 0 * 0.5 = 0.0
        let pos = simd_float3(0.2, 0.0, 0.0)
        let result = snapToGrid(pos)
        XCTAssertEqual(result.x, 0.0, accuracy: 0.001)
    }

    func testPositionAboveMidpoint_RoundsUp() {
        // 0.3 / 0.5 = 0.6 → round(0.6) = 1 → 1 * 0.5 = 0.5
        let pos = simd_float3(0.3, 0.0, 0.0)
        let result = snapToGrid(pos)
        XCTAssertEqual(result.x, 0.5, accuracy: 0.001)
    }

    func testPositionAtExactMidpoint_RoundsUp() {
        // 0.25 / 0.5 = 0.5 → round(0.5) = 1 (rounds away from zero) → 0.5
        let pos = simd_float3(0.25, 0.0, 0.0)
        let result = snapToGrid(pos)
        XCTAssertEqual(result.x, 0.5, accuracy: 0.001)
    }

    // MARK: - Y axis

    func testYAxisIsAlwaysPreserved() {
        let pos = simd_float3(0.3, 7.654, 0.8)
        let result = snapToGrid(pos)
        XCTAssertEqual(result.y, 7.654, accuracy: 0.0001)
    }

    func testYAxisPreservedWhenZero() {
        let result = snapToGrid(simd_float3(0.3, 0.0, 0.3))
        XCTAssertEqual(result.y, 0.0, accuracy: 0.0001)
    }

    // MARK: - Negative coordinates

    func testNegativeX_RoundsAwayFromZero() {
        // -0.3 / 0.5 = -0.6 → round(-0.6) = -1 → -0.5
        let pos = simd_float3(-0.3, 0.0, 0.0)
        let result = snapToGrid(pos)
        XCTAssertEqual(result.x, -0.5, accuracy: 0.001)
    }

    func testNegativeZ_SnapsToGrid() {
        // -1.1 / 0.5 = -2.2 → round(-2.2) = -2 → -1.0
        let pos = simd_float3(0.0, 0.0, -1.1)
        let result = snapToGrid(pos)
        XCTAssertEqual(result.z, -1.0, accuracy: 0.001)
    }

    func testNegativeAtMidpoint_RoundsAwayFromZero() {
        // -0.25 / 0.5 = -0.5 → round(-0.5) = -1 → -0.5
        let pos = simd_float3(-0.25, 0.0, 0.0)
        let result = snapToGrid(pos)
        XCTAssertEqual(result.x, -0.5, accuracy: 0.001)
    }

    // MARK: - Origin

    func testOriginRemainsAtOrigin() {
        let result = snapToGrid(.zero)
        XCTAssertEqual(result.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(result.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(result.z, 0.0, accuracy: 0.001)
    }

    // MARK: - Custom grid size

    func testCustomGridSize_OneUnit() {
        // 0.7 / 1.0 = 0.7 → round = 1 → 1.0
        let pos = simd_float3(0.7, 0.0, 1.3)
        let result = snapToGrid(pos, gridSize: 1.0)
        XCTAssertEqual(result.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.z, 1.0, accuracy: 0.001)
    }

    func testCustomGridSize_QuarterUnit() {
        // 0.3 / 0.25 = 1.2 → round = 1 → 0.25
        let pos = simd_float3(0.3, 0.0, 0.0)
        let result = snapToGrid(pos, gridSize: 0.25)
        XCTAssertEqual(result.x, 0.25, accuracy: 0.001)
    }

    func testCustomGridSize_TwoUnits() {
        // x: 2.9 / 2.0 = 1.45 → round(1.45) = 1 → 2.0
        // z: 3.1 / 2.0 = 1.55 → round(1.55) = 2 → 4.0
        let pos = simd_float3(2.9, 0.0, 3.1)
        let result = snapToGrid(pos, gridSize: 2.0)
        XCTAssertEqual(result.x, 2.0, accuracy: 0.001)
        XCTAssertEqual(result.z, 4.0, accuracy: 0.001)
    }

    // MARK: - Large coordinates

    func testLargeCoordinates_SnapCorrectly() {
        let pos = simd_float3(100.3, 0.0, -50.8)
        let result = snapToGrid(pos)
        XCTAssertEqual(result.x, 100.5, accuracy: 0.001)
        XCTAssertEqual(result.z, -51.0, accuracy: 0.001)
    }

    // MARK: - Both X and Z snapped independently

    func testBothAxesSnappedIndependently() {
        // X rounds down, Z rounds up
        let pos = simd_float3(0.1, 0.0, 0.4)
        let result = snapToGrid(pos)
        XCTAssertEqual(result.x, 0.0, accuracy: 0.001)  // 0.1 → 0.0
        XCTAssertEqual(result.z, 0.5, accuracy: 0.001)  // 0.4 → 0.5
    }
}

//
//  SurfaceClassificationTests.swift
//  HomeDesignTests
//

import XCTest
import UntoldEngine
@testable import HomeDesign

final class SurfaceClassificationTests: XCTestCase {

    // MARK: - Floor vs. wall height threshold

    func testEntityAtFloorLevel_IsFloor() {
        XCTAssertEqual(classifySurface(entityY: 0.0, yRotationDegrees: 0), .floor)
    }

    func testEntitySlightlyAboveFloor_BelowThreshold_IsFloor() {
        XCTAssertEqual(classifySurface(entityY: 0.1, yRotationDegrees: 0), .floor)
    }

    func testEntityExactlyAtThreshold_IsFloor() {
        // Guard is strictly greater-than, so the threshold itself still counts as floor.
        XCTAssertEqual(classifySurface(entityY: 0.3, yRotationDegrees: 0), .floor)
    }

    func testEntityJustAboveThreshold_IsWall() {
        XCTAssertNotEqual(classifySurface(entityY: 0.31, yRotationDegrees: 0), .floor)
    }

    func testCustomThreshold_IsRespected() {
        XCTAssertEqual(classifySurface(entityY: 1.0, yRotationDegrees: 0, wallHeightThreshold: 2.0), .floor)
        XCTAssertNotEqual(classifySurface(entityY: 1.0, yRotationDegrees: 0, wallHeightThreshold: 0.5), .floor)
    }

    // MARK: - Wall drag-plane axis from rotation

    func testZeroRotation_FacesNorthSouth_UsesXY() {
        XCTAssertEqual(classifySurface(entityY: 1.5, yRotationDegrees: 0), .wall(.xy))
    }

    func testNinetyDegrees_FacesEastWest_UsesYZ() {
        XCTAssertEqual(classifySurface(entityY: 1.5, yRotationDegrees: 90), .wall(.yz))
    }

    func testOneEightyDegrees_FacesNorthSouth_UsesXY() {
        XCTAssertEqual(classifySurface(entityY: 1.5, yRotationDegrees: 180), .wall(.xy))
    }

    func testTwoSeventyDegrees_FacesEastWest_UsesYZ() {
        XCTAssertEqual(classifySurface(entityY: 1.5, yRotationDegrees: 270), .wall(.yz))
    }

    func testFullTurn_MatchesZeroRotation() {
        XCTAssertEqual(classifySurface(entityY: 1.5, yRotationDegrees: 360), .wall(.xy))
    }

    func testNegativeRotation_MirrorsPositiveEquivalent() {
        XCTAssertEqual(classifySurface(entityY: 1.5, yRotationDegrees: -90), .wall(.yz))
    }
}

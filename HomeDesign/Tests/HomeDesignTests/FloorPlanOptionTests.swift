//
//  FloorPlanOptionTests.swift
//  HomeDesignTests
//

import XCTest
@testable import HomeDesign

final class FloorPlanOptionTests: XCTestCase {

    // MARK: - formatDisplayName

    func testSingleWord_ReturnsCapitalized() {
        XCTAssertEqual(FloorPlanOption.formatDisplayName("modern"), "Modern")
        XCTAssertEqual(FloorPlanOption.formatDisplayName("STUDIO"), "Studio")
    }

    func testUnderscoreSeparated_JoinsWithSpaces() {
        XCTAssertEqual(FloorPlanOption.formatDisplayName("modern_loft"), "Modern Loft")
    }

    func testHyphenSeparated_JoinsWithSpaces() {
        XCTAssertEqual(FloorPlanOption.formatDisplayName("cozy-studio"), "Cozy Studio")
    }

    func testMixedSeparators_JoinsWithSpaces() {
        XCTAssertEqual(FloorPlanOption.formatDisplayName("family_home-01"), "Family Home 01")
    }

    func testEmptyString_ReturnsEmpty() {
        XCTAssertEqual(FloorPlanOption.formatDisplayName(""), "")
    }

    func testAlreadyMixedCase_IsNormalized() {
        XCTAssertEqual(FloorPlanOption.formatDisplayName("mOdErN_lOfT"), "Modern Loft")
    }
}

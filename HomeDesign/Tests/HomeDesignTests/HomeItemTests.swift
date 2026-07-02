//
//  HomeItemTests.swift
//  HomeDesignTests
//

import XCTest
@testable import HomeDesign

final class HomeItemTests: XCTestCase {

    // MARK: - formatDisplayName

    func testStandardName_CapitalizesCategory_UsesVariantNumber() {
        XCTAssertEqual(HomeItem.formatDisplayName("bed_01_01"), "Bed 1")
        XCTAssertEqual(HomeItem.formatDisplayName("bed_01_02"), "Bed 2")
        XCTAssertEqual(HomeItem.formatDisplayName("bed_01_03"), "Bed 3")
    }

    func testCategoryCapitalized() {
        XCTAssertEqual(HomeItem.formatDisplayName("chair_01_01"), "Chair 1")
        XCTAssertEqual(HomeItem.formatDisplayName("sofa_02_04"), "Sofa 4")
        XCTAssertEqual(HomeItem.formatDisplayName("table_01_01"), "Table 1")
    }

    func testSingleSegment_ReturnsCapitalized() {
        XCTAssertEqual(HomeItem.formatDisplayName("bed"), "Bed")
        XCTAssertEqual(HomeItem.formatDisplayName("chair"), "Chair")
    }

    func testTwoSegments_NonNumericLast_ReturnsCapitalizedCategory() {
        // Last segment is not a number → fall back to capitalised category only
        XCTAssertEqual(HomeItem.formatDisplayName("bed_queen"), "Bed")
    }

    func testTwoSegments_NumericLast_UsesNumber() {
        XCTAssertEqual(HomeItem.formatDisplayName("bed_3"), "Bed 3")
    }

    func testEmptyString_ReturnsEmpty() {
        XCTAssertEqual(HomeItem.formatDisplayName(""), "")
    }

    func testVariantNumberZero_IncludesZero() {
        XCTAssertEqual(HomeItem.formatDisplayName("lamp_01_00"), "Lamp 0")
    }

    func testHighVariantNumber_Preserved() {
        XCTAssertEqual(HomeItem.formatDisplayName("shelf_01_99"), "Shelf 99")
    }
}

//
//  HomeDesignStoreTests.swift
//  HomeDesignTests
//

import XCTest
@testable import HomeDesign

final class HomeDesignStoreTests: XCTestCase {

    var store: HomeDesignStore!

    override func setUp() {
        super.setUp()
        store = HomeDesignStore()
    }

    // MARK: - Action queue

    func testConsumeAction_WhenEmpty_ReturnsNil() {
        XCTAssertNil(store.consumeAction())
    }

    func testRequestThenConsume_ReturnsAction() {
        store.requestAction(.remove)
        XCTAssertEqual(store.consumeAction(), .remove)
    }

    func testConsume_ClearsSlot() {
        store.requestAction(.undo)
        _ = store.consumeAction()
        XCTAssertNil(store.consumeAction())
    }

    func testDoubleRequest_LastActionWins() {
        store.requestAction(.remove)
        store.requestAction(.undo)
        XCTAssertEqual(store.consumeAction(), .undo)
    }

    func testAllActionsCanBeQueued() {
        let actions: [PanelAction] = [.remove, .rotateLeft, .rotateRight, .duplicate, .resetFloorPlanScale, .undo]
        for action in actions {
            store.requestAction(action)
            XCTAssertEqual(store.consumeAction(), action, "Failed for action: \(action)")
        }
    }

    // MARK: - Snap enabled toggle

    func testSnapEnabled_DefaultIsTrue() {
        XCTAssertTrue(store.snapEnabled)
    }

    func testSnapEnabled_CanBeDisabled() {
        store.snapEnabled = false
        XCTAssertFalse(store.snapEnabled)
    }

    func testSnapEnabled_CanBeReEnabled() {
        store.snapEnabled = false
        store.snapEnabled = true
        XCTAssertTrue(store.snapEnabled)
    }

    // MARK: - Thread safety

    func testConcurrentActionRequestAndConsume_DoesNotCrash() {
        let expectation = expectation(description: "concurrent ops")
        expectation.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for _ in 0..<500 {
                self.store.requestAction(.remove)
            }
            expectation.fulfill()
        }

        DispatchQueue.global().async {
            for _ in 0..<500 {
                _ = self.store.consumeAction()
            }
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testConcurrentSnapToggle_DoesNotCrash() {
        let expectation = expectation(description: "snap toggle")
        expectation.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for i in 0..<500 {
                self.store.snapEnabled = i.isMultiple(of: 2)
            }
            expectation.fulfill()
        }

        DispatchQueue.global().async {
            for _ in 0..<500 {
                _ = self.store.snapEnabled
            }
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
    }
}

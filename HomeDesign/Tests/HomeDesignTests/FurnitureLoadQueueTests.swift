//
//  FurnitureLoadQueueTests.swift
//  HomeDesignTests
//

import XCTest
@testable import HomeDesign

final class FurnitureLoadQueueTests: XCTestCase {

    var queue: FurnitureLoadQueue!

    override func setUp() {
        super.setUp()
        queue = FurnitureLoadQueue()
    }

    // MARK: - Basic queue behaviour

    func testDequeue_WhenEmpty_ReturnsNil() {
        XCTAssertNil(queue.dequeue())
    }

    func testEnqueueThenDequeue_ReturnsSameValue() {
        queue.enqueue("bed_01_01")
        XCTAssertEqual(queue.dequeue(), "bed_01_01")
    }

    func testDequeue_ClearsSlot() {
        queue.enqueue("bed_01_01")
        _ = queue.dequeue()
        XCTAssertNil(queue.dequeue())
    }

    // MARK: - Single-slot behaviour (last write wins)

    func testDoubleEnqueue_LastValueWins() {
        queue.enqueue("bed_01_01")
        queue.enqueue("bed_01_02")
        XCTAssertEqual(queue.dequeue(), "bed_01_02")
    }

    func testTripleEnqueue_LastValueWins() {
        queue.enqueue("bed_01_01")
        queue.enqueue("bed_01_02")
        queue.enqueue("bed_01_03")
        XCTAssertEqual(queue.dequeue(), "bed_01_03")
    }

    func testDequeueAfterDoubleEnqueue_IsNilOnSecondCall() {
        queue.enqueue("bed_01_01")
        queue.enqueue("bed_01_02")
        _ = queue.dequeue()
        XCTAssertNil(queue.dequeue())
    }

    // MARK: - Empty string handling

    func testEnqueueEmptyString_CanBeDequeued() {
        queue.enqueue("")
        XCTAssertEqual(queue.dequeue(), "")
    }

    // MARK: - Thread safety

    func testConcurrentEnqueueDequeue_DoesNotCrash() {
        let iterations = 1_000
        let expectation = expectation(description: "concurrent ops complete")
        expectation.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for i in 0..<iterations {
                self.queue.enqueue("model_\(i)")
            }
            expectation.fulfill()
        }

        DispatchQueue.global().async {
            for _ in 0..<iterations {
                _ = self.queue.dequeue()
            }
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        // After all concurrent ops the queue holds at most one value — just verify no crash
    }

    func testConcurrentEnqueue_FinalStateIsValid() {
        let group = DispatchGroup()

        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                self.queue.enqueue("model_\(i)")
                group.leave()
            }
        }

        group.wait()
        // Either nil (if dequeued between writes) or a valid "model_N" string
        let result = queue.dequeue()
        if let name = result {
            XCTAssertTrue(name.hasPrefix("model_"))
        }
    }
}

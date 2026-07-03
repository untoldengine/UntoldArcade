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

    // MARK: - FIFO behaviour (no tap is dropped)

    func testDoubleEnqueue_DequeuesInOrder() {
        queue.enqueue("bed_01_01")
        queue.enqueue("bed_01_02")
        XCTAssertEqual(queue.dequeue(), "bed_01_01")
        XCTAssertEqual(queue.dequeue(), "bed_01_02")
    }

    func testTripleEnqueue_DequeuesInOrder() {
        queue.enqueue("bed_01_01")
        queue.enqueue("bed_01_02")
        queue.enqueue("bed_01_03")
        XCTAssertEqual(queue.dequeue(), "bed_01_01")
        XCTAssertEqual(queue.dequeue(), "bed_01_02")
        XCTAssertEqual(queue.dequeue(), "bed_01_03")
    }

    func testDequeueAfterDoubleEnqueue_IsNilOnThirdCall() {
        queue.enqueue("bed_01_01")
        queue.enqueue("bed_01_02")
        _ = queue.dequeue()
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
        // Just verify no crash — exact interleaving of concurrent enqueue/dequeue is undefined.
    }

    func testConcurrentEnqueue_AllItemsSurvive() {
        let group = DispatchGroup()

        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                self.queue.enqueue("model_\(i)")
                group.leave()
            }
        }

        group.wait()

        var drained: [String] = []
        while let name = queue.dequeue() {
            drained.append(name)
        }
        XCTAssertEqual(drained.count, 100)
        XCTAssertTrue(drained.allSatisfy { $0.hasPrefix("model_") })
    }
}

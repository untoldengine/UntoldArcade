@testable import CoolCloth
import simd
import XCTest

final class CoolClothSimulationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CoolClothSimulation.shared.resetForTesting()
    }

    override func tearDown() {
        CoolClothSimulation.shared.resetForTesting()
        super.tearDown()
    }

    func testFrameStateConsumesDeltaTimeExactlyOnce() {
        advanceCoolCloth(deltaTime: 1.0 / 60.0)
        advanceCoolCloth(deltaTime: 1.0 / 60.0)

        let first = CoolClothSimulation.shared.consumeFrameState()
        let second = CoolClothSimulation.shared.consumeFrameState()

        XCTAssertEqual(first.deltaTime, 2.0 / 60.0, accuracy: 1e-6)
        // With no pending delta the simulation falls back to a 90 Hz step.
        XCTAssertEqual(second.deltaTime, 1.0 / 90.0, accuracy: 1e-6)
    }

    func testResetBumpsGenerationAndAppliesPinMode() {
        let before = CoolClothSimulation.shared.consumeFrameState()
        resetCoolCloth(pinMode: .leftEdge)
        let after = CoolClothSimulation.shared.consumeFrameState()

        XCTAssertEqual(after.resetGeneration, before.resetGeneration &+ 1)
        XCTAssertEqual(after.pinMode, .leftEdge)
    }

    func testResetReleasesGrab() {
        grabCoolClothParticle(column: 4, row: 8, targetWorld: SIMD3<Float>(0, 1, 0))
        resetCoolCloth()

        let state = CoolClothSimulation.shared.consumeFrameState()

        XCTAssertNil(state.grab)
    }

    func testGrabLifecycle() {
        grabCoolClothParticle(column: 4, row: 8, targetWorld: SIMD3<Float>(0, 1, 0))
        setCoolClothGrabTarget(worldPosition: SIMD3<Float>(0.5, 1.5, -0.25))

        let held = CoolClothSimulation.shared.consumeFrameState()
        XCTAssertEqual(held.grab?.column, 4)
        XCTAssertEqual(held.grab?.row, 8)
        XCTAssertEqual(held.grab?.targetWorld, SIMD3<Float>(0.5, 1.5, -0.25))

        releaseCoolClothGrab()
        let released = CoolClothSimulation.shared.consumeFrameState()
        XCTAssertNil(released.grab)
    }

    func testGrabRejectsOutOfRangeParticles() {
        grabCoolClothParticle(
            column: CoolClothSimulation.gridSize,
            row: 0,
            targetWorld: .zero
        )

        XCTAssertNil(CoolClothSimulation.shared.consumeFrameState().grab)
    }

    func testWindIsStoredAsVelocityVector() {
        setCoolClothWind(directionWorld: SIMD3<Float>(0, 0, 8), strength: 2.5, gustiness: 0.75)

        let state = CoolClothSimulation.shared.consumeFrameState()

        XCTAssertEqual(state.windWorld, SIMD3<Float>(0, 0, 2.5))
        XCTAssertEqual(state.gustiness, 0.75)
    }

    func testMaterialPresetsGrowSofterFromDenimToRubber() {
        let denim = CoolClothMaterialPreset.denim.parameters
        let silk = CoolClothMaterialPreset.silk.parameters
        let rubber = CoolClothMaterialPreset.rubber.parameters

        XCTAssertLessThan(denim.stretchCompliance, silk.stretchCompliance)
        XCTAssertLessThan(silk.stretchCompliance, rubber.stretchCompliance)
        // Every preset bends more easily than it stretches.
        for preset in CoolClothMaterialPreset.allCases {
            let parameters = preset.parameters
            XCTAssertLessThan(parameters.stretchCompliance, parameters.bendCompliance)
        }
    }

    func testSolverQualityIsClamped() {
        setCoolClothSolverQuality(substeps: 99, iterations: 0)

        let state = CoolClothSimulation.shared.consumeFrameState()

        XCTAssertEqual(state.substeps, 16)
        XCTAssertEqual(state.iterations, 1)
    }

    func testLightDirectionIsNormalized() {
        setCoolClothLightDirection(SIMD3<Float>(0, 4, 0))

        XCTAssertEqual(
            CoolClothSimulation.shared.consumeFrameState().lightDirection,
            SIMD3<Float>(0, 1, 0)
        )
    }
}

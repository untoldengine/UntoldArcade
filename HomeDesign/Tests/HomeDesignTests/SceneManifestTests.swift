//
//  SceneManifestTests.swift
//  HomeDesignTests
//

import XCTest
@testable import HomeDesign

final class SceneManifestTests: XCTestCase {

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: - Direct `asset` field (plain furniture entities)

    func testFurnitureEntity_DirectAsset_ResolvesModelBaseName() {
        let json = """
        {"entities":[
            {"asset":{"kind":"model","path":"Models/bed_01_02/bed_01_02.untold"}}
        ]}
        """
        XCTAssertEqual(SceneManifest.modelBaseNames(from: data(json)), ["bed_01_02"])
    }

    // MARK: - Nested `assetInstance.asset` (multi-part imported assets, e.g. the floor plan)

    func testFloorPlanEntity_AssetInstance_ResolvesModelBaseName() {
        let json = """
        {"entities":[
            {"assetInstance":{"asset":{"kind":"model","path":"Models/FloorPlan/FloorPlan.untold"}}}
        ]}
        """
        XCTAssertEqual(SceneManifest.modelBaseNames(from: data(json)), ["FloorPlan"])
    }

    func testAssetInstanceTakesPriorityOverDirectAsset() {
        let json = """
        {"entities":[
            {
                "asset":{"kind":"model","path":"Models/bed_01_02/bed_01_02.untold"},
                "assetInstance":{"asset":{"kind":"model","path":"Models/FloorPlan/FloorPlan.untold"}}
            }
        ]}
        """
        XCTAssertEqual(SceneManifest.modelBaseNames(from: data(json)), ["FloorPlan"])
    }

    // MARK: - Non-model entities (lights, cameras, empties)

    func testProceduralAsset_ReturnsNil() {
        let json = """
        {"entities":[
            {"asset":{"kind":"procedural","path":"/primitive/default_cube"}}
        ]}
        """
        XCTAssertEqual(SceneManifest.modelBaseNames(from: data(json)), [nil])
    }

    func testNoAssetAtAll_ReturnsNil() {
        let json = """
        {"entities":[{}]}
        """
        XCTAssertEqual(SceneManifest.modelBaseNames(from: data(json)), [nil])
    }

    func testModelKindOutsideModelsFolder_ReturnsNil() {
        let json = """
        {"entities":[
            {"asset":{"kind":"model","path":"/absolute/outside/Models/rogue.untold"}}
        ]}
        """
        XCTAssertEqual(SceneManifest.modelBaseNames(from: data(json)), [nil])
    }

    // MARK: - Multiple entities, order preserved

    func testMultipleEntities_PreservesFileOrder() {
        let json = """
        {"entities":[
            {"assetInstance":{"asset":{"kind":"model","path":"Models/FloorPlan/FloorPlan.untold"}}},
            {"asset":{"kind":"procedural","path":"/primitive/default_cube"}},
            {},
            {"asset":{"kind":"model","path":"Models/bed_01_02/bed_01_02.untold"}},
            {"asset":{"kind":"model","path":"Models/clock_02_01/clock_02_01.untold"}}
        ]}
        """
        XCTAssertEqual(
            SceneManifest.modelBaseNames(from: data(json)),
            ["FloorPlan", nil, nil, "bed_01_02", "clock_02_01"]
        )
    }

    // MARK: - Malformed input

    func testMalformedJSON_ReturnsNil() {
        XCTAssertNil(SceneManifest.modelBaseNames(from: data("not json")))
    }

    func testEmptyEntityList_ReturnsEmptyArray() {
        XCTAssertEqual(SceneManifest.modelBaseNames(from: data("{\"entities\":[]}")), [])
    }
}

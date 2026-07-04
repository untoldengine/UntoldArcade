//
//  SceneManifest.swift
//  HomeDesign
//

import Foundation

/// Minimal, engine-independent parse of a `.untoldscene` file's entity list.
///
/// The engine exposes `loadUntoldScene(named:)` to spawn a scene, but its `SceneData`/
/// `EntityData` types have internal (non-public) stored properties, and a live entity's
/// asset reference isn't queryable through any public API once loaded. So there's no way
/// to ask "what model does this spawned entity use" after the fact.
///
/// Reading the same `.untoldscene` file ourselves — it's just JSON — gets us each
/// authored entity's model reference directly. Combined with entity-creation-order
/// correlation (see `GameSceneUtils.registerLoadedFloorPlan`), this lets HomeDesign tell
/// pre-placed furniture apart from the room shell without any engine-side support.
enum SceneManifest {
    /// Model base names (e.g. "bed_01_02"), one per top-level authored entity, in file
    /// order. `nil` for entities with no model reference (lights, cameras, empties) or a
    /// non-model asset (procedural placeholders). Returns `nil` if the file can't be read.
    static func modelBaseNames(sceneName: String) -> [String?]? {
        guard let scenesDir = Bundle.main.url(
            forResource: "Scenes",
            withExtension: nil,
            subdirectory: "GameData"
        ) else { return nil }

        let url = scenesDir.appendingPathComponent(sceneName).appendingPathExtension("untoldscene")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return modelBaseNames(from: data)
    }

    /// Decoding step split out from bundle/file resolution so it's testable without a
    /// bundled `GameData` (the test target doesn't carry app resources — same reason
    /// `HomeItem.discover()`'s own bundle scan isn't unit tested, only its pure helpers).
    static func modelBaseNames(from data: Data) -> [String?]? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return manifest.entities.map(\.modelBaseName)
    }

    private struct Manifest: Decodable {
        var entities: [Entity]
    }

    /// Furniture entities carry `asset` directly. The floor plan (a multi-part imported
    /// asset with per-node overrides) carries it nested under `assetInstance` instead —
    /// both are checked, `assetInstance` taking priority when both happen to be present.
    private struct Entity: Decodable {
        var asset: AssetRef?
        var assetInstance: AssetInstanceRef?

        var modelBaseName: String? {
            let ref = assetInstance?.asset ?? asset
            guard let ref, ref.kind == "model", ref.path.hasPrefix("Models/") else { return nil }
            return URL(fileURLWithPath: ref.path).deletingPathExtension().lastPathComponent
        }
    }

    private struct AssetRef: Decodable {
        var kind: String
        var path: String
    }

    private struct AssetInstanceRef: Decodable {
        var asset: AssetRef?
    }
}

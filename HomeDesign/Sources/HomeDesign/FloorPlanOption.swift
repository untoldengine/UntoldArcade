//
//  FloorPlanOption.swift
//  HomeDesign
//

import Foundation

/// A pre-furnished floor plan the user can pick at the start of the experience.
/// Backed by a `GameData/Scenes/<name>.untoldscene` file (loaded via `loadUntoldScene(named:)`)
/// and an optional `GameData/Thumbnails/FloorPlans/<name>.png` preview.
struct FloorPlanOption: Identifiable {
    let id: String
    let displayName: String
    let thumbnailURL: URL?
    /// Base name passed to `loadUntoldScene(named:)` — no extension.
    let sceneName: String

    static func discover() -> [FloorPlanOption] {
        guard let scenesDir = Bundle.main.url(
            forResource: "Scenes",
            withExtension: nil,
            subdirectory: "GameData"
        ) else { return [] }

        let thumbnailsDir = Bundle.main.url(
            forResource: "FloorPlans",
            withExtension: nil,
            subdirectory: "GameData/Thumbnails"
        )

        let sceneFiles = ((try? FileManager.default.contentsOfDirectory(
            at: scenesDir,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "untoldscene" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return sceneFiles.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let thumbnailURL = thumbnailsDir?.appendingPathComponent(name).appendingPathExtension("png")
            let thumbnailExists = thumbnailURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return FloorPlanOption(
                id: name,
                displayName: formatDisplayName(name),
                thumbnailURL: thumbnailExists ? thumbnailURL : nil,
                sceneName: name
            )
        }
    }

    /// Scene names don't otherwise encode a presentable name (e.g. "floorplanA" has no
    /// separator `formatDisplayName` could split on), so known ones are named explicitly
    /// here; anything else falls back to the generic formatting below.
    private static let displayNameOverrides: [String: String] = [
        "floorplanA": "Apartment",
        "floorplanB": "Villa",
    ]

    static func formatDisplayName(_ id: String) -> String {
        if let override = displayNameOverrides[id] {
            return override
        }
        return id.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

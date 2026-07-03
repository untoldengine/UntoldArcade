//
//  FurnitureCatalog.swift
//  HomeDesign
//

import Foundation

/// Single source of truth for which model names count as placeable catalog furniture.
/// Used by the SwiftUI catalog (HomeItem.discover()) and by GameScene, which needs the
/// same list to recognize pre-placed furniture loaded from a floor plan scene.
enum FurnitureCatalog {
    /// Thumbnail URLs for every discoverable catalog item, sorted by filename.
    static func modelThumbnailURLs() -> [URL] {
        guard let thumbnailDir = Bundle.main.url(
            forResource: "Thumbnails",
            withExtension: nil,
            subdirectory: "GameData"
        ) else { return [] }

        return ((try? FileManager.default.contentsOfDirectory(
            at: thumbnailDir,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Model names (matching GameData/Models/<name>) with a catalog thumbnail.
    static func knownModelNames() -> [String] {
        modelThumbnailURLs().map { $0.deletingPathExtension().lastPathComponent }
    }
}

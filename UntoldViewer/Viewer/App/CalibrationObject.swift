//
//  CalibrationObject.swift
//  Untold Viewer
//
//  A calibration panel both renderers build from code, so that a capture of each measures
//  what they do to known colours: rows of grey and colour swatches, with RealityKit's
//  default tone map and with it off ("exact"), and three lit spheres — white and black
//  diffuse, and chrome — for the light itself. The engine shows its own pipeline on every
//  row (its swatches are emissive metals: no light reaches the colour), so its exact rows
//  should match RealityKit's exact rows, and RealityKit's tone-mapped rows show the curve
//  the engine's look pass has to match.
//

import RealityKit
import SwiftUI
import UntoldEngine

enum CalibrationObject {
    static let id = "calibration"

    /// Swatch values as a colour picker gives them (sRGB-encoded, 0–1).
    static let greys: [SIMD3<Float>] = [0.0, 0.1, 0.2, 0.3, 0.45, 0.6, 0.8, 1.0].map { SIMD3<Float>(repeating: $0) }
    static let colours: [SIMD3<Float>] = [
        SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1),
        SIMD3<Float>(0.93, 0.85, 0.62), // the board's cream
        SIMD3<Float>(0.72, 0.13, 0.11), // its red
        SIMD3<Float>(0.16, 0.50, 0.28), // its green
        SIMD3<Float>(1.0, 0.85, 0.2),
        SIMD3<Float>(0.9, 0.6, 0.5),
    ]

    /// The rows, top to bottom: greys tone-mapped, greys exact, colours tone-mapped, colours exact.
    static let rows: [(values: [SIMD3<Float>], exact: Bool)] = [(greys, false), (greys, true), (colours, false), (colours, true)]
    static let swatchSize: Float = 0.05
    static let pitch: Float = 0.062
    static let rowY: [Float] = [0.155, 0.093, 0.031, -0.031]
    static let sphereY: Float = -0.125
    static let sphereRadius: Float = 0.035
    static let sphereX: [Float] = [-0.15, 0, 0.15]
    /// The backing board behind it all: an exact mid grey, 0.35 as a picker gives it.
    static let backingGrey: Float = 0.35
    static let backingSize = SIMD3<Float>(0.54, 0.40, 0.004)

    static func swatchX(_ index: Int, of count: Int) -> Float {
        (Float(index) - Float(count - 1) / 2) * pitch
    }

    static func linear(_ encoded: Float) -> Float {
        encoded <= 0.04045 ? encoded / 12.92 : powf((encoded + 0.055) / 1.055, 2.4)
    }

    static func linear(_ encoded: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(linear(encoded.x), linear(encoded.y), linear(encoded.z))
    }

    // MARK: - Engine

    /// The panel as children of `parent` (which the placement and the tour move).
    @MainActor
    static func buildEngine(parent: EntityID) {
        func part(_ name: String, meshes: [Mesh], at offset: SIMD3<Float>, scale: SIMD3<Float> = SIMD3<Float>(repeating: 1)) -> EntityID {
            let entity = createEntity()
            setEntityName(entityId: entity, name: "Viewer.calibration.\(name)")
            setEntityMeshDirect(entityId: entity, meshes: meshes, assetName: name)
            scaleTo(entityId: entity, scale: scale)
            setParent(childId: entity, parentId: parent, offset: offset)
            return entity
        }
        /// An emissive black metal: no diffuse, no reflection, the colour as given.
        func emissive(_ entity: EntityID, _ encoded: SIMD3<Float>) {
            updateMaterialColor(entityId: entity, color: .black)
            updateMaterialMetallic(entityId: entity, metallic: 1)
            updateMaterialRoughness(entityId: entity, roughness: 1)
            updateMaterialEmmisive(entityId: entity, emmissive: linear(encoded))
        }
        let backing = part("backing", meshes: BasicPrimitives.createCube(extent: 1.0), at: SIMD3<Float>(0, 0.02, -0.006), scale: backingSize)
        emissive(backing, SIMD3<Float>(repeating: backingGrey))
        for (row, line) in rows.enumerated() {
            for (index, value) in line.values.enumerated() {
                let swatch = part("row\(row).\(index)", meshes: BasicPrimitives.createCube(extent: 1.0),
                                  at: SIMD3<Float>(swatchX(index, of: line.values.count), rowY[row], 0),
                                  scale: SIMD3<Float>(swatchSize, swatchSize, 0.004))
                emissive(swatch, value)
            }
        }
        let spheres: [(name: String, colour: Color, roughness: Float, metallic: Float)] = [
            ("white", .white, 1, 0),
            ("black", Color(red: 0.03, green: 0.03, blue: 0.03), 1, 0),
            ("chrome", .white, 0.05, 1),
        ]
        for (index, sphere) in spheres.enumerated() {
            let entity = part(sphere.name, meshes: BasicPrimitives.createSphere(extent: sphereRadius * 2, segments: [96, 48]),
                              at: SIMD3<Float>(sphereX[index], sphereY, sphereRadius + 0.004))
            updateMaterialColor(entityId: entity, color: sphere.colour)
            updateMaterialRoughness(entityId: entity, roughness: sphere.roughness)
            updateMaterialMetallic(entityId: entity, metallic: sphere.metallic)
        }
    }

    // MARK: - RealityKit

    static func makeRealityKitEntity() -> Entity {
        let root = Entity()
        root.name = "calibration"
        func color(_ encoded: SIMD3<Float>) -> UIColor {
            UIColor(red: CGFloat(encoded.x), green: CGFloat(encoded.y), blue: CGFloat(encoded.z), alpha: 1)
        }
        func swatch(_ encoded: SIMD3<Float>, exact: Bool, size: SIMD3<Float>, at position: SIMD3<Float>) {
            let material = UnlitMaterial(color: color(encoded), applyPostProcessToneMap: !exact)
            let entity = ModelEntity(mesh: .generateBox(size: size), materials: [material])
            entity.position = position
            root.addChild(entity)
        }
        swatch(SIMD3<Float>(repeating: backingGrey), exact: true, size: backingSize, at: SIMD3<Float>(0, 0.02, -0.006))
        for (row, line) in rows.enumerated() {
            for (index, value) in line.values.enumerated() {
                swatch(value, exact: line.exact, size: SIMD3<Float>(swatchSize, swatchSize, 0.004),
                       at: SIMD3<Float>(swatchX(index, of: line.values.count), rowY[row], 0))
            }
        }
        let spheres: [(tint: UIColor, roughness: Float, metallic: Float)] = [
            (.white, 1, 0),
            (UIColor(white: 0.03, alpha: 1), 1, 0),
            (.white, 0.05, 1),
        ]
        for (index, sphere) in spheres.enumerated() {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: sphere.tint)
            material.roughness = .init(floatLiteral: sphere.roughness)
            material.metallic = .init(floatLiteral: sphere.metallic)
            let entity = ModelEntity(mesh: .generateSphere(radius: sphereRadius), materials: [material])
            entity.position = SIMD3<Float>(sphereX[index], sphereY, sphereRadius + 0.004)
            root.addChild(entity)
        }
        return root
    }
}

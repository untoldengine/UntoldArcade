//
//  FieldBounds.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import simd
import UntoldEngine

func clampPositionToField(_ position: simd_float3, margin: Float = 0.5) -> simd_float3 {
    guard let field = EntityRegistry.shared.field else { return position }
    let fieldPos = getPosition(entityId: field)
    let fieldBounds = SceneManifest.shared.fieldBounds
    let halfWidth = fieldBounds.width * 0.5
    let halfDepth = fieldBounds.depth * 0.5

    let maxX = max(0.0, halfWidth - margin)
    let maxZ = max(0.0, halfDepth - margin)

    var localX = position.x - fieldPos.x
    var localZ = position.z - fieldPos.z

    if abs(localX) > maxX {
        localX = localX > 0.0 ? maxX : -maxX
    }
    if abs(localZ) > maxZ {
        localZ = localZ > 0.0 ? maxZ : -maxZ
    }

    return simd_float3(fieldPos.x + localX, position.y, fieldPos.z + localZ)
}

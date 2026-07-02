//
//  SnapGrid.swift
//  HomeDesign
//

import simd

/// Snaps X and Z — for floor items (XZ drag). Y (height) is preserved.
func snapToGrid(_ position: simd_float3, gridSize: Float = 0.5) -> simd_float3 {
    simd_float3(
        round(position.x / gridSize) * gridSize,
        position.y,
        round(position.z / gridSize) * gridSize
    )
}

/// Snaps X and Y — for wall items on east-west walls (XY drag). Z (depth) is preserved.
func snapToGridXY(_ position: simd_float3, gridSize: Float = 0.5) -> simd_float3 {
    simd_float3(
        round(position.x / gridSize) * gridSize,
        round(position.y / gridSize) * gridSize,
        position.z
    )
}

/// Snaps Y and Z — for wall items on north-south walls (YZ drag). X (depth) is preserved.
func snapToGridYZ(_ position: simd_float3, gridSize: Float = 0.5) -> simd_float3 {
    simd_float3(
        position.x,
        round(position.y / gridSize) * gridSize,
        round(position.z / gridSize) * gridSize
    )
}

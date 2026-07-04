//
//  SurfaceClassification.swift
//  HomeDesign
//

import simd
import UntoldEngine

/// How a pre-placed (scene-authored) furniture entity should be treated once loaded:
/// resting on the floor, or mounted to a wall with a specific drag plane.
enum SurfaceClassification: Equatable {
    case floor
    case wall(SpatialDragPlane)
}

/// Classifies a scene-authored furniture entity from its transform alone.
///
/// Interactively-placed wall items get their drag plane from the user's live gaze
/// direction at placement time (see `GameScene.handleInput()`), but pre-placed furniture
/// loaded from a `.untoldscene` file has no such runtime signal — only its authored
/// position and rotation. This infers the same thing from those:
///
/// - `entityY` near the room's floor (assumed local Y ≈ 0, the modeling convention already
///   relied on elsewhere in this codebase — see `calibratedFloorEntityY`'s 0.0 default)
///   means the item is resting on the floor.
/// - Otherwise it's wall-mounted, and the axis it's dragged along is inferred from its
///   authored Y-axis rotation: the item's forward-facing normal (assumed to be +Z at 0°
///   rotation) points into the room the same way a user's gaze would when placing it
///   interactively, so the same east/west-facing split from `snapToGridXY`/`snapToGridYZ`
///   applies — a normal pointing more along X (east-west) drags on `.yz`; more along Z
///   (north-south) drags on `.xy`.
func classifySurface(
    entityY: Float,
    yRotationDegrees: Float,
    wallHeightThreshold: Float = 0.3
) -> SurfaceClassification {
    guard entityY > wallHeightThreshold else { return .floor }

    let radians = yRotationDegrees * .pi / 180
    let forwardX = abs(sin(radians))
    let forwardZ = abs(cos(radians))
    let isEastWestFacing = forwardX >= forwardZ
    return .wall(isEastWestFacing ? .yz : .xy)
}

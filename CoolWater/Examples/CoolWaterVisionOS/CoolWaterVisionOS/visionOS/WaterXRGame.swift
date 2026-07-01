//
//  WaterXRGame.swift  (visionOS)
//  WebGLWater
//
//  Mixed-reality water demo logic. The pool lives in its local [-1,1]³ space (water
//  surface at local y=0) and is placed into the real world by a model matrix:
//      world = T(boxCenter) · Ry(boxYaw) · S(boxScale)
//  so the water surface sits at floor level and the pool sinks `boxScale` metres into
//  the floor. Pinch on the floor to (re)place it, two-hand pinch to scale/rotate, and
//  pinch the ball with a hand to move it.
//

import simd
import Metal
import UntoldEngine
import CoolWater

final class WaterXRGame {

    private let radius: Float = 0.3
    private let poolDepthRatio: Float = 1.0  // cube: depth == footprint
    private let occlusion = CoolWaterARKitOcclusionProvider()

    // Pool placement (world). The pool SITS ON the floor: its bottom (local y=-1) rests
    // at floorY, so the basin stands on the ground (a sunk-in pool would need real-floor
    // occlusion we don't have). A default position shows water immediately; a pinch on
    // the floor relocates + locks it.
    private var floorY: Float = -1.2          // detected floor height (default ≈ standing)
    private var boxCenterXZ = simd_float2(0.0, -1.2) // ~1.2 m in front of the start pose
    private var boxScale: Float = 0.5         // half-width → ~1 m footprint
    private var boxYaw: Float = 0.0
    private var placed = false

    // Ball state (pool-local space, like the desktop demo).
    private var ballLocal = simd_float3(-0.4, 0.4, 0.2)
    private var velocity = simd_float3(0, 0, 0)
    private let gravity: Float = -4.0
    private var grabbing = false

    // Interaction (driven by the gaze/pinch ray + engine-computed pinch deltas).
    private enum Drag { case none, ball, box }
    private var drag: Drag = .none
    private var wasPinching = false

    func start() {
        setCoolWaterSphere(center: ballLocal, radius: radius)
        setCoolWaterLightDirection(simd_float3(2.0, 2.0, -1.0))
        loadArt()
        seedCoolWaterRipples(count: 8)
        updateModel()

        // Required for spatial input: the engine's onSpatialEvent handler drops all
        // pinch events unless XR events are enabled AND the scene is marked ready.
        registerXREvents()
        setSceneReady(true)

        // Real-world occlusion: real surfaces occlude the water.
        occlusion.start()
    }

    private func loadArt() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        if let tiles = DemoAssets.loadTexture(device: device, name: "tiles", ext: "jpg", srgb: true, mipmapped: true) {
            setCoolWaterTilesTexture(tiles)
        }
        if let sky = DemoAssets.loadCubemap(device: device) {
            setCoolWaterSkyTexture(sky)
        }
    }

    private func boxCenter() -> simd_float3 {
        // Place the pool's TOP (the rim, at local y = 2/12) at floor level, so the whole
        // box sits below the real floor — a hole in the ground.
        let sy = boxScale * poolDepthRatio
        return simd_float3(boxCenterXZ.x, floorY - (2.0 / 12.0) * sy, boxCenterXZ.y)
    }

    private func model() -> simd_float4x4 {
        let t = simd_float4x4(translation: boxCenter())
        let r = simd_float4x4(rotationY: boxYaw)
        let s = simd_float4x4(scale: simd_float3(boxScale, boxScale * poolDepthRatio, boxScale))
        return simd_mul(simd_mul(t, r), s)
    }

    private func updateModel() { setCoolWaterModelMatrix(model()) }

    /// Does the world-space ray hit the ball? (ball is a sphere of radius `radius` in
    /// local space → `boxScale·radius` in world for the cube placement.)
    private func rayHitsBall(origin: simd_float3, direction: simd_float3) -> Bool {
        let len = simd_length(direction)
        guard len > 1e-5 else { return false }
        let d = direction / len
        let cw = simd_mul(model(), simd_float4(ballLocal, 1))
        let center = simd_float3(cw.x, cw.y, cw.z)
        let rw = boxScale * radius
        let oc = origin - center
        let b = simd_dot(oc, d)
        let c = simd_dot(oc, oc) - rw * rw
        let disc = b * b - c
        return disc > 0 && (-b - sqrt(disc)) > 0
    }

    /// Convert a world-space translation delta into pool-local space (undo yaw + scale).
    private func worldDeltaToLocal(_ d: simd_float3) -> simd_float3 {
        let r = simd_mul(simd_float4x4(rotationY: -boxYaw), simd_float4(d, 0))
        let sy = boxScale * poolDepthRatio
        return simd_float3(r.x / boxScale, r.y / max(sy, 1e-4), r.z / boxScale)
    }

    // MARK: - Per-frame

    func update(deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        let input = InputSystem.shared.xrSpatialInputState

        let pinching = input.spatialPinchActive
        let pinchBegan = pinching && !wasPinching

        // On pinch start, decide what's being grabbed: the ball (gaze ray hits it) or
        // otherwise the pool itself. Both are then DRAGGED by the hand's movement
        // (relative), never teleported.
        if pinchBegan {
            drag = rayHitsBall(origin: input.rayOriginWorld, direction: input.rayDirectionWorld) ? .ball : .box
            if drag == .ball { velocity = .zero }
            placed = true   // any interaction locks placement (stops auto floor-snapping)
        }

        if pinching {
            let world = input.spatialPinchDragDelta   // world-space movement of the pinch
            switch drag {
            case .ball:
                let d = worldDeltaToLocal(world)
                ballLocal.x = min(max(ballLocal.x + d.x, radius - 1), 1 - radius)
                ballLocal.y = min(max(ballLocal.y + d.y, radius - 1), 1.0)
                ballLocal.z = min(max(ballLocal.z + d.z, radius - 1), 1 - radius)
                velocity = .zero
            case .box:
                // Slide the pool along the floor following the hand.
                boxCenterXZ += simd_float2(world.x, world.z)
                if let floor = pickRealSurfacePosition(
                    rayOrigin: simd_float3(boxCenterXZ.x, floorY + 2.0, boxCenterXZ.y),
                    rayDirection: simd_float3(0, -1, 0), filter: .floorOnly
                ) {
                    floorY = floor.worldPosition.y
                }
            case .none:
                break
            }
        }
        if !pinching { drag = .none }
        grabbing = (drag == .ball)
        wasPinching = pinching

        // Until first placed/grabbed, snap to the detected floor (down-ray) so the pool
        // doesn't hang at the default height while ARKit warms up.
        if !placed, let floor = pickRealSurfacePosition(
            rayOrigin: simd_float3(boxCenterXZ.x, 3.0, boxCenterXZ.y),
            rayDirection: simd_float3(0, -1, 0), filter: .floorOnly
        ) {
            floorY = floor.worldPosition.y
        }

        // Two-hand pinch: scale + rotate (engine-detected). Allowed once placed.
        if placed {
            if input.spatialZoomActive {
                boxScale = min(max(boxScale * (1.0 + input.spatialZoomDelta), 0.15), 1.5)
            }
            if input.spatialRotateActive {
                boxYaw += input.spatialRotateDeltaRadians
            }
        }

        // When not held, the ball falls under gravity and bounces off the pool floor,
        // staying wherever it was released.
        if !grabbing {
            velocity.y += gravity * dt
            ballLocal += velocity * dt
            let floorBottom = radius - 1.0
            if ballLocal.y < floorBottom {
                ballLocal.y = floorBottom
                velocity.y = abs(velocity.y) * 0.6
                if abs(velocity.y) < 0.2 { velocity.y = 0 }
            }
            let limit = 1.0 - radius
            ballLocal.x = min(max(ballLocal.x, -limit), limit)
            ballLocal.z = min(max(ballLocal.z, -limit), limit)
        }

        setCoolWaterSphereCenter(ballLocal)
        updateModel()
    }

    func handleInput() {}
}

// MARK: - Matrix helpers

private extension simd_float4x4 {
    init(translation t: simd_float3) {
        self.init(
            simd_float4(1, 0, 0, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(t.x, t.y, t.z, 1)
        )
    }
    init(scale s: simd_float3) {
        self.init(
            simd_float4(s.x, 0, 0, 0),
            simd_float4(0, s.y, 0, 0),
            simd_float4(0, 0, s.z, 0),
            simd_float4(0, 0, 0, 1)
        )
    }
    init(rotationY a: Float) {
        let c = cos(a), s = sin(a)
        self.init(
            simd_float4(c, 0, -s, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(s, 0, c, 0),
            simd_float4(0, 0, 0, 1)
        )
    }
}

import Foundation
import simd

/// Controls for projecting the water's caustic light onto the surrounding room
/// surfaces (the reconstructed real walls/floor in AR). Disabled by default so
/// the effect is opt-in per demo.
public final class CoolWaterWallCaustics: @unchecked Sendable {
    public static let shared = CoolWaterWallCaustics()

    public struct Config: Sendable {
        public var enabled: Bool = false
        /// Additive brightness of the projected caustics.
        public var strength: Float = 1.2
        /// Colour tint applied to the projected light.
        public var tint: SIMD3<Float> = SIMD3<Float>(0.45, 0.72, 1.0)
        /// Zoom of the single caustic copy within the reflection window (≈1 shows
        /// one copy; >1 zooms in for finer ripples). Kept ≤~1 to avoid streaking.
        public var wallScale: Float = 1.0
        /// Perpendicular pool→wall distance (metres) beyond which the reflection
        /// fades out entirely.
        public var maxDistance: Float = 3.5
        /// Pool-local Y of the real floor (the pool rim sits at 2/12).
        public var floorLevel: Float = 2.0 / 12.0
        /// Vertical thickness (metres) of the reflection band on the wall.
        public var bandWidth: Float = 0.55
        /// Half-width (metres) the reflection spreads horizontally along the wall
        /// before fading — one caustic copy is mapped into this window (no tiling).
        public var lateralExtent: Float = 1.4
        /// How much the reflection band rises up the wall per metre of pool→wall
        /// distance (≈ tan of the light's elevation). Far wall → higher band.
        public var heightPerDistance: Float = 0.8
        /// Optional extra 3×3 box-blur of the caustic on the wall, in window-UV
        /// units. Default 0: anti-aliasing is handled by trilinear mipmapping of
        /// the caustics texture, which stays crisp up close and smooth at range
        /// without smearing. Raise only if you want a deliberately soft glow.
        public var blur: Float = 0.0

        public init() {}
    }

    private let lock = NSLock()
    private var config = Config()

    private init() {}

    public var isEnabled: Bool {
        get { lock.withLock { config.enabled } }
        set { lock.withLock { config.enabled = newValue } }
    }

    public func setConfig(_ config: Config) {
        lock.withLock { self.config = config }
    }

    func state() -> Config {
        lock.withLock { config }
    }

    /// Builds the shader params for a given light direction.
    func params(lightDirection: SIMD3<Float>) -> CoolWaterWallCausticsParams {
        let c = lock.withLock { config }
        let light = simd_length(lightDirection) > 1e-4
            ? simd_normalize(lightDirection)
            : SIMD3<Float>(0, 1, 0)
        return CoolWaterWallCausticsParams(
            tintStrength: SIMD4<Float>(c.tint.x, c.tint.y, c.tint.z, c.strength),
            config: SIMD4<Float>(c.wallScale, c.maxDistance, c.floorLevel, c.bandWidth),
            light: SIMD4<Float>(light.x, light.y, light.z, 0),
            poolCenter: SIMD4<Float>(0, 0, 0, 0),   // filled in by the render extension
            config2: SIMD4<Float>(c.lateralExtent, c.heightPerDistance, c.blur, 0)
        )
    }
}

// MARK: - Public free-function API

/// Enable or disable projecting the water caustics onto surrounding surfaces.
public func setCoolWaterWallCausticsEnabled(_ enabled: Bool) {
    CoolWaterWallCaustics.shared.isEnabled = enabled
}

/// Replace the full wall-caustics configuration.
public func setCoolWaterWallCausticsConfig(_ config: CoolWaterWallCaustics.Config) {
    CoolWaterWallCaustics.shared.setConfig(config)
}

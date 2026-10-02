import simd
import UntoldComponentKit
import UntoldEngine

/// Spins its entity while the scene is playing.
///
/// A component plugin: the editor lists it under Add Component for any entity. Add it
/// from the Inspector and press Play. Change `speed` here and save: with "Rebuild on save"
/// on, the editor picks the change up without restarting. For a kind of entity with its
/// own properties and shape, subclass EntityPlugin instead.
final class Spinner: ComponentPlugin {
    @UntoldAttribute("Degrees per second", range: -360 ... 360) var speed: Float = 90
    @UntoldAttribute var axis: SIMD3<Float> = [0, 1, 0]

    override func onUpdate(deltaTime: Float) {
        guard simd_length(axis) > 0 else { return }
        rotateBy(entityId: entity, angle: speed * deltaTime, axis: simd_normalize(axis))
    }
}

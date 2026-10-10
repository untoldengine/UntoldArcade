//
//  CoolMirrorGame.swift
//  CoolMirror
//
//  Virtual-mirror demo core: a rigged character standing in front of the user,
//  playing animation clips (live mocap arrives in a later phase), with the
//  engine's deformation stack switchable at runtime. Owns no rendering — the
//  engine draws the character; this class spawns it and forwards controls.
//

import CoolMirrorMocap
import Foundation
import simd
import UntoldEngine
import UntoldJoltPhysics

/// Characters bundled with the demo, each with its own rig and clips.
public enum CoolMirrorCharacter: String, CaseIterable, Sendable {
    case spiderman
    case batman
    case redplayer

    /// The source models are authored oversized (Spider-Man 2.05 m,
    /// Batman 2.22 m in the files); scale them to believable human heights
    /// for the mirror. Uniform scale composes after skinning and morphs.
    var displayScale: Float {
        switch self {
        case .redplayer: 1.0
        case .spiderman: 1.75 / 2.05
        case .batman: 1.90 / 2.22
        }
    }

    /// (clip name shown in UI, animation file name, file extension)
    public var clips: [(name: String, file: String, ext: String)] {
        switch self {
        case .redplayer:
            [("idle", "idle", "untold"), ("running", "running", "untold")]
        case .spiderman:
            // Two curl signs while we pin down which way the Mixamo rig
            // plays back on device — pick the anatomically correct one.
            [("flex", "spiderman_flex", "untoldanim"),
             ("flex-alt", "spiderman_flex_alt", "untoldanim")]
        case .batman:
            [("flex", "batman_flex", "untoldanim")]
        }
    }
}

/// How the muscle deltas are produced on top of skinning.
public enum CoolMirrorMuscleMode: String, CaseIterable, Sendable {
    case off
    /// Live XPBD volumetric muscle simulation.
    case simulation
    /// Network trained on the simulation (needs `<hero>.untoldml`).
    case mlDeformer
}

/// Skinning paths the mirror can switch between live.
public enum CoolMirrorSkinningPath: String, CaseIterable, Sendable {
    case vertexShader
    case computeLBS
    case computeDQS
    case computeDDM
}

@MainActor
public final class CoolMirrorGame {
    public private(set) var characterId: EntityID?
    public private(set) var character: CoolMirrorCharacter = .spiderman

    /// Called on the main actor when a character finishes loading (morph
    /// target names are available from then on).
    public var onCharacterReady: (() -> Void)?

    // Mirror framing: the character stands ~1.6 m in front of the world origin
    // and faces back toward the user like a reflection.
    private let characterPosition = simd_float3(0.0, 0.0, -1.6)
    private var skinningPath: CoolMirrorSkinningPath = .vertexShader
    private var currentClip: String?
    private var muscleMode: CoolMirrorMuscleMode = .off
    private var pausedByUser = false
    private let mocap = CoolMirrorMocapController()
    private let cape = CoolMirrorCape()
    private let joltCape = CoolMirrorJoltCape()
    private var capeMode: CoolMirrorCapeMode = .jolt
    private var muscleFlex: Float = 0
    private var mlDeformerWeight: Float = 1
    private var muscleCagesVisible = false
    private var disabledMuscles: Set<String> = []
    private var muscleActivations: [String: Float] = [:]
    private var generation = 0

    public init() {}

    public func start() {
        // Required for spatial input on visionOS: without these the engine
        // drops all XR events.
        registerXREvents()
        setSceneReady(true)
        setCharacter(character)
    }

    // Called from the XR render thread, between the animation update and
    // the render: the mocap controller retargets the newest iPhone frame
    // onto the character here (its own state is lock-protected).
    public nonisolated func update(deltaTime: Float) {
        mocap.update()
        cape.update(deltaTime: deltaTime)
        joltCape.update(deltaTime: deltaTime)
    }

    /// Installs the cloth plugin the cape uses; call once before the XR
    /// renderer is created.
    public static func registerRenderPlugins() {
        CoolMirrorCape.registerPlugin()
    }

    /// The Jolt backend the cape cloth lives in (registered by the app
    /// before the renderer is created).
    public func setJoltBackend(_ backend: JoltPhysicsBackend?) {
        joltCape.setBackend(backend)
    }

    /// How Batman's cape is done (no effect on the other characters): the
    /// model's rigid cape, the GPU sheet, or the cape mesh as Jolt cloth.
    public func setCapeMode(_ mode: CoolMirrorCapeMode) {
        capeMode = mode
        cape.setEnabled(mode == .sheet)
        joltCape.setEnabled(mode == .jolt)
        if mode == .jolt, skinningPath == .vertexShader {
            // The cloth writes into the deformation pass's output.
            setSkinningPath(.computeLBS)
        }
    }

    public func setCapeEnabled(_ enabled: Bool) {
        setCapeMode(enabled ? .jolt : .rigid)
    }

    public func hasCape() -> Bool {
        CoolMirrorCapeRig.rig(for: character) != nil
    }

    public nonisolated func handleInput() {}

    // MARK: - Controls (called from the SwiftUI control window)

    /// Called during immersive-space teardown, before the engine resets the
    /// world: drops entity references so late async loads touch nothing.
    public func prepareForShutdown() {
        generation += 1
        characterId = nil
        onCharacterReady = nil
        mocap.setCharacter(nil, mapping: nil)
        mocap.setEnabled(false)
        cape.setCharacter(nil, character: nil)
        joltCape.setCharacter(nil, character: nil)
    }

    public func setCharacter(_ newCharacter: CoolMirrorCharacter) {
        if let characterId {
            destroyEntity(entityId: characterId)
            self.characterId = nil
        }
        character = newCharacter
        currentClip = newCharacter.clips.first?.name
        generation += 1
        let expectedGeneration = generation

        let entity = createEntity()
        setEntityName(entityId: entity, name: "MirrorCharacter-\(newCharacter.rawValue)")
        characterId = entity

        setEntityMeshAsync(entityId: entity, filename: newCharacter.rawValue, withExtension: "untold") { [weak self] _ in
            guard let self, self.generation == expectedGeneration, let characterId = self.characterId else { return }
            for clip in newCharacter.clips {
                setEntityAnimations(
                    entityId: characterId,
                    filename: clip.file,
                    withExtension: clip.ext,
                    name: clip.name
                )
            }
            translateTo(entityId: characterId, position: self.characterPosition)
            rotateTo(entityId: characterId, angle: .pi, axis: simd_float3(0, 1, 0))
            scaleTo(entityId: characterId, scale: simd_float3(repeating: newCharacter.displayScale))
            setEntityMuscleRig(entityId: characterId, rig: CoolMirrorMuscles.rig(for: newCharacter))
            self.applyClip()
            self.applySkinningPath()
            self.mocap.setCharacter(
                characterId, mapping: CoolMirrorMocapMapping.mapping(for: newCharacter),
                hands: CoolMirrorMocapMapping.hands(for: newCharacter), origin: self.characterPosition
            )
            self.cape.setCharacter(characterId, character: newCharacter)
            self.joltCape.setCharacter(characterId, character: newCharacter)
            self.applyMocapPause()
            self.onCharacterReady?()
        }
    }

    public func setSkinningPath(_ path: CoolMirrorSkinningPath) {
        skinningPath = path
        applySkinningPath()
    }

    public func setClip(_ name: String) {
        currentClip = name
        applyClip()
    }

    /// Freeze playback on the current frame so skinning paths can be
    /// compared on the exact same pose.
    public func setPaused(_ paused: Bool) {
        pausedByUser = paused
        applyMocapPause()
    }

    // MARK: - iPhone motion capture

    /// Streams the user's body pose from the iPhone capture app onto the
    /// character (the clip freezes underneath; joints the capture drives
    /// follow the user, the rest keep the frozen pose).
    public func setMocapEnabled(_ enabled: Bool) {
        mocap.setEnabled(enabled)
        applyMocapPause()
    }

    /// Captures the next tracked frame as the pose matching the character's
    /// rest pose; call it while the user holds that pose.
    public func calibrateMocap() {
        mocap.requestCalibration()
    }

    /// `bodySmoothing` and `legSmoothing` go from 0 (raw tracker, shaky)
    /// to 1 (very steady, laggy); the legs setting also steadies the hips
    /// and where the character stands. With `armReach` the hands go where
    /// the captured hands are on the body (reach IK) instead of where the
    /// copied bone directions take them. With `headAnchor` the head is
    /// where the headset is and the planted feet stay where they landed;
    /// the phone gives the pose between them, not where the body is.
    /// With `headsetHands` the hands are where the headset sees them,
    /// the phone's taking over while it does not.
    public func setMocapOptions(
        mirror: Bool, flipFacing: Bool, weight: Float, rootMotion: Bool,
        bodySmoothing: Float = 0.4, legSmoothing: Float = 0.6, groundLock: Bool = true, plantFeet: Bool = false,
        armReach: Bool = true, headAnchor: Bool = true, headsetHands: Bool = true
    ) {
        mocap.isGroundLockEnabled = groundLock
        mocap.isHeadsetHandsEnabled = headsetHands
        mocap.isHeadAnchorEnabled = headAnchor
        mocap.isArmReachEnabled = armReach
        var options = MocapRetargetOptions()
        options.mirror = mirror
        options.flipFacing = flipFacing
        options.weight = weight
        options.rootTranslationScale = rootMotion ? 1 : 0
        options.smoothing.bodyCutoff = Self.smoothingCutoff(bodySmoothing)
        options.smoothing.legCutoff = Self.smoothingCutoff(legSmoothing)
        options.smoothing.rootCutoff = options.smoothing.legCutoff * 0.6
        options.smoothing.plantFeet = plantFeet
        mocap.options = options
    }

    /// 0 → 8 Hz (hardly any smoothing), 1 → 0.24 Hz, exponential in between.
    static func smoothingCutoff(_ amount: Float) -> Float {
        8 * powf(0.03, min(max(amount, 0), 1))
    }

    /// Draws the captured skeleton and the rig bones over the character.
    public func setMocapDebugOverlay(_ enabled: Bool) {
        mocap.isDebugOverlayEnabled = enabled
    }

    public func mocapStatus() -> String {
        mocap.status
    }

    public func mocapIsCalibrated() -> Bool {
        mocap.isCalibrated
    }

    /// Drives the character's head from the headset's own pose (world):
    /// its orientation turns the head (the phone cannot see it under the
    /// Vision Pro) and its position says where the head is. The provider
    /// runs on the render thread every frame; nil goes back to the neck
    /// and the phone's root.
    public func setMocapHeadPoseProvider(_ provider: (@Sendable () -> simd_float4x4?)?) {
        mocap.setHeadPoseProvider(provider)
    }

    /// Supplies the wearer's hands as the headset sees them (see
    /// `CoolMirrorHandSession`): the character's hands follow them, and
    /// they go into the recordings. The provider runs on the render
    /// thread every frame.
    public func setMocapHandProvider(_ provider: (@Sendable () -> [MocapHandSide: MocapHandSample])?) {
        mocap.setHandProvider(provider)
    }

    /// Whether an iPhone is connected to the mirror.
    public func mocapIsConnected() -> Bool {
        mocap.isConnected
    }

    /// Link state in one line (connected, rate, body seen).
    public func mocapConnectionSummary() -> String {
        mocap.connectionSummary
    }

    /// Whether the phone sees the whole body (calibrate only then).
    public func mocapIsFramed() -> Bool {
        mocap.isFramed
    }

    /// The phone's camera picture with the tracked joints, a few times a
    /// second, so the wearer can check the framing.
    public func mocapPreview() -> MocapPreviewFrame? {
        mocap.preview
    }

    /// Records the raw frames the phone sends, and the headset's head and
    /// hands at every frame it renders, into a new file in the app's
    /// Documents folder (shown in the Files app), for replaying on a Mac.
    /// Returns the file.
    public func startMocapRecording() -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("mocap-\(formatter.string(from: Date())).\(MocapRecording.fileExtension)")
        do {
            try mocap.startRecording(to: url)
            return url
        } catch {
            print("CoolMirror mocap: could not record to \(url.path): \(error)")
            return nil
        }
    }

    /// Notes what the wearer does from now on, in the recording.
    public func markMocapRecording(_ label: String) {
        mocap.markRecording(label)
    }

    /// Closes the recording; the file, how many frames of the phone's it
    /// holds and how many samples of the headset's.
    @discardableResult
    public func stopMocapRecording() -> (url: URL, frames: Int, headsetSamples: Int)? {
        mocap.stopRecording()
    }

    public func mocapRecordingFrameCount() -> Int? {
        mocap.recordingFrameCount
    }

    private func applyMocapPause() {
        guard let characterId else { return }
        // Mocap needs a frozen base pose; otherwise the user's pause choice.
        pauseAnimationComponent(entityId: characterId, isPaused: pausedByUser || mocap.isEnabled)
    }

    /// Pose-space deformation: authored drivers fire morphs from the pose
    /// automatically (the biceps bulge as the elbows curl).
    public func setPoseDrivers(enabled: Bool) {
        guard let characterId else { return }
        setEntityPoseDrivers(entityId: characterId, enabled: enabled)
    }

    /// Morph target weight passthrough. Applied by the deformation pass, so a
    /// compute skinning path must be active for the weight to show.
    public func setMorphWeight(name: String, weight: Float) {
        guard let characterId else { return }
        setEntityMorphTargetWeight(entityId: characterId, name: name, weight: weight)
    }

    public func morphTargetNames() -> [String] {
        guard let characterId else { return [] }
        return entityMorphTargetNames(entityId: characterId)
    }

    /// Volumetric muscles: XPBD tet cages built from the character's muscle
    /// rig, simulated on the GPU and wrapped onto the skin after skinning,
    /// or the ML deformer that learned those deltas. Needs a compute
    /// skinning path.
    public func setMuscleMode(_ mode: CoolMirrorMuscleMode) {
        muscleMode = mode
        applyMuscles()
    }

    /// Whether the current character ships a trained `.untoldml` payload.
    public func hasMLDeformer() -> Bool {
        guard let characterId else { return false }
        return entityHasMLDeformerPayload(entityId: characterId)
    }

    /// Blend of the ML deformer's delta (A/B against nothing).
    public func setMLDeformerWeight(_ weight: Float) {
        mlDeformerWeight = weight
        applyMuscles()
    }

    /// Flexes every muscle at once (0 = let the pose drivers decide).
    public func setMuscleFlex(_ value: Float) {
        muscleFlex = value
        applyMuscles()
    }

    public func muscleNames() -> [String] {
        guard let characterId else { return [] }
        return entityMuscleNames(entityId: characterId)
    }

    /// Draws every muscle cage as wireframe lines over the character
    /// (coloured by activation, bone capsules in cyan) to tune placement.
    public func setMuscleCagesVisible(_ visible: Bool) {
        muscleCagesVisible = visible
        setMuscleDebugOverlay(enabled: visible)
    }

    /// Hides one muscle (it keeps simulating but no longer moves the skin).
    public func setMuscleEnabled(name: String, enabled: Bool) {
        if enabled { disabledMuscles.remove(name) } else { disabledMuscles.insert(name) }
        guard let characterId else { return }
        setEntityMuscleEnabled(entityId: characterId, name: name, enabled: enabled)
    }

    /// Manual activation of one muscle (0 = back to its pose driver).
    public func setMuscleActivation(name: String, value: Float) {
        muscleActivations[name] = value
        guard let characterId else { return }
        setEntityMuscleActivation(entityId: characterId, name: name, activation: value)
    }

    public func clipNames() -> [String] {
        character.clips.map(\.name)
    }

    private func applySkinningPath() {
        guard let characterId else { return }
        switch skinningPath {
        case .vertexShader:
            removeEntityDeformation(entityId: characterId)
        case .computeLBS:
            setEntityDeformation(entityId: characterId, skinningMode: .lbs)
        case .computeDQS:
            setEntityDeformation(entityId: characterId, skinningMode: .dqs)
        case .computeDDM:
            setEntityDeformation(entityId: characterId, skinningMode: .ddm)
        }
        // The deformation component is recreated with the path; re-apply the
        // muscle settings on top of it.
        applyMuscles()
    }

    private func applyMuscles() {
        guard let characterId, skinningPath != .vertexShader else { return }
        setEntityMuscleSimulation(entityId: characterId, enabled: muscleMode == .simulation)
        setEntityMLDeformer(entityId: characterId, enabled: muscleMode == .mlDeformer)
        setEntityMLDeformerWeight(entityId: characterId, weight: mlDeformerWeight)
        setEntityMuscleActivationOverride(entityId: characterId, activation: muscleFlex > 0.01 ? muscleFlex : nil)
        for name in disabledMuscles {
            setEntityMuscleEnabled(entityId: characterId, name: name, enabled: false)
        }
        for (name, value) in muscleActivations {
            setEntityMuscleActivation(entityId: characterId, name: name, activation: value)
        }
        setMuscleDebugOverlay(enabled: muscleCagesVisible && muscleMode == .simulation)
    }

    private func applyClip() {
        guard let characterId, let currentClip else { return }
        changeAnimation(entityId: characterId, name: currentClip)
    }
}

/// How Batman's cape is done.
public enum CoolMirrorCapeMode: String, CaseIterable, Sendable {
    /// The model's own cape, skinned like the rest.
    case rigid
    /// The CoolCloth GPU sheet hanging from the shoulders.
    case sheet
    /// The cape mesh itself as Jolt cloth.
    case jolt
}

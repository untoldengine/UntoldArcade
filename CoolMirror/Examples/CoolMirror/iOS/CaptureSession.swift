//
//  CaptureSession.swift
//  CoolMirrorCapture
//

import ARKit
import CoolMirrorMocap
import CoreImage
import Foundation
import ImageIO
import Observation
import simd
import UIKit

/// Runs ARKit body tracking and streams every tracked body anchor update
/// as a `MocapFrame` to the mirror. Also projects the tracked skeleton onto
/// the camera preview so a screen recording of the phone shows the raw
/// tracking over the real body.
@Observable
@MainActor
final class CaptureSession: NSObject {
    static var isSupported: Bool { ARBodyTrackingConfiguration.isSupported }

    private(set) var status = "starting…"
    private(set) var isTracked = false
    private(set) var framesPerSecond = 0
    private(set) var trackedJointCount = 0
    private(set) var videoFormat = ""
    /// Raw motion between consecutive frames (see `MocapJitterMeter`).
    private(set) var jitterReport = ""
    /// Flip count since the last reset, to read after stepping out of view.
    private(set) var flipTotals = ""
    /// ARKit's body scale and distance, with how much each moved in the
    /// last second: a pose change that re-sizes or re-places the whole
    /// skeleton shows here, not in the joints.
    private(set) var scaleReport = ""
    /// Raw frames written to a file in Documents (visible in the Files
    /// app, to share) while recording, for replaying on a Mac.
    private(set) var recording: MocapRecordingWriter?
    private(set) var recordingReport = ""
    var isRecording: Bool {
        get { recording != nil }
        set { newValue ? startRecording() : stopRecording() }
    }

    /// Skeleton overlay: joints projected into the preview view, in points.
    var showSkeleton = true
    private(set) var overlayPoints: [MocapJoint: CGPoint] = [:]
    private(set) var overlayTracked: Set<MocapJoint> = []
    /// Camera frame rate to ask for (the tracker runs at the camera rate; a
    /// lower rate gives each frame more exposure).
    var preferredFrameRate = 60 {
        didSet { if preferredFrameRate != oldValue, isRunning { start() } }
    }

    /// Whether ARKit re-estimates the person's size as it tracks. Off, the
    /// skeleton keeps ARKit's default proportions and only its placement
    /// follows the picture; on, a change of pose (arms up) can re-size and
    /// re-place the whole skeleton at once, which the mirror shows as a jump.
    var automaticScale = false {
        didSet { if automaticScale != oldValue, isRunning { start() } }
    }

    private var isRunning = false
    /// Set by the preview view from its layout.
    var viewportSize = CGSize.zero
    var interfaceOrientation: UIInterfaceOrientation = .landscapeRight {
        didSet { previewLock.withLock { sharedOrientation = interfaceOrientation } }
    }

    let session = ARSession()
    private let sender = MocapSender()
    /// Camera preview for the headset: this wide, this often. Encoded on
    /// ARKit's delegate queue (holding frames for the main actor would make
    /// ARKit stop delivering them); the state below belongs to that queue,
    /// except what the lock guards, which the main actor writes.
    private static let previewWidth: CGFloat = 320
    private static let previewInterval: TimeInterval = 0.1
    private nonisolated let previewContext = CIContext(options: [.cacheIntermediates: false])
    private nonisolated(unsafe) var lastPreviewTime: TimeInterval = 0
    private nonisolated(unsafe) var previewId: UInt32 = 0
    private nonisolated let previewLock = NSLock()
    private nonisolated(unsafe) var sharedOrientation: UIInterfaceOrientation = .landscapeRight
    private nonisolated(unsafe) var sharedBody: ARBodyAnchor?
    private(set) var previewsSent = 0
    private(set) var previewFailures = 0
    private(set) var cameraFrames = 0
    private var sentTimes: [TimeInterval] = []
    private var statusTimer: Timer?
    private var jitter = MocapJitterMeter()
    /// (time, ARKit scale factor, body distance from the camera) over the last second.
    private var scaleSamples: [(TimeInterval, Float, Float)] = []

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard Self.isSupported else {
            status = "unsupported device"
            return
        }
        let configuration = ARBodyTrackingConfiguration()
        configuration.automaticSkeletonScaleEstimationEnabled = automaticScale
        // Body tracking only: nothing else competes for the frame (the
        // frame semantics stay at their default, .bodyDetection, which the
        // 3D tracker relies on).
        configuration.planeDetection = []
        configuration.environmentTexturing = .none
        // The largest format at the requested rate (or the nearest rate
        // the device offers).
        let formats = ARBodyTrackingConfiguration.supportedVideoFormats
        let rates = Set(formats.map(\.framesPerSecond))
        let rate = rates.min { abs($0 - preferredFrameRate) < abs($1 - preferredFrameRate) } ?? preferredFrameRate
        if let format = formats.filter({ $0.framesPerSecond == rate }).max(by: { $0.imageResolution.width < $1.imageResolution.width }) {
            configuration.videoFormat = format
        }
        videoFormat = "\(Int(configuration.videoFormat.imageResolution.width))×\(Int(configuration.videoFormat.imageResolution.height)) @ \(configuration.videoFormat.framesPerSecond) fps"
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        if !sender.isConnected {
            sender.start()
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func stop() {
        stopRecording()
        statusTimer?.invalidate()
        statusTimer = nil
        sender.stop()
        session.pause()
        isRunning = false
        status = "stopped"
    }

    private func refreshStatus() {
        let now = Date().timeIntervalSinceReferenceDate
        sentTimes.removeAll { now - $0 > 1 }
        framesPerSecond = sentTimes.count
        status = sender.status
        jitterReport = jitter.report
        flipTotals = jitter.totals
        scaleSamples.removeAll { now - $0.0 > 1 }
        if let last = scaleSamples.last {
            let scales = scaleSamples.map(\.1), distances = scaleSamples.map(\.2)
            scaleReport = String(
                format: "ARKit body scale %.3f (moved %.3f in 1 s) · distance %.2f m (moved %.2f m in 1 s)",
                last.1, (scales.max() ?? 0) - (scales.min() ?? 0), last.2, (distances.max() ?? 0) - (distances.min() ?? 0)
            )
        } else {
            scaleReport = ""
        }
    }

    func startRecording() {
        guard recording == nil else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("mocap-\(formatter.string(from: Date())).\(MocapRecording.fileExtension)")
        do {
            recording = try MocapRecordingWriter(url: url)
            recordingReport = "Recording to \(url.lastPathComponent)"
        } catch {
            recordingReport = "Could not record: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard let recording else { return }
        recording.close()
        recordingReport = "Saved \(recording.frameCount) frames to \(recording.url.lastPathComponent) (Files app → On My iPhone → CoolMirror Capture)"
        self.recording = nil
    }

    func resetCounters() {
        jitter.reset()
        flipTotals = jitter.totals
    }

    /// Builds the wire frame from the anchor: joint transforms in the
    /// anchor's space, the anchor's own world orientation as `.root`, its
    /// world position and which joints ARKit actually saw.
    nonisolated static func frame(from anchor: ARBodyAnchor, timestamp: TimeInterval) -> MocapFrame {
        let definition = ARSkeletonDefinition.defaultBody3D
        let skeleton = anchor.skeleton
        let transforms = skeleton.jointModelTransforms
        var rotations: [MocapJoint: simd_quatf] = [:]
        var positions: [MocapJoint: simd_float3] = [:]
        var tracked: Set<MocapJoint> = []
        for joint in MocapJoint.allCases {
            if joint == .root {
                rotations[.root] = simd_quatf(anchor.transform)
                positions[.root] = .zero
                tracked.insert(.root)
            } else {
                let index = definition.index(for: ARSkeleton.JointName(rawValue: joint.arKitName))
                if index != NSNotFound, index >= 0, index < transforms.count {
                    let transform = transforms[index]
                    rotations[joint] = simd_quatf(transform)
                    positions[joint] = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                    if skeleton.isJointTracked(index) {
                        tracked.insert(joint)
                    }
                }
            }
        }
        let position = anchor.transform.columns.3
        return MocapFrame(
            sequence: 0,
            timestamp: timestamp,
            isTracked: anchor.isTracked,
            rootPosition: simd_float3(position.x, position.y, position.z),
            rotations: rotations,
            positions: positions,
            trackedJoints: tracked
        )
    }

    /// Encodes and sends the small camera picture with the joints in it.
    /// Runs on ARKit's delegate queue.
    private nonisolated func sendPreview(for frame: ARFrame) {
        let now = frame.timestamp
        guard now - lastPreviewTime >= Self.previewInterval else { return }
        lastPreviewTime = now
        let (orientation, body) = previewLock.withLock { (sharedOrientation, sharedBody) }
        var image = CIImage(cvPixelBuffer: frame.capturedImage)
        // The buffer is in the camera's native landscape (home button on
        // the right); the other landscape is the same picture upside down.
        if orientation == .landscapeLeft {
            image = image.oriented(.down)
        }
        let scale = Self.previewWidth / image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        let size = CGSize(width: image.extent.width.rounded(), height: image.extent.height.rounded())
        guard let cgImage = previewContext.createCGImage(image, from: CGRect(origin: .zero, size: size)),
              let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.4)
        else {
            Task { @MainActor in self.previewFailures += 1 }
            return
        }
        var keypoints: [MocapJoint: SIMD2<Float>] = [:]
        if let body, body.isTracked {
            let mocap = Self.frame(from: body, timestamp: now)
            for (joint, position) in mocap.positions {
                let world = body.transform * simd_float4(position, 1)
                let point = frame.camera.projectPoint(simd_float3(world.x, world.y, world.z), orientation: orientation, viewportSize: size)
                if point.x.isFinite, point.y.isFinite {
                    keypoints[joint] = SIMD2(Float(point.x), Float(point.y))
                }
            }
        }
        previewId &+= 1
        let preview = MocapPreviewFrame(
            id: previewId, width: UInt16(size.width), height: UInt16(size.height), jpeg: jpeg, keypoints: keypoints
        )
        sender.send(preview)
        Task { @MainActor in self.previewsSent += 1 }
    }

    /// Projects the body's joints into the preview for the overlay.
    private func updateOverlay(camera: ARCamera, body: ARBodyAnchor, frame: MocapFrame) {
        guard showSkeleton, viewportSize.width > 0 else {
            overlayPoints = [:]
            return
        }
        var points: [MocapJoint: CGPoint] = [:]
        for (joint, position) in frame.positions {
            let world = body.transform * simd_float4(position, 1)
            let point = camera.projectPoint(
                simd_float3(world.x, world.y, world.z), orientation: interfaceOrientation, viewportSize: viewportSize
            )
            if point.x.isFinite, point.y.isFinite {
                points[joint] = point
            }
        }
        overlayPoints = points
        overlayTracked = frame.trackedJoints
    }
}

extension CaptureSession: ARSessionDelegate {
    nonisolated func session(_: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let body = anchors.compactMap({ $0 as? ARBodyAnchor }).first else { return }
        let timestamp = Date().timeIntervalSinceReferenceDate
        var frame = Self.frame(from: body, timestamp: timestamp)
        previewLock.withLock { sharedBody = body }
        let scale = Float(body.estimatedScaleFactor)
        Task { @MainActor in
            self.isTracked = body.isTracked
            self.trackedJointCount = frame.trackedJoints.count
            if let recording = self.recording {
                recording.append(frame)
                if recording.frameCount % 30 == 0 {
                    self.recordingReport = "Recording \(recording.frameCount) frames to \(recording.url.lastPathComponent)"
                }
            }
            if let camera = self.session.currentFrame?.camera {
                let eye = camera.transform.columns.3
                self.scaleSamples.append((timestamp, scale, simd_length(frame.rootPosition - simd_float3(eye.x, eye.y, eye.z))))
            }
            self.sender.send(frame)
            self.sentTimes.append(frame.timestamp)
            // The sender assigns sequence numbers; the meter only needs
            // successive frames to differ.
            frame.sequence = UInt32(truncatingIfNeeded: self.sentTimes.count) &+ UInt32(truncatingIfNeeded: Int(timestamp * 1000))
            self.jitter.add(frame, at: timestamp)
            if let camera = self.session.currentFrame?.camera {
                self.updateOverlay(camera: camera, body: body, frame: frame)
            }
        }
    }

    nonisolated func session(_: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in self.cameraFrames += 1 }
        sendPreview(for: frame)
    }

    nonisolated func session(_: ARSession, didFailWithError error: Error) {
        Task { @MainActor in self.status = "ARKit failed: \(error.localizedDescription)" }
    }
}

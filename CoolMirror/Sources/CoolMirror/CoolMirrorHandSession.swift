//
//  CoolMirrorHandSession.swift
//  CoolMirror
//
//  The wearer's hands as the headset sees them: an ARKit session of the
//  mirror's own (the engine's runs world tracking) with hand tracking.
//  The providers are made anew on every start: ARKit's run once.
//

#if os(visionOS)
    import ARKit
    import CoolMirrorMocap
    import Foundation
    import simd

    public final class CoolMirrorHandSession: @unchecked Sendable {
        private let session = ARKitSession()
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var latest: [MocapHandSide: MocapHandSample] = [:]

        public init() {}

        public static var isSupported: Bool {
            HandTrackingProvider.isSupported
        }

        /// The hands as last reported; a hand the headset has dropped is
        /// absent, one it keeps but does not see is there, untracked.
        public var hands: [MocapHandSide: MocapHandSample] {
            lock.withLock { latest }
        }

        public func start() {
            guard Self.isSupported else { return }
            lock.withLock {
                guard task == nil else { return }
                task = Task { [weak self] in
                    guard let self else { return }
                    let provider = HandTrackingProvider()
                    do {
                        try await session.run([provider])
                    } catch {
                        print("CoolMirror: hand tracking failed to run: \(error)")
                        finished()
                        return
                    }
                    for await update in provider.anchorUpdates {
                        guard !Task.isCancelled else { break }
                        handle(update)
                    }
                    finished()
                }
            }
        }

        public func stop() {
            let running = lock.withLock { () -> Task<Void, Never>? in
                defer {
                    task = nil
                    latest.removeAll()
                }
                return task
            }
            running?.cancel()
            session.stop()
        }

        private func finished() {
            lock.withLock {
                task = nil
                latest.removeAll()
            }
        }

        private func handle(_ update: AnchorUpdate<HandAnchor>) {
            let anchor = update.anchor
            let side: MocapHandSide = anchor.chirality == .left ? .left : .right
            guard update.event != .removed else {
                lock.withLock { latest[side] = nil }
                return
            }
            let sample = Self.sample(of: anchor)
            lock.withLock { latest[side] = sample }
        }

        private static let joints: [(MocapHandJoint, HandSkeleton.JointName)] = [
            (.wrist, .wrist),
            (.thumbKnuckle, .thumbKnuckle), (.thumbIntermediateBase, .thumbIntermediateBase),
            (.thumbIntermediateTip, .thumbIntermediateTip), (.thumbTip, .thumbTip),
            (.indexFingerMetacarpal, .indexFingerMetacarpal), (.indexFingerKnuckle, .indexFingerKnuckle),
            (.indexFingerIntermediateBase, .indexFingerIntermediateBase),
            (.indexFingerIntermediateTip, .indexFingerIntermediateTip), (.indexFingerTip, .indexFingerTip),
            (.middleFingerMetacarpal, .middleFingerMetacarpal), (.middleFingerKnuckle, .middleFingerKnuckle),
            (.middleFingerIntermediateBase, .middleFingerIntermediateBase),
            (.middleFingerIntermediateTip, .middleFingerIntermediateTip), (.middleFingerTip, .middleFingerTip),
            (.ringFingerMetacarpal, .ringFingerMetacarpal), (.ringFingerKnuckle, .ringFingerKnuckle),
            (.ringFingerIntermediateBase, .ringFingerIntermediateBase),
            (.ringFingerIntermediateTip, .ringFingerIntermediateTip), (.ringFingerTip, .ringFingerTip),
            (.littleFingerMetacarpal, .littleFingerMetacarpal), (.littleFingerKnuckle, .littleFingerKnuckle),
            (.littleFingerIntermediateBase, .littleFingerIntermediateBase),
            (.littleFingerIntermediateTip, .littleFingerIntermediateTip), (.littleFingerTip, .littleFingerTip),
            (.forearmWrist, .forearmWrist), (.forearmArm, .forearmArm),
        ]

        /// The anchor sits at the wrist; the joints are given in its axes.
        private static func sample(of anchor: HandAnchor) -> MocapHandSample {
            var sample = MocapHandSample(isTracked: anchor.isTracked, wrist: MocapPose(anchor.originFromAnchorTransform))
            guard let skeleton = anchor.handSkeleton else { return sample }
            for (joint, name) in joints {
                let transform = skeleton.joint(name).anchorFromJointTransform
                sample.joints[joint] = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            }
            return sample
        }
    }
#endif

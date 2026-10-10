//
//  BodyTrackingView.swift
//  CoolMirrorCapture
//

import ARKit
import CoolMirrorMocap
import RealityKit
import SwiftUI

/// Camera preview running the capture session (no virtual content; the
/// character is drawn on the Vision Pro). Reports its size and orientation
/// to the session so the skeleton overlay projects correctly.
struct BodyTrackingView: UIViewRepresentable {
    let session: CaptureSession

    func makeUIView(context _: Context) -> PreviewARView {
        let view = PreviewARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session.session
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disablePersonOcclusion, .disableGroundingShadows]
        view.capture = session
        return view
    }

    func updateUIView(_: PreviewARView, context _: Context) {}
}

final class PreviewARView: ARView {
    weak var capture: CaptureSession?

    override func layoutSubviews() {
        super.layoutSubviews()
        capture?.viewportSize = bounds.size
        if let orientation = window?.windowScene?.interfaceOrientation, orientation != .unknown {
            capture?.interfaceOrientation = orientation
        }
    }
}

/// The tracked skeleton drawn over the camera image: orange bones, red
/// where ARKit lost the joint and is guessing.
struct SkeletonOverlay: View {
    let points: [MocapJoint: CGPoint]
    let tracked: Set<MocapJoint>

    var body: some View {
        Canvas { context, _ in
            for joint in MocapJoint.allCases {
                guard let parent = joint.parent, let a = points[parent], let b = points[joint] else { continue }
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                let color: Color = tracked.contains(joint) ? .orange : .red
                context.stroke(path, with: .color(color), lineWidth: 3)
            }
            for (joint, point) in points {
                let radius: CGFloat = joint == .hips || joint == .head ? 6 : 4
                let dot = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                context.fill(dot, with: .color(tracked.contains(joint) ? .yellow : .red))
            }
        }
        .allowsHitTesting(false)
    }
}

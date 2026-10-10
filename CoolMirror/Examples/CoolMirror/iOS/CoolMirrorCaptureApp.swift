//
//  CoolMirrorCaptureApp.swift
//  CoolMirrorCapture
//
//  Put the iPhone sideways on a stand facing you (ARKit body tracking only
//  works in landscape): it tracks your body and streams the pose over the
//  local network to the CoolMirror visionOS app, which retargets it onto the
//  character in front of you like a mirror.
//

import CoolMirrorMocap
import SwiftUI

@main
struct CoolMirrorCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var capture = CaptureSession()

    var body: some View {
        ZStack(alignment: .bottom) {
            if CaptureSession.isSupported {
                BodyTrackingView(session: capture)
                    .ignoresSafeArea()
                    .overlay {
                        if capture.showSkeleton {
                            SkeletonOverlay(points: capture.overlayPoints, tracked: capture.overlayTracked)
                                .ignoresSafeArea()
                        }
                    }
            } else {
                ContentUnavailableView(
                    "Body tracking not supported",
                    systemImage: "figure.walk.motion",
                    description: Text("This iPhone cannot run ARKit body tracking (needs an A12 chip or newer).")
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(capture.isTracked ? "Body tracked (\(capture.trackedJointCount)/\(MocapJoint.allCases.count) joints seen)" : "Phone sideways, 3–4 m away, whole body in view", systemImage: capture.isTracked ? "figure.stand" : "figure.walk.motion")
                        .font(.headline)
                    Spacer()
                    Picker("Rate", selection: $capture.preferredFrameRate) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    Toggle("Skeleton", isOn: $capture.showSkeleton)
                        .toggleStyle(.button)
                    Toggle("Auto scale", isOn: $capture.automaticScale)
                        .toggleStyle(.button)
                    Toggle("Record", isOn: $capture.isRecording)
                        .toggleStyle(.button)
                }
                if !capture.recordingReport.isEmpty {
                    Text(capture.recordingReport)
                        .font(.footnote)
                }
                Text("\(capture.status) · \(capture.videoFormat)")
                    .font(.footnote)
                if !capture.scaleReport.isEmpty {
                    Text(capture.scaleReport)
                        .font(.footnote.monospacedDigit())
                }
                Text("\(capture.framesPerSecond) frames/s sent · camera frames \(capture.cameraFrames) · pictures sent \(capture.previewsSent), failed \(capture.previewFailures) · \(capture.jitterReport)")
                    .font(.footnote.monospacedDigit())
                HStack {
                    Text("Since reset: \(capture.flipTotals)")
                        .font(.footnote.monospacedDigit())
                    Spacer()
                    Button("Reset counters") { capture.resetCounters() }
                        .font(.footnote)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding()
        }
        .onAppear { capture.start() }
        .onDisappear { capture.stop() }
    }
}

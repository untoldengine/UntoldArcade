//
//  ViewerApp.swift
//  Untold Viewer
//
//  A comparison bench for the Untold Engine on Vision Pro: the same objects,
//  at the same spot in the room, drawn by the engine or by RealityKit, so
//  sharpness, aliasing, lighting and frame time can be compared while the
//  engine is pushed. One immersive space is open at a time; the Controls
//  window switches between them.
//

import CompositorServices
import os
import SwiftUI
import UntoldEngine
import UntoldEngineXR

@main
struct ViewerApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some SwiftUI.Scene {
        WindowGroup(id: "Controls") {
            ControlsView(
                show: { renderer in await show(renderer) },
                hideWindow: { dismissWindow(id: "Controls") },
                measurementWindows: MeasurementWindows(
                    hideControls: { dismissWindow(id: "Controls") },
                    showControls: { openWindow(id: "Controls") },
                    showStatus: { openWindow(id: "Status") },
                    hideStatus: { dismissWindow(id: "Status") }
                )
            )
        }
        .windowStyle(.plain)
        .defaultSize(width: 1100, height: 720)
        .defaultWindowPlacement { _, context in
            // Reopened after a pass: back where it was, which is where the pill is.
            if let status = context.windows.first(where: { $0.id == "Status" }) {
                return WindowPlacement(.replacing(status))
            }
            return WindowPlacement()
        }

        // The measurement pass's pill: it takes the main window's spot (straight
        // ahead at eye level; the object goes under it), and stays open across
        // both spaces so the app stays alive while the main window is hidden.
        WindowGroup(id: "Status") {
            MeasureStatusView()
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, context in
            if let main = context.windows.first(where: { $0.id == "Controls" }) {
                return WindowPlacement(.replacing(main))
            }
            return WindowPlacement()
        }

        ImmersiveSpace(id: "Engine") {
            CompositorLayer(configuration: ViewerLayerConfiguration()) { layerRenderer in
                EngineSession.shared.start(layerRenderer: layerRenderer)
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
        // The compositor hides the hands behind the engine's content from the depth
        // the layer writes: the one documented, visible check that our depth reaches it.
        .upperLimbVisibility(.automatic)

        ImmersiveSpace(id: "RealityKit") {
            RealityKitSpaceView()
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
        .upperLimbVisibility(.automatic)
    }

    private static let log = Logger(subsystem: "com.untoldengine.untoldviewer", category: "spaces")

    /// Closes whichever space is open, waits for it to be gone (the engine
    /// session is released by its render thread after the loop returns, and
    /// the system takes a moment more to tear the space down), then opens the
    /// requested renderer's space, trying again when the system refuses
    /// because the last one is still closing. Nil just closes.
    @MainActor
    private func show(_ renderer: Renderer?) async {
        if EngineSession.shared.isOpen || RealityKitSpaceState.shared.isOpen {
            await dismissImmersiveSpace()
        }
        for _ in 0 ..< 60 where EngineSession.shared.xr != nil || EngineSession.shared.isOpen || RealityKitSpaceState.shared.isOpen {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let renderer else { return }
        let id = renderer == .engine ? "Engine" : "RealityKit"
        for attempt in 1 ... 5 {
            let result = await openImmersiveSpace(id: id)
            EngineSession.shared.lastOpenResult = String(describing: result)
            if case .opened = result {
                consoleLine("\(id) space opened (attempt \(attempt))")
                Self.log.log("\(id, privacy: .public) space opened (attempt \(attempt))")
                return
            }
            consoleLine("\(id) space did not open (attempt \(attempt)): \(String(describing: result))")
            Self.log.error("\(id, privacy: .public) space did not open (attempt \(attempt)): \(String(describing: result), privacy: .public)")
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

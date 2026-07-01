//
//  WebGLWaterXRApp.swift  (visionOS)
//  WebGLWater
//
//  Mixed-reality build: renders the water pool into a box placed on the real floor.
//

import SwiftUI
import CompositorServices
import UntoldEngine
import CoolWater
import UntoldEngineXR

// Retains the XR system + game so they aren't deallocated.
final class XRHolder {
    static let shared = XRHolder()
    var xr: UntoldEngineXR?
    var game: WaterXRGame?
    var renderThread: Thread?
}

struct WaterLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        // Use the standard visionOS layer format (matches UntoldImmersive). The water
        // shader's display-space output gets sRGB-encoded here, so it reads a bit
        // brighter than macOS/iOS — acceptable for now, tunable later.
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

@main
struct WebGLWaterXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some SwiftUI.Scene {
        WindowGroup {
            VStack(spacing: 24) {
                Text("WebGL Water").font(.extraLargeTitle).fontWeight(.bold)
                Text("Pinch while looking at the floor to place the pool.\nTwo-hand pinch to resize/rotate. Pinch the ball to move it.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button {
                    Task { await openImmersiveSpace(id: "Water") }
                } label: {
                    Label("Enter Mixed Reality", systemImage: "drop.fill").frame(minWidth: 260)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(60)
        }
        .windowStyle(.plain)
        .defaultSize(width: 560, height: 360)

        ImmersiveSpace(id: "Water") {
            CompositorLayer(configuration: WaterLayerConfiguration()) { layerRenderer in
                guard XRHolder.shared.xr == nil else { return }
                guard installCoolWater() else { return }

                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                XRHolder.shared.xr = xr
                xr.setImmersionMode(xrImmersionMode: .mixed)

                // The CompositorLayer renderer closure is @MainActor, so set up directly
                // here (matches the engine's XR template). The blocking render loop runs
                // on its own plain Thread — NOT the main actor.
                let game = WaterXRGame()
                XRHolder.shared.game = game
                game.start()
                xr.setupCallbacks(
                    gameUpdate: { dt in game.update(deltaTime: dt) },
                    handleInput: { game.handleInput() }
                )

                let t = Thread {
                    xr.start()
                    xr.runLoop()
                }
                t.name = "XR Render Thread"
                t.qualityOfService = .userInteractive
                XRHolder.shared.renderThread = t
                t.start()
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }

    private func installCoolWater() -> Bool {
        switch registerCoolWaterPlugin() {
        case .installed, .replaced:
            return true
        case let .rejected(failure):
            print("CoolWater installation rejected:", failure)
            return false
        }
    }
}

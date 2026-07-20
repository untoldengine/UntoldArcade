//
//  CoolClothVisionOSXRApp.swift  (visionOS)
//  CoolCloth
//
//  Mixed-reality build: hangs a simulated silk sheet in the real room.
//  The control window keeps working while immersed — material, attachment,
//  and wind changes apply live.
//

import SwiftUI
import CompositorServices
import UntoldEngine
import CoolCloth
import UntoldEngineXR

// Retains the XR system + game so they aren't deallocated.
final class XRHolder {
    static let shared = XRHolder()
    var xr: UntoldEngineXR?
    var game: ClothXRGame?
    var renderThread: Thread?
}

struct ClothLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

/// UI-facing knobs; every change is pushed straight into the CoolCloth API.
@Observable
final class ClothControls {
    var material: CoolClothMaterialPreset = .silk {
        didSet { setCoolClothMaterial(material) }
    }
    var pinMode: CoolClothPinMode = .topEdge {
        didSet { resetCoolCloth(pinMode: pinMode) }
    }
    var windStrength: Double = 0.35 {
        didSet { pushWind() }
    }
    var gustiness: Double = 0.5 {
        didSet { pushWind() }
    }
    var occlusionEnabled = true {
        didSet { setCoolClothOcclusionEnabled(occlusionEnabled) }
    }

    private func pushWind() {
        setCoolClothWind(
            directionWorld: SIMD3<Float>(0.2, 0, 1),
            strength: Float(windStrength),
            gustiness: Float(gustiness)
        )
    }
}

@main
struct CoolClothVisionOSXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var immersionStyle: ImmersionStyle = .mixed
    @State private var controls = ClothControls()

    var body: some SwiftUI.Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("Cool Cloth").font(.extraLargeTitle).fontWeight(.bold)
                Text("Pinch the cloth to grab it, pinch the ball to throw it through the sheet.\nPinch elsewhere to move the cloth, two-hand pinch to resize/rotate.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)

                Button {
                    Task { await openImmersiveSpace(id: "Cloth") }
                } label: {
                    Label("Enter Mixed Reality", systemImage: "wind").frame(minWidth: 260)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                #if targetEnvironment(simulator)
                // The simulator has no hands: enter the immersive space directly.
                .task { await openImmersiveSpace(id: "Cloth") }
                #endif

                Toggle("Real-world occlusion", isOn: $controls.occlusionEnabled)
                    .frame(maxWidth: 320)

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        Text("Material")
                        Picker("Material", selection: $controls.material) {
                            Text("Silk").tag(CoolClothMaterialPreset.silk)
                            Text("Cotton").tag(CoolClothMaterialPreset.cotton)
                            Text("Denim").tag(CoolClothMaterialPreset.denim)
                            Text("Rubber").tag(CoolClothMaterialPreset.rubber)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    GridRow {
                        Text("Hang")
                        Picker("Hang", selection: $controls.pinMode) {
                            Text("Curtain").tag(CoolClothPinMode.topEdge)
                            Text("Banner").tag(CoolClothPinMode.topCorners)
                            Text("Flag").tag(CoolClothPinMode.leftEdge)
                            Text("Drop").tag(CoolClothPinMode.none)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    GridRow {
                        Text("Wind")
                        Slider(value: $controls.windStrength, in: 0 ... 3)
                    }
                    GridRow {
                        Text("Gusts")
                        Slider(value: $controls.gustiness, in: 0 ... 2)
                    }
                }

                Button("Reset Cloth") {
                    resetCoolCloth()
                }
                .buttonStyle(.bordered)
            }
            .padding(48)
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 560)

        ImmersiveSpace(id: "Cloth") {
            CompositorLayer(configuration: ClothLayerConfiguration()) { layerRenderer in
                guard XRHolder.shared.xr == nil else { return }
                guard installCoolCloth() else { return }

                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                XRHolder.shared.xr = xr
                xr.setImmersionMode(xrImmersionMode: .mixed)

                // The CompositorLayer renderer closure is @MainActor, so set up directly
                // here (matches the engine's XR template). The blocking render loop runs
                // on its own plain Thread — NOT the main actor.
                let game = ClothXRGame()
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

    private func installCoolCloth() -> Bool {
        switch registerCoolClothPlugin() {
        case .installed, .replaced:
            return true
        case let .rejected(failure):
            print("CoolCloth installation rejected:", failure)
            return false
        }
    }
}

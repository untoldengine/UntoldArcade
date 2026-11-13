//
//  LayerConfiguration.swift
//  Untold Viewer
//

import CompositorServices
import SwiftUI

struct ViewerLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        // The engine draws through the compositor's rasterization rate maps
        // (dense where the eyes look), which is also what lets us ask for a
        // render quality above the platform default. False on the simulator.
        configuration.isFoveationEnabled = capabilities.supportsFoveation && RenderSettings.foveationWanted
        configuration.colorFormat = .bgra8Unorm_srgb
        RenderSettings.applyToLayerConfiguration(capabilities: capabilities, configuration: &configuration)
    }
}

//
//  RenderSettings.swift
//  Untold Viewer
//
//  The engine's rendering settings the Controls window edits, persisted in
//  UserDefaults and applied around the XR runtime's creation: the
//  anti-aliasing mode is read when the renderer initialises, the lighting mode
//  once the runtime exists, the render quality in the layer configuration.
//  A change applies the next time the engine space is opened.
//

import ARKit
import CompositorServices
import Foundation
import UntoldEngine
import UntoldEngineXR

enum RenderSettings {
    static let antiAliasingKey = "antiAliasing"   // "msaaTaa" | "msaa" | "taa" | "fxaa"
    static let msaaSamplesKey = "msaaSamples"     // "2" | "4": the samples of the MSAA modes
    static let lightingKey = "lighting"           // "room" | "studio"
    static let renderQualityKey = "renderQuality" // "default" | "high" | "max"
    static let foveationAvailableKey = "foveationAvailable"
    static let foveationKey = "foveation"         // the compositor's rasterization rate maps; applied when the space opens
    static let taaHistoryWeightKey = "taaHistoryWeight"
    static let taaClipGammaKey = "taaClipGamma"
    // Diagnostics, live: which engine system blinks a moving object.
    static let occlusionCullKey = "occlusionCull"     // the test against the previous frame's depth pyramid
    static let taaJitterKey = "taaJitter"             // the sub-pixel jitter (the resolve still runs)
    static let textureStreamingKey = "textureStreaming" // texture tiers by screen coverage
    static let tileLightStageKey = "tileLightStage"     // the light pass as a tile stage (once per pixel) vs the quad (once per sample)
    static let hiddenSurfaceRemovalKey = "hiddenSurfaceRemoval" // opaque draws through the model pipeline without discards
    // Shading-cost experiments, off by default: what the frame costs without that shading.
    static let gpuPassTimingKey = "gpuPassTiming"       // the GPU times each pass; the summary lists them
    static let renderPathKey = "renderPath"               // "forward" (the headset's default), "hybrid" or "deferred": where the geometry is shaded
    static let shadowTapsKey = "shadowTaps"               // the sun shadow's compares per fragment: 8 (the headset default), 16 (the whole Poisson disk) or 4
    static let sunKey = "sun"                             // the viewer's sun over the wearer's shoulder (off: the room's light alone); applied when the space opens
    static let roomLightFactorKey = "roomLightFactor"     // a factor on the room estimate's light: 1, 2, 4 or 8
    static let toneMapKey = "toneMap"                     // "none" (the mixed space's default), "aces" or "agx"
    static let wideGamutKey = "wideGamut"                 // the scene shown with the display's P3 primaries, as RealityKit shows it (on unless switched off)
    /// An HDR the engine ships, for the studio lighting (and the simulator).
    static let studioEnvironment = "teatro_massimo_2k"

    /// Whether the viewer's sun is placed when the space opens (on unless switched off).
    static var sunWanted: Bool { UserDefaults.standard.object(forKey: sunKey) == nil ? true : UserDefaults.standard.bool(forKey: sunKey) }
    /// Where the geometry is shaded ("forward" unless changed: the headset's path).
    static var renderPath: String { UserDefaults.standard.string(forKey: renderPathKey) ?? "forward" }
    /// The look pass's tone map ("none" unless changed: the passthrough sets the display's response).
    static var toneMap: String { UserDefaults.standard.string(forKey: toneMapKey) ?? "none" }
    /// The factor on the room estimate's light (1 unless changed).
    static var roomLightFactor: Float { UserDefaults.standard.object(forKey: roomLightFactorKey) == nil ? 1 : Float(UserDefaults.standard.double(forKey: roomLightFactorKey)) }

    /// The sun shadow's taps per fragment, as set (8 unless changed: the engine's headset default).
    static var shadowTaps: Int { UserDefaults.standard.object(forKey: shadowTapsKey) == nil ? 8 : UserDefaults.standard.integer(forKey: shadowTapsKey) }

    static var antiAliasing: String { UserDefaults.standard.string(forKey: antiAliasingKey) ?? "msaaTaa" }
    /// Whether the space opens with foveation (on unless switched off): an experiment, since
    /// without the rate maps the compositor allocates its own, lower, resolution.
    static var foveationWanted: Bool { UserDefaults.standard.object(forKey: foveationKey) == nil ? true : UserDefaults.standard.bool(forKey: foveationKey) }
    static var msaaSamples: Int { Int(UserDefaults.standard.string(forKey: msaaSamplesKey) ?? "4") ?? 4 }
    static var lighting: String { UserDefaults.standard.string(forKey: lightingKey) ?? "room" }

    /// The compositor's render quality in [0, 1] (visionOS 26); nil leaves the
    /// platform default. Above the default is only accepted with foveation on.
    static var renderQualityValue: Float? {
        switch UserDefaults.standard.string(forKey: renderQualityKey) ?? "max" {
        case "default": return nil
        case "high": return 0.75
        default: return 1.0
        }
    }

    /// Before `UntoldEngineXR(layerRenderer:)`: the sample count is fixed when
    /// the renderer's pipelines are built.
    static func applyBeforeRendererCreation() {
        switch antiAliasing {
        case "fxaa": setRendering(.antiAliasing(.fxaa))
        case "taa": setRendering(.antiAliasing(.taa))
        case "msaa": setRendering(.antiAliasing(.msaa))
        default: setRendering(.antiAliasing(.msaaTaa))
        }
        applyMultisampleCount()
    }

    /// Live: the engine rebuilds its multisampled targets on the next frame. With two samples
    /// the tile light stage lights each pixel once; with four it falls back to the quad on
    /// GPUs whose tile memory does not hold four samples of the G-buffer.
    static func applyMultisampleCount() {
        setRendering(.multisampleCount(msaaSamples))
    }

    /// In the layer configuration, before any drawable exists.
    static func applyToLayerConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        UserDefaults.standard.set(configuration.isFoveationEnabled, forKey: foveationAvailableKey)
        if #available(visionOS 26.0, *) {
            let platformDefault = capabilities.defaultRenderQuality.rawValue
            if configuration.isFoveationEnabled, let wanted = renderQualityValue {
                configuration.maxRenderQuality = LayerRenderer.RenderQuality(rawValue: max(wanted, platformDefault))
            }
            print("Viewer: render quality platform default \(platformDefault), max \(configuration.maxRenderQuality.rawValue), foveation \(configuration.isFoveationEnabled)")
        }
    }

    /// Once the layer renderer exists: the quality actually used.
    static func applyRenderQuality(to layerRenderer: LayerRenderer) {
        if #available(visionOS 26.0, *), layerRenderer.configuration.isFoveationEnabled, let wanted = renderQualityValue {
            layerRenderer.renderQuality = LayerRenderer.RenderQuality(rawValue: wanted)
        }
    }

    /// The temporal anti-aliasing knobs, live.
    static func applyTAAParams() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: taaHistoryWeightKey) != nil {
            TAAParams.shared.historyWeight = Float(defaults.double(forKey: taaHistoryWeightKey))
        }
        if defaults.object(forKey: taaClipGammaKey) != nil {
            TAAParams.shared.clipGamma = Float(defaults.double(forKey: taaClipGammaKey))
        }
    }

    /// The three diagnostic switches, live. Off: the occlusion test skips every
    /// frame (a camera step of 0), every frame samples the pixel centre, and
    /// the textures stay at the tier they have.
    /// A diagnostic switch's state: on until the control is turned off.
    static func diagnosticOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    static func applyDiagnostics() {
        let defaults = UserDefaults.standard
        func on(_ key: String) -> Bool { diagnosticOn(key) }
        setRendering(.occlusionCullingMaxCameraStep(on(occlusionCullKey) ? 0.5 : 0))
        TAAParams.shared.jitterScale = on(taaJitterKey) ? 1 : 0
        TextureStreamingSystem.shared.enabled = on(textureStreamingKey)
        setRendering(.tileLightStage(on(tileLightStageKey) ? .enabled : .disabled))
        setRendering(.opaqueHiddenSurfaceRemoval(on(hiddenSurfaceRemovalKey) ? .enabled : .disabled))
        setRendering(.gpuPassTiming(on(gpuPassTimingKey) ? .enabled : .disabled))
        switch renderPath {
        case "deferred": setRendering(.renderPath(.deferred))
        case "hybrid": setRendering(.renderPath(.hybrid))
        default: setRendering(.renderPath(.forward))
        }
        setShadowSoftness(ShadowSoftnessSettings(filterTaps: shadowTaps, xrFilterTaps: shadowTaps))
        EngineSession.shared.xr?.setXRLightingContribution(roomLightFactor)
        switch toneMap {
        case "aces": setPostFX(.tonemapOperator(.aces))
        case "agx": setPostFX(.tonemapOperator(.agx))
        default: setPostFX(.tonemapOperator(.none))
        }
        setPostFX(.colorPrimaries(on(wideGamutKey) ? .displayP3 : .sRGB))
    }

    /// After the runtime exists and the immersion mode is set.
    static func applyAfterRendererCreation(_ xr: UntoldEngineXR) {
        // The engine's texture budget (200 MB by default) is under one 4K object's textures;
        // over it, the streaming sheds tiers under the wearer's eyes. The headset has the memory.
        MemoryBudgetManager.shared.textureBudget = 1536 * 1024 * 1024
        applyTAAParams()
        applyDiagnostics()
        setRendering(.environment(.ibl(true)))
        if lighting == "room", EnvironmentLightEstimationProvider.isSupported {
            // Lit by the real room: ARKit's environment probe becomes the
            // irradiance and specular maps every frame — what RealityKit does
            // in a mixed space.
            xr.setXRLightingMode(.realWorldEstimate)
            xr.setXRLightingContribution(roomLightFactor)
        } else {
            xr.setXRLightingMode(.staticIBL)
            setRendering(.environment(.asset(studioEnvironment)))
            setRendering(.environment(.intensity(1.0)))
        }
    }
}

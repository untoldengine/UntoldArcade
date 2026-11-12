//
//  ZombieLighting.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import UntoldEngine

/// Lighting shared by the macOS and visionOS scenes.
public enum ZombieLighting {
    /// Strength of the neutral ambient term. The engine default is 0.4
    /// against its theatre HDRI, whose irradiance is both brighter and
    /// blue; against a radiance-1.0 white the same 0.4 lands close to the
    /// previous overall brightness without the tint.
    public static let ambientIntensity: Float = 0.4

    /// Replaces the engine's default environment (a theatre HDRI whose
    /// irradiance is blue) with a uniform white one, so the ambient term is
    /// neutral: the shirt reads white, blood red, and the normal map's
    /// relief comes from the sun alone. The image is a 64x32 equirectangular
    /// Radiance file of constant radiance 1.0 in `Resources/HDR`, resolved
    /// through the asset base path set by the scene. It must be `.hdr` (or
    /// `.exr`): the engine's loader builds a half-float bitmap from the
    /// source depth, which an 8-bit PNG cannot satisfy.
    ///
    /// Call it once the renderer has built its IBL resources — on visionOS
    /// that is after scene setup, so the game applies it on its first frame.
    public static func applyNeutralEnvironment() {
        setRendering(.environment(.asset("neutral")))
        setRendering(.environment(.ibl(true)))
        setRendering(.environment(.intensity(ambientIntensity)))
    }
}

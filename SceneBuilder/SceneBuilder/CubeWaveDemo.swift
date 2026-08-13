//
//  CubeWaveDemo.swift
//  SceneBuilder
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//
//  "SwiftUI... but 3D" — a Swift3D-style intro demo.
//
//  A flat SwiftUI grid of colored squares becomes a live 3D scene: the same
//  grid, now cubes riding a wave, declared with the same declarative style
//  you'd use for any SwiftUI view. All the motion runs through the engine's
//  per-frame `onUpdate` event; SwiftUI state never touches the render loop.
//

import simd
import SwiftUI
import UntoldEngine

// MARK: - Shared scene state

/// Owns the renderer and the entity IDs so the scene survives SwiftUI
/// re-renders and 2D/3D toggles without duplicating entities.
@MainActor
final class CubeWaveScene {
    static let shared = CubeWaveScene()

    static let grid = 7
    static let spacing: Float = 1.15

    let renderer: UntoldRenderer?
    let cubeIDs: [EntityID]
    let sphereID: EntityID
    let moonIDs: [EntityID]

    private var time: Float = 0

    private init() {
        renderer = UntoldRenderer.create()

        cubeIDs = (0 ..< Self.grid * Self.grid).map { _ in createEntity() }
        sphereID = createEntity()
        moonIDs = [createEntity(), createEntity()]

        // Dark studio backdrop + image-based lighting.
        setRendering(.environment(.asset("color_121212.hdr")))
        setRendering(.environment(.ibl(true)))
        setRendering(.environment(.visible(true)))
    }

    // MARK: Layout & colors

    static func position(row: Int, col: Int) -> (x: Float, z: Float) {
        let half = Float(grid - 1) / 2.0
        return ((Float(col) - half) * spacing, (Float(row) - half) * spacing)
    }

    /// Rainbow across the grid diagonal, shared by the 2D preview and the 3D cubes.
    static func rgbColor(row: Int, col: Int) -> (Float, Float, Float) {
        let hue = Float(row + col) / Float(2 * (grid - 1))
        return hsvToRGB(hue: hue * 0.85, saturation: 0.75, value: 1.0)
    }

    static func swiftUIColor(row: Int, col: Int) -> Color {
        let (r, g, b) = rgbColor(row: row, col: col)
        return Color(red: Double(r), green: Double(g), blue: Double(b))
    }

    private static func hsvToRGB(hue: Float, saturation: Float, value: Float) -> (Float, Float, Float) {
        let h = (hue - floor(hue)) * 6.0
        let i = Int(h)
        let f = h - Float(i)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))

        switch i % 6 {
        case 0: return (value, t, p)
        case 1: return (q, value, p)
        case 2: return (p, value, t)
        case 3: return (p, q, value)
        case 4: return (t, p, value)
        default: return (value, p, q)
        }
    }

    // MARK: Per-frame animation

    func update(deltaTime: Float) {
        time += deltaTime

        // Cubes ride a radial wave out from the center.
        for row in 0 ..< Self.grid {
            for col in 0 ..< Self.grid {
                let (x, z) = Self.position(row: row, col: col)
                let distance = sqrt(x * x + z * z)
                let y = 0.8 * sin(time * 2.2 - distance * 0.9)

                let id = cubeIDs[row * Self.grid + col]
                translateTo(entityId: id, position: simd_float3(x, y, z))
                rotateTo(entityId: id, pitch: 0, yaw: y * 25.0, roll: 0)
            }
        }

        // The sphere bobs above the wave; spinning it swings its moons around.
        translateTo(entityId: sphereID, position: simd_float3(0, 3.2 + 0.3 * sin(time * 1.3), 0))
        rotateTo(entityId: sphereID, pitch: 0, yaw: time * 60.0, roll: 0)

        // Slow camera orbit around the whole scene.
        let angle = time * 0.25
        let eye = simd_float3(sin(angle) * 11.0, 5.5, cos(angle) * 11.0)
        cameraLookAt(entityId: findGameCamera(), eye: eye, target: simd_float3(0, 1.2, 0), up: simd_float3(0, 1, 0))
    }
}

// MARK: - 3D view

struct CubeWaveView: View {
    let onBack: () -> Void
    private let waveScene = CubeWaveScene.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            UntoldView(renderer: waveScene.renderer) {
                CameraNode()
                    .lookAt(eye: simd_float3(0, 5.5, 11), target: simd_float3(0, 1.2, 0))

                DirectionalLightNode()
                    .color(1.0, 0.95, 0.85)
                    .intensity(1.6)
                    .rotateTo(angle: -50, axis: [.x])

                for row in 0 ..< CubeWaveScene.grid {
                    for col in 0 ..< CubeWaveScene.grid {
                        let (x, z) = CubeWaveScene.position(row: row, col: col)
                        let (r, g, b) = CubeWaveScene.rgbColor(row: row, col: col)

                        CubeNode(size: 0.85, entityID: waveScene.cubeIDs[row * CubeWaveScene.grid + col])
                            .baseColor(r, g, b)
                            .roughness(0.35)
                            .metallic(0.1)
                            .emissive(r * 0.18, g * 0.18, b * 0.18)
                            .translateTo(x: x, z: z)
                    }
                }

                // Hierarchy showcase: the moons are children of the sphere,
                // so spinning the sphere swings them around it.
                SphereNode(radius: 0.8, entityID: waveScene.sphereID) {
                    CubeNode(size: 0.4, entityID: waveScene.moonIDs[0])
                        .baseColor(1.0, 0.35, 0.45)
                        .emissive(0.9, 0.15, 0.25)
                        .translateTo(x: 2.0)

                    CubeNode(size: 0.4, entityID: waveScene.moonIDs[1])
                        .baseColor(0.35, 0.75, 1.0)
                        .emissive(0.15, 0.55, 0.9)
                        .translateTo(x: -2.0)
                }
                .baseColor(0.95, 0.95, 1.0)
                .roughness(0.3)
                .metallic(0.2)
                .emissive(0.85, 0.8, 0.65)
                .translateTo(y: 3.2)
            }
            .onUpdate { event in
                waveScene.update(deltaTime: Float(event.deltaTime))
            }
            // MTKView has no intrinsic size — without this the hosting window
            // collapses when SwiftUI swaps the 2D intro for the 3D scene.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            VStack(spacing: 12) {
                Text("Declared in SwiftUI · Rendered by Untold Engine")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button(action: onBack) {
                    Text("Back to Flatland")
                        .font(.callout.bold())
                        .padding(.vertical, 10)
                        .padding(.horizontal, 20)
                        .background(Capsule().fill(.thinMaterial))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 24)
        }
    }
}

// MARK: - 2D intro

struct IntroView: View {
    let onEnter: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("Untold Engine")
                .font(.system(size: 42, weight: .black, design: .rounded))

            Text("SwiftUI... but what if it went ✨3D✨?")
                .font(.title3)
                .foregroundStyle(.secondary)

            // The same grid the 3D scene uses — flat, for now.
            VStack(spacing: 6) {
                ForEach(0 ..< CubeWaveScene.grid, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0 ..< CubeWaveScene.grid, id: \.self) { col in
                            RoundedRectangle(cornerRadius: 6)
                                .fill(CubeWaveScene.swiftUIColor(row: row, col: col))
                                .frame(width: 30, height: 30)
                        }
                    }
                }
            }

            Spacer()

            Button(action: onEnter) {
                Text("Enter the 3rd Dimension 🚀")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 28)
                    .background(Capsule().fill(Color.blue))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Root

struct CubeWaveDemo: View {
    // Launch with `-start3d` to skip the intro (handy for testing/recording).
    @State private var entered = ProcessInfo.processInfo.arguments.contains("-start3d")

    var body: some View {
        ZStack {
            if entered {
                CubeWaveView {
                    withAnimation(.easeInOut(duration: 0.4)) { entered = false }
                }
                .transition(.opacity)
            } else {
                IntroView {
                    withAnimation(.easeInOut(duration: 0.4)) { entered = true }
                }
                .transition(.opacity)
            }
        }
    }
}

#Preview {
    CubeWaveDemo()
}

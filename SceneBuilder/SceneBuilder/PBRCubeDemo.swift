//
//  PBRCubeDemo.swift
//  SceneBuilder
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//
//  Dynamic lighting + physically based materials, Swift3D-PBRSample style:
//  a rounded PBR cube (fish-scale tiles) lit by three colored point lights
//  orbiting on different axes, each marked by a small glowing sphere.
//  Drag to orbit the camera, with inertia.
//
//  Each light rig is a parent Node at the origin whose children (light +
//  marker) sit at a local offset — rotating the parent swings them around
//  the cube. All motion runs through the engine's per-frame onUpdate event.
//

import simd
import SwiftUI
import UntoldEngine

// MARK: - Shared scene state

@MainActor
final class PBRCubeScene {
    static let shared = PBRCubeScene()

    struct LightRig {
        let groupID: EntityID
        let lightID: EntityID
        let markerID: EntityID
        let axis: simd_float3
        let speed: Float // degrees per second
    }

    let renderer: UntoldRenderer?
    let cubeID: EntityID
    let rigs: [LightRig]

    // Camera orbit state, driven by the drag gesture.
    var yaw: Float = 20
    var pitch: Float = 15
    var yawVelocity: Float = 0
    var pitchVelocity: Float = 0
    var lastTranslation: CGSize = .zero
    var isDragging = false

    private var time: Float = 0

    private init() {
        renderer = UntoldRenderer.create()

        cubeID = createEntity()
        rigs = [
            LightRig(groupID: createEntity(), lightID: createEntity(), markerID: createEntity(),
                     axis: simd_float3(1, 0, 0), speed: 36),
            LightRig(groupID: createEntity(), lightID: createEntity(), markerID: createEntity(),
                     axis: simd_normalize(simd_float3(-1, 1, 0)), speed: 36),
            LightRig(groupID: createEntity(), lightID: createEntity(), markerID: createEntity(),
                     axis: simd_normalize(simd_float3(1, 1, 0)), speed: -36),
        ]

        // Dark studio backdrop + image-based lighting.
        setRendering(.environment(.asset("color_121212.hdr")))
        setRendering(.environment(.ibl(true)))
        setRendering(.environment(.visible(true)))

        // The renderer creates a default sun; kill it so the orbiting point
        // lights carry all the drama, and keep the ambient IBL wash low.
        setDirectionalLight(.active(nil))
        ambientIntensity = 0.1
    }

    func dragChanged(delta: CGSize) {
        isDragging = true
        let dx = Float(delta.width) * 0.35
        let dy = Float(delta.height) * 0.35
        yaw -= dx
        pitch += dy
        pitch = min(max(pitch, -80), 80)
        // Remember the last motion so release keeps a little inertia.
        yawVelocity = -dx
        pitchVelocity = dy
    }

    func dragEnded() {
        isDragging = false
        lastTranslation = .zero
    }

    func update(deltaTime: Float) {
        time += deltaTime

        // Swing each light rig around its own axis.
        for rig in rigs {
            rotateTo(entityId: rig.groupID, angle: time * rig.speed, axis: rig.axis)
        }

        // Inertia after the drag releases.
        if !isDragging {
            yaw += yawVelocity
            pitch += pitchVelocity
            pitch = min(max(pitch, -80), 80)
            yawVelocity *= 0.94
            pitchVelocity *= 0.94
        }

        let yawRad = yaw * .pi / 180
        let pitchRad = pitch * .pi / 180
        let distance: Float = 2.7
        let eye = simd_float3(
            distance * cos(pitchRad) * sin(yawRad),
            distance * sin(pitchRad),
            distance * cos(pitchRad) * cos(yawRad)
        )
        cameraLookAt(entityId: findGameCamera(), eye: eye, target: .zero, up: simd_float3(0, 1, 0))
    }
}

// MARK: - 3D view

struct PBRCubeView: View {
    private let pbrScene = PBRCubeScene.shared

    private static let rigColors: [(Float, Float, Float)] = [
        (1.0, 1.0, 1.0),   // white
        (0.2, 0.9, 0.3),   // green
        (0.7, 0.3, 0.9),   // purple
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            UntoldView(renderer: pbrScene.renderer) {
                CameraNode()
                    .lookAt(eye: simd_float3(0, 1, 2.7), target: .zero)

                // The star of the show: a rounded cube with a PBR
                // fish-scale material (base color, normal, roughness maps).
                MeshNode(resource: "BlueTile.usdz", entityID: pbrScene.cubeID)
                    .materialData(
                        roughness: 0.6,
                        metallic: 0.0,
                        baseColor: (1, 1, 1, 1),
                        baseColorResource: "Tiles_08_basecolor_1.jpg",
                        roughnessResource: "Tiles_08_roughness_1.jpg",
                        normalResource: "Tiles_08_normal_1.jpg"
                    )

                // Three point lights orbiting on different axes, each with
                // a glowing marker sphere riding along.
                for (index, rig) in pbrScene.rigs.enumerated() {
                    let (r, g, b) = Self.rigColors[index]

                    Node(entityID: rig.groupID, name: "LightRig\(index)") {
                        PointLightNode(entityID: rig.lightID)
                            .color(r, g, b)
                            .intensity(10)
                            .radius(10)
                            .attenuation(constant: 1, quadratic: 1.2)
                            .translateTo(y: 1.5)

                        SphereNode(radius: 0.06, entityID: rig.markerID)
                            .baseColor(r, g, b)
                            .emissive(r * 3, g * 3, b * 3)
                            .translateTo(y: 1.5)
                    }
                }
            }
            .onUpdate { event in
                pbrScene.update(deltaTime: Float(event.deltaTime))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            // The MTKView consumes mouse events, so the gesture lives on a
            // transparent overlay above it. Drag state lives in the scene
            // class, not @State — mutating @State here would re-run the
            // scene builder on every tick.
            .overlay(
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                pbrScene.dragChanged(delta: CGSize(
                                    width: value.translation.width - pbrScene.lastTranslation.width,
                                    height: value.translation.height - pbrScene.lastTranslation.height
                                ))
                                pbrScene.lastTranslation = value.translation
                            }
                            .onEnded { _ in
                                pbrScene.dragEnded()
                            }
                    )
            )

            VStack(spacing: 6) {
                Text("⚡️ Dynamic lighting + physically based materials ⚡️")
                    .font(.callout)
                Text("Drag to orbit · Declared in SwiftUI · Rendered by Untold Engine")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Root

struct PBRCubeDemo: View {
    var body: some View {
        PBRCubeView()
    }
}

#Preview {
    PBRCubeDemo()
}

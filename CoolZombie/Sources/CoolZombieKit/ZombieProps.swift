//
//  ZombieProps.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd
import SwiftUI
import UntoldEngine

/// Things to throw at the zombie: balls with a rigid body, simulated by the
/// physics world and read back by the engine. A few at a time; the oldest
/// goes when a new one arrives.
public final class ZombieProps: @unchecked Sendable {
    public static let ballRadius: Float = 0.12
    public static let ballMass: Float = 0.6
    public var capacity = 8
    /// The balls' collision layer: through the character controller, onto
    /// the ragdoll's parts (see `ZombiePhysics.Configuration.ballLayer`).
    public var ballLayer: UInt32 = ZombiePhysics.Configuration().ballLayer

    private var balls: [EntityID] = []
    private var counter = 0

    public init() {}

    /// Frame thread: the ball exists in the physics world from the next step.
    @discardableResult
    public func throwBall(from origin: simd_float3, velocity: simd_float3) -> EntityID {
        counter += 1
        let entity = createEntity()
        setEntityName(entityId: entity, name: "Ball \(counter)")
        setEntityMeshDirect(
            entityId: entity,
            meshes: BasicPrimitives.createSphere(extent: Self.ballRadius * 2, segments: [24, 16]),
            assetName: "zombieBall\(counter)"
        )
        updateMaterialColor(entityId: entity, color: Color(red: 0.95, green: 0.45, blue: 0.15))
        translateTo(entityId: entity, position: origin)
        registerComponent(entityId: entity, componentType: ColliderComponent.self)
        registerComponent(entityId: entity, componentType: RigidBodyComponent.self)
        if let collider = scene.get(component: ColliderComponent.self, for: entity) {
            collider.shape = .sphere(radius: Self.ballRadius)
            collider.restitution = 0.55
            collider.friction = 0.4
        }
        if let body = scene.get(component: RigidBodyComponent.self, for: entity) {
            body.motionType = .dynamic
            body.mass = Self.ballMass
            body.layer = ballLayer
            // Whatever the caller computed, a body never starts with a
            // velocity that is not a number.
            body.initialLinearVelocity = velocity.x.isFinite && velocity.y.isFinite && velocity.z.isFinite ? velocity : .zero
        }
        balls.append(entity)
        while balls.count > capacity {
            destroyEntity(entityId: balls.removeFirst())
        }
        return entity
    }

    public func isBall(_ entity: EntityID) -> Bool {
        balls.contains(entity)
    }

    public func removeAll() {
        for ball in balls { destroyEntity(entityId: ball) }
        balls.removeAll()
    }

    /// The launch velocity that carries a ball from `origin` to `target`
    /// at `speed` under gravity, on the flatter of the two arcs; aimed
    /// straight when the target is out of range.
    public static func ballisticVelocity(from origin: simd_float3, to target: simd_float3, speed: Float, gravity: Float = 9.8) -> simd_float3 {
        let delta = target - origin
        // A target on the origin has no direction: a straight-down drop,
        // never a NaN (Jolt asserts on a body created with one; headset,
        // 2026-10-27, a pinch on the window became a throw at the head).
        guard simd_length_squared(delta) > 1e-8, speed.isFinite, speed > 0 else { return simd_float3(0, -max(speed, 0), 0) }
        let flat = simd_float3(delta.x, 0, delta.z)
        let distance = simd_length(flat)
        let horizontal = distance > 1e-4 ? flat / distance : simd_float3(0, 0, 1)
        let height = delta.y
        let s2 = speed * speed
        let discriminant = s2 * s2 - gravity * (gravity * distance * distance + 2 * height * s2)
        guard distance > 1e-4, discriminant >= 0 else {
            return simd_normalize(delta) * speed
        }
        let angle = atan2(s2 - sqrt(discriminant), gravity * distance)
        return horizontal * (speed * cos(angle)) + simd_float3(0, speed * sin(angle), 0)
    }
}

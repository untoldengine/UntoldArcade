//
//  ZombieScene.swift
//  CoolZombie
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(macOS)
    import CoolZombieKit
    import Foundation
    import simd
    import SwiftUI
    import UntoldEngine

    /// The Mac sandbox: the kit's `ZombieChaseGame` — the same chase the
    /// headset runs — hunting an orbiting cube around a selectable obstacle
    /// layout. The scene owns the camera, the ground, the cube and the
    /// obstacle boxes; the zombie, its clips, its lighting and the chase
    /// logic are the kit's, so whatever is tuned here holds on the device.
    @MainActor
    final class ZombieScene {
        /// Obstacle layouts for steering and wall contact. Everything but
        /// the room's walls sits inside the cube's orbit (2 to 5 m from the
        /// origin), so the chase regularly has to go around it. `file` is a
        /// saved room (`-layoutFile`): the bundled sample, or one captured
        /// on the headset.
        enum Layout: String, CaseIterable, Identifiable {
            case open, pillars, wall, room, file

            var id: String { rawValue }

            var title: String {
                switch self {
                case .open: return "Open"
                case .pillars: return "Pillars"
                case .wall: return "Wall"
                case .room: return "Room"
                case .file: return "Room file"
                }
            }

            /// The layouts on offer: the file only once one is loaded.
            static func available(roomLoaded: Bool) -> [Layout] {
                allCases.filter { $0 != .file || roomLoaded }
            }

            func obstacles(room: [NavObstacle]) -> [NavObstacle] {
                let wall = NavObstacle(center: simd_float3(0, 0.75, 0), size: simd_float3(3.2, 1.5, 0.2))
                switch self {
                case .open:
                    return []
                case .file:
                    return room
                case .pillars:
                    return [simd_float2(1.3, 1.3), simd_float2(-1.3, 1.3), simd_float2(1.3, -1.3), simd_float2(-1.3, -1.3)].map {
                        NavObstacle(center: simd_float3($0.x, 0.3, $0.y), size: simd_float3(0.6, 0.6, 0.6))
                    }
                case .wall:
                    return [wall]
                case .room:
                    return [
                        wall,
                        NavObstacle(center: simd_float3(0, 0.75, 6.5), size: simd_float3(13.2, 1.5, 0.2)),
                        NavObstacle(center: simd_float3(0, 0.75, -6.5), size: simd_float3(13.2, 1.5, 0.2)),
                        NavObstacle(center: simd_float3(6.5, 0.75, 0), size: simd_float3(0.2, 1.5, 13.2)),
                        NavObstacle(center: simd_float3(-6.5, 0.75, 0), size: simd_float3(0.2, 1.5, 13.2)),
                    ]
                }
            }
        }

        /// Where the red cube (the stand-in player) goes.
        enum TargetMode: String, CaseIterable, Identifiable {
            case orbit, behindWall

            var id: String { rawValue }

            var title: String {
                switch self {
                case .orbit: return "Orbit"
                case .behindWall: return "Behind wall"
                }
            }
        }

        /// How high the cube sits: near the floor, or at chest height as a
        /// stand-in for a person — the arms reach for it either way.
        enum TargetHeight: String, CaseIterable, Identifiable {
            case low, person

            var id: String { rawValue }

            var title: String {
                switch self {
                case .low: return "Low"
                case .person: return "Person"
                }
            }

            var y: Float {
                switch self {
                case .low: return 0.15
                case .person: return 1.4
                }
            }
        }

        let game: ZombieChaseGame

        // MARK: Entities

        private var target: EntityID = .invalid
        private var camera: EntityID = .invalid
        private let obstacleRenderer = ZombieObstacleRenderer()
        /// The saved room behind the `file` layout, on this floor, and the
        /// orbit that fits inside its walls (the arena's orbit runs 2 to
        /// 5 m out, wider than most rooms).
        private var roomObstacles: [NavObstacle] = []
        private var roomOrbit: (center: simd_float2, radius: Float)?
        private(set) var layout: Layout = .open
        private(set) var targetMode: TargetMode = .orbit
        private(set) var targetHeight: TargetHeight = .low
        private var targetKeyWasDown = false
        private var provoked = false
        private var clipKeyWasDown = false
        private var throwKeyWasDown = false
        /// `-throwBall <seconds>`: a ball from the cube at the zombie's chest
        /// every so many seconds, for scripted runs — a toss, then a throw.
        private var throwInterval: Float = 0
        private var throwClock: Float = 0
        private var throwCount = 0
        private var layoutKeyWasDown = false
        private var targetAngle: Float = 0
        private var debugLog = false
        private var debugClock: Float = 0
    private var autoInspection: ZombieChaseGame.InspectionMode?
    private var autoInspected = false
    private var trackClock: Float = 0

        init() {
            let arguments = ProcessInfo.processInfo.arguments
            var configuration = ZombieChaseGame.Configuration()
            configuration.floorY = 0
            configuration.spawnDistance = 2.5 // facing the arena's centre, where the wall layouts put their wall
            // A saved room (`-layoutFile <name|path>`: the bundled `sample`,
            // or a room captured on the headset) is laid out around the
            // headset's spawn distance, so the zombie starts where it
            // would there.
            var room: [NavObstacle] = []
            if let index = arguments.firstIndex(of: "-layoutFile"), index + 1 < arguments.count {
                do {
                    let file = try ZombieRoom.load(arguments[index + 1])
                    room = ZombieRoom.obstacles(of: file, onFloor: configuration.floorY)
                    configuration.spawnDistance = 4
                    print("CoolZombie: room \(file.name): \(ZombieRoom.summary(of: room))")
                } catch {
                    print("CoolZombie: could not load the room \(arguments[index + 1]) — \(error)")
                }
            }
            roomObstacles = room
            let walls = room.filter { ZombieRoom.isWall($0) }
            if !walls.isEmpty {
                let bounds = ZombieNavigator.bounds(around: walls, padding: 0, minimumHalfExtent: 0)
                let half = (bounds.max - bounds.min) / 2
                roomOrbit = ((bounds.min + bounds.max) / 2, max(1.5, min(half.x, half.y) - 0.7))
            }
            game = ZombieChaseGame(configuration: configuration)
            // The physics world (the layouts' boxes, the zombie's character
            // controller) has to be installed before the first simulated
            // frame; the registry keeps the first backend for good.
            if let physics = ZombiePhysics.install() {
                game.attachPhysics(physics)
            }
            configureEngine()
            makeCamera()
            makeGround()
            makeTarget()
            game.setupScene() // sun, zombie, every available clip set, motion matching
            setSceneReady(true)
            // Test hooks, like the visionOS app's: `-layout wall` starts on a
            // layout, `-play` skips the paused start, `-debugLog` traces the
            // chase every two seconds so a scripted run can be checked
            // (`-clipSet` is read in ZombieResources).
            var initial = room.isEmpty ? Layout.open : .file
            if let index = arguments.firstIndex(of: "-layout"), index + 1 < arguments.count,
               let named = Layout(rawValue: arguments[index + 1]), availableLayouts.contains(named)
            {
                initial = named
            }
            applyLayout(initial)
            if let index = arguments.firstIndex(of: "-target"), index + 1 < arguments.count,
               let mode = TargetMode(rawValue: arguments[index + 1])
            {
                targetMode = mode
            }
            if let index = arguments.firstIndex(of: "-height"), index + 1 < arguments.count,
               let height = TargetHeight(rawValue: arguments[index + 1])
            {
                targetHeight = height
            }
            debugLog = arguments.contains("-debugLog")
            if let index = arguments.firstIndex(of: "-throwBall"), index + 1 < arguments.count,
               let interval = Float(arguments[index + 1]), interval > 0
            {
                throwInterval = interval
            }
            if arguments.contains("-play") {
                gameMode = true
            }
            if let index = arguments.firstIndex(of: "-inspect"), index + 1 < arguments.count {
                switch arguments[index + 1] {
                case "idle": autoInspection = .idling
                case "roam": autoInspection = .roaming(.walk)
                case "freeze": autoInspection = .frozen
                case "tpose", "bind": autoInspection = .bindPose
                default: break
                }
            }
        }

        // MARK: - Setup

        private func configureEngine() {
            // Starts paused; the play button (or Space) flips gameMode so a
            // screen recording can be armed on a clean still frame.
            gameMode = false
            setSceneReady(false)
            if let resources = ZombieResources.baseURL {
                setEngine(.assetBasePath(resources))
            }
            registerKeyboardEvents()
            registerMouseEvents()
            setRendering(.postProcessing(.enabled))
            setRendering(.antiAliasing(.fxaa))
            // The simulation steps with every frame, as on the headset (a
            // 60 Hz window draws one step a frame either way).
            setEngine(.simulationStepping(.perFrame))
            // The renderer (and its IBL resources) exists before the scene
            // on macOS, so the environment can be swapped right here; the
            // update callback only runs in game mode, so the paused still
            // frame would otherwise keep the default sky's blue ambient.
            ZombieLighting.applyNeutralEnvironment()
            setRendering(.environment(.visible(false)))
        }

        private func makeCamera() {
            camera = createEntity()
            setEntityName(entityId: camera, name: "Main Camera")
            createGameCamera(entityId: camera)
            cameraLookAt(
                entityId: camera,
                eye: simd_float3(0, 4.5, -7.5),
                target: simd_float3(0, 0.8, 0),
                up: simd_float3(0, 1, 0)
            )
            setCamera(.active(camera))
        }

        private func makeGround() {
            let ground = createEntity()
            setEntityName(entityId: ground, name: "Ground")
            let plane = BasicPrimitives.createPlane(width: 24, depth: 24)
            setEntityMeshDirect(entityId: ground, meshes: plane, assetName: "ground")
            updateMaterialColor(entityId: ground, color: Color(red: 0.55, green: 0.55, blue: 0.52))
        }

        private func makeTarget() {
            target = createEntity()
            setEntityName(entityId: target, name: "Target")
            let marker = BasicPrimitives.createCube(extent: 0.125)
            setEntityMeshDirect(entityId: target, meshes: marker, assetName: "target")
            updateMaterialColor(entityId: target, color: Color(red: 0.85, green: 0.15, blue: 0.1))
            translateTo(entityId: target, position: simd_float3(3.5, 0.15, 0))
        }

        // MARK: - Controls (overlay and keys)

        var clipSet: ZombieResources.ClipSet { game.clipSet }

        func setClipSet(_ set: ZombieResources.ClipSet) {
            game.setClipSet(set)
        }

        var availableLayouts: [Layout] {
            Layout.available(roomLoaded: !roomObstacles.isEmpty)
        }

        func setLayout(_ layout: Layout) {
            guard availableLayouts.contains(layout) else { return }
            applyLayout(layout)
        }

        /// Orbit: the cube circles the arena. Behind wall: it parks just past
        /// the wall layouts' wall, so the zombie arrives walled off and
        /// plants its hands on it.
        func setTargetMode(_ mode: TargetMode) {
            targetMode = mode
        }

        func setTargetHeight(_ height: TargetHeight) {
            targetHeight = height
        }

        private func cycleTargetMode() {
            let all = TargetMode.allCases
            guard let index = all.firstIndex(of: targetMode) else { return }
            targetMode = all[(index + 1) % all.count]
        }

        /// Back to the spawn point; the chase restarts on the next frame.
        /// A ball from the camera at the zombie's chest: a toss that makes
        /// it flinch (H, the button), or a throw that knocks it down (Shift+H).
        func throwBall(hard: Bool = false) {
            guard game.isReady else { return }
            let origin = getCameraPosition(entityId: camera)
            game.throwBall(from: origin, toward: game.chestPosition, speed: hard ? 9 : 4.5)
        }

        func reset() {
            game.reset()
            provoked = false
        }

        private func applyLayout(_ layout: Layout) {
            let obstacles = layout.obstacles(room: roomObstacles)
            obstacleRenderer.show(obstacles)
            self.layout = layout
            game.setObstacles(obstacles)
            // The spawn is measured from the player's stand-in: the arena's
            // centre, or the room's when a saved room is loaded (its
            // origin can sit against a wall), looking down -Z as the head
            // does at launch.
            let anchor = layout == .file ? (roomOrbit?.center ?? .zero) : .zero
            game.setSpawnAnchor(position: simd_float3(anchor.x, 0, anchor.y), forward: simd_float3(0, 0, -1))
            print("CoolZombie: layout \(layout.rawValue) (\(obstacles.count) obstacles)")
        }

        private func cycleLayout() {
            let all = availableLayouts
            guard let index = all.firstIndex(of: layout) else { return }
            applyLayout(all[(index + 1) % all.count])
        }

        private func cycleClipSet() {
            let sets = ZombieResources.availableClipSets
            guard let index = sets.firstIndex(of: clipSet), sets.count > 1 else { return }
            setClipSet(sets[(index + 1) % sets.count])
        }

        // MARK: - Input

        /// Free camera: WASD pans and dollies (W/S zoom, A/D strafe),
        /// Q/E move vertically. Right-drag orbits around the zombie;
        /// Shift+right-drag free-looks instead. J cycles the clip set,
        /// K the obstacle layout, L where the cube goes. Works while
        /// paused too, so a shot can be framed before pressing play.
        func handleInput() {
            let input = InputSystem.shared
            if input.keyState.hPressed != throwKeyWasDown {
                throwKeyWasDown = input.keyState.hPressed
                if throwKeyWasDown { throwBall(hard: input.keyState.shiftPressed) }
            }
            if input.keyState.jPressed != clipKeyWasDown {
                clipKeyWasDown = input.keyState.jPressed
                if clipKeyWasDown { cycleClipSet() }
            }
            if input.keyState.kPressed != layoutKeyWasDown {
                layoutKeyWasDown = input.keyState.kPressed
                if layoutKeyWasDown { cycleLayout() }
            }
            if input.keyState.lPressed != targetKeyWasDown {
                targetKeyWasDown = input.keyState.lPressed
                if targetKeyWasDown { cycleTargetMode() }
            }
            moveCameraWithInput(
                entityId: camera,
                input: (
                    w: input.keyState.wPressed,
                    a: input.keyState.aPressed,
                    s: input.keyState.sPressed,
                    d: input.keyState.dPressed,
                    q: input.keyState.qPressed,
                    e: input.keyState.ePressed
                ),
                speed: 3.0,
                deltaTime: 1.0 / 60.0
            )

            if input.keyState.rightMousePressed {
                if input.keyState.shiftPressed || !game.isReady {
                    rotateCamera(
                        entityId: camera,
                        pitch: input.mouseDeltaY,
                        yaw: input.mouseDeltaX,
                        sensitivity: -0.01
                    )
                } else {
                    // Re-anchor the orbit pivot to the (moving) zombie every
                    // frame: aim at it, set the pivot at that distance, then
                    // orbit by the drag delta.
                    let eye = getCameraPosition(entityId: camera)
                    let pivot = game.position + simd_float3(0, 0.9, 0)
                    cameraLookAt(entityId: camera, eye: eye, target: pivot, up: simd_float3(0, 1, 0))
                    setOrbitOffset(entityId: camera, uTargetOffset: simd_length(pivot - eye))
                    orbitCameraAround(
                        entityId: camera,
                        uDelta: simd_float2(input.mouseDeltaX, input.mouseDeltaY)
                    )
                }
            }
        }

        // MARK: - Per-frame update

        /// The cube stands in for the player: the game gets its position
        /// every frame and does the rest — waiting, chasing around the
        /// obstacles, holding at arm's length.
        func update(deltaTime: Float) {
            guard gameMode else { return }

            moveTarget(deltaTime: deltaTime)
            if let mode = autoInspection, !autoInspected, game.isReady {
                autoInspected = true
                game.setInspection(mode)
            } else if !provoked, autoInspection == nil, game.isReady {
                provoked = true
                game.provoke()
            }
            if throwInterval > 0, game.isReady {
                throwClock += deltaTime
                if throwClock >= throwInterval {
                    throwClock = 0
                    throwCount += 1
                    let origin = getPosition(entityId: target) + simd_float3(0, 1.0, 0)
                    game.throwBall(from: origin, toward: game.chestPosition, speed: throwCount % 2 == 1 ? 4 : 8)
                }
            }
            game.update(deltaTime: deltaTime, playerPosition: getPosition(entityId: target))

            // The tracking readouts ask the skeleton, which the entity lacks
            // until the mesh has loaded: polled before that, every frame logs
            // an engine error.
            if debugLog, game.isReady {
                debugClock += deltaTime
                trackClock += deltaTime
                if trackClock >= 0.5, game.phase != .downed, let error = game.trackingError {
                    trackClock = 0
                    let arm = game.trackingErrors.filter { ["spine_03", "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l"].contains($0.part) }
                        .map { String(format: "%@=%.2f", $0.part, $0.distance) }.joined(separator: " ")
                    print(String(format: "CoolZombie: track %.3f m (%@) %@", error.distance, error.part, arm))
                }
                if debugClock >= (game.phase == .contact ? 0.5 : 2) {
                    debugClock = 0
                    for d in game.trackingDetail(parts: ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head", "clavicle_l", "upperarm_l", "hand_l", "thigh_l", "calf_l", "foot_l"]) {
                        print(String(format: "CoolZombie: detail %@ target=(%.2f,%.2f,%.2f) actual=(%.2f,%.2f,%.2f) rot=%.0f deg (twist %.0f, swing %.0f)", d.part, d.target.x, d.target.y, d.target.z, d.actual.x, d.actual.y, d.actual.z, d.angle, d.twist, d.swing))
                    }
                    let p = game.position, t = getPosition(entityId: target)
                    let lying = game.downedHeights.map { String(format: " pelvisY=%.2f headY=%.2f topY=%.2f", $0.pelvis, $0.head, $0.top) }
                        ?? game.trackingError.map { String(format: " track=%.3f(%@)", $0.distance, $0.part) } ?? ""
                    print(String(format: "CoolZombie: %@%@ layout=%@ target=%@ clips=%@ physics=%@ zombie=(%.2f,%.2f) cube=(%.2f,%.2f) distance=%.2f%@",
                                 String(describing: game.phase), game.isContactPlanted ? "(planted)" : "", layout.rawValue, targetMode.rawValue, game.clipSet.rawValue,
                                 game.physics?.hasCharacter == true ? (game.isStaggering ? "jolt+stagger" : (game.isReacting ? "jolt+react" : "jolt")) : (game.phase == .downed ? "ragdoll" : "none"),
                                 p.x, p.z, t.x, t.z, game.distanceToPlayer, lying))
                }
            }
        }

        private func moveTarget(deltaTime: Float) {
            switch targetMode {
            case .orbit:
                targetAngle += deltaTime * 0.35
                var center = simd_float2(0, 0)
                var radius: Float = 3.5 + sinf(targetAngle * 0.7) * 1.5
                if layout == .file, let roomOrbit {
                    center = roomOrbit.center
                    radius = roomOrbit.radius * (0.7 + 0.3 * sinf(targetAngle * 0.7))
                }
                translateTo(entityId: target, position: simd_float3(center.x + cosf(targetAngle) * radius, targetHeight.y, center.y + sinf(targetAngle) * radius))
            case .behindWall:
                // 0.8 m past the wall's far face, opposite the spawn side.
                translateTo(entityId: target, position: simd_float3(0, targetHeight.y, 0.9))
            }
        }
    }
#endif

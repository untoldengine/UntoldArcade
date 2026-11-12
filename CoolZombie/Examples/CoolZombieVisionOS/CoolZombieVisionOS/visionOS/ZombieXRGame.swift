//
//  ZombieXRGame.swift  (visionOS)
//  CoolZombie
//
//  Thin adapter between the XR render loop and the CoolZombieKit package:
//  the package owns the scene and the chase; this file feeds it the head
//  position and the room, forwards frames, and publishes diagnostics for
//  the control window.
//

import CoolZombieKit
import Foundation
import simd
import SwiftUI
import UntoldEngine

final class ZombieXRGame: @unchecked Sendable {
    let game: ZombieChaseGame
    private let session = ZombieSpatialSession()
    private let roomRenderer = ZombieObstacleRenderer()
    private let floorRenderer = ZombieObstacleRenderer()
    private let rulerRenderer = ZombieObstacleRenderer()
    private var shownFloorKey: simd_float4?
    private var floorTrimApplied: Float = 0
    private var meshFloor: Float?
    private var floorSource = "assumed"
    private var started = false
    private var autoProvoked = false
    private var spawnAnchored = false
    private var anchoredAtReady = false
    private var standingOrigin: simd_float3?
    private var reportedDrift: Float = 0
    private var lastFloor: Float = 0
    private var roomChangedThisFrame = false
    private var lastSpatialTap: TimeInterval = 0
    /// A saved room standing in for detection (`-room <name|path|none>`).
    /// The simulator detects no surfaces, so it gets the bundled sample.
    private var fixedRoom: NavLayoutFile?
    private var roomSource: String
    private var roomVersion = -1
    private var scanVersion = -1
    private var scannedBoxes = 0
    private var roomFloor: Float = .nan
    private var roomClock: Float = 1
    private var obstacles: [NavObstacle] = []
    private var savedName = ""
    /// `-autoThrow <seconds>`: a ball from the head every so many seconds.
    private var autoThrowInterval: Float = 0
    private var autoThrowClock: Float = 0
    private var autoThrowCount = 0

    init() {
        var configuration = ZombieChaseGame.Configuration()
        // The simulator has no floor calibration — its world origin is at
        // the head — so the floor sits about a person's height below it.
        #if targetEnvironment(simulator)
            configuration.floorY = -1.0
            var roomName: String? = ZombieRoom.sampleName
        #else
            configuration.floorY = 0
            var roomName: String?
        #endif
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-room"), index + 1 < arguments.count {
            roomName = arguments[index + 1] == "none" ? nil : arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "-autoThrow"), index + 1 < arguments.count,
           let interval = Float(arguments[index + 1]), interval > 0
        {
            autoThrowInterval = interval
        }
        roomSource = "detected"
        if let roomName {
            do {
                fixedRoom = try ZombieRoom.load(roomName)
                roomSource = roomName == ZombieRoom.sampleName ? "sample" : "file"
            } catch {
                print("CoolZombie: could not load the room \(roomName) — \(error)")
                roomSource = "none"
            }
        }
        game = ZombieChaseGame(configuration: configuration)
        // The physics world: the room's boxes and the zombie's character
        // controller. Installed here, before the renderer exists, as the
        // registry asks; a reopened space finds the first one still there.
        if let physics = ZombiePhysics.install() {
            game.attachPhysics(physics)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        // Pose-timing knobs for telling the presentation from the tracking
        // when the body sways against the room while its coordinates hold:
        // `-inputWait always|never|auto` (wait for the compositor's optimal
        // input time, the lowest pose latency, at the cost of late frames;
        // the default adapts), `-framePacing full|half|halfWhenLate`.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-inputWait"), index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "always": setRendering(.optimalInputWait(.always))
            case "never": setRendering(.optimalInputWait(.never))
            default: setRendering(.optimalInputWait(.automatic))
            }
            print("CoolZombie: optimal input wait \(arguments[index + 1])")
        }
        if let index = arguments.firstIndex(of: "-framePacing"), index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "half": setRendering(.framePacing(.halfRate))
            case "halfWhenLate": setRendering(.framePacing(.halfRateWhenLate))
            default: setRendering(.framePacing(.fullRate))
            }
            print("CoolZombie: frame pacing \(arguments[index + 1])")
        }
        // The simulation lands on every frame of the 100 Hz display: under
        // the engine's fixed 60 Hz step two frames in five showed no new
        // physics pose, and the tracked parts stuttered on the mesh.
        setEngine(.simulationStepping(.perFrame))
        session.start()
        ZombieXRHolder.shared.setRoomDiagnostics(room: "nothing yet (\(roomSource))", saved: savedName)
        gameMode = true
    }

    func shutdown() {
        started = false
        gameMode = false
        roomRenderer.clear()
        floorRenderer.clear()
        rulerRenderer.clear()
        session.stop()
        // The entities go with the engine reset; the character controller
        // lives in the physics world, which outlives the space.
        game.shutdown()
    }

    /// Called by the engine once per frame on the XR render thread.
    func update(deltaTime: Float) {
        let holder = ZombieXRHolder.shared

        if holder.takeProvokeRequest() {
            game.provoke()
        }
        // The zombie appears ahead of the player's head, not of the world
        // origin (which is wherever tracking last started): anchor the
        // spawn to the head once it is tracked, and again on every reset
        // so it reappears in front of wherever the player is now.
        if let pose = session.headPose(), !spawnAnchored {
            spawnAnchored = true
            game.setSpawnAnchor(position: pose.position, forward: pose.forward)
        }
        // And again the moment it is ready to appear: the first tracked
        // pose is from seconds earlier, while the clips loaded, and the
        // player has looked elsewhere since — it should come up in front
        // of where they look now.
        if game.isReady, !anchoredAtReady, let pose = session.headPose() {
            anchoredAtReady = true
            game.setSpawnAnchor(position: pose.position, forward: pose.forward)
        }
        if holder.takeResetRequest() {
            if let pose = session.headPose() {
                game.setSpawnAnchor(position: pose.position, forward: pose.forward)
            }
            game.reset()
        }
        if let mode = holder.takeInspectionRequest() {
            game.setInspection(mode)
        }
        // A pinch anywhere in the room (not on the window, which keeps its
        // own) arrives as a spatial tap with the ray the player was looking
        // along when they pinched: the ball goes down that ray, at the
        // part of the body it crosses or past it. The window's button
        // throws along the head instead. A knockdown or a hit reaction
        // follows from what the ball does.
        let speed: Float = holder.throwsHard ? 7 : 4
        let input = getXRSpatialInputState()
        if input.spatialTapActive, input.timestamp != lastSpatialTap, simd_length_squared(input.rayDirectionWorld) > 1e-6 {
            lastSpatialTap = input.timestamp
            let direction = simd_normalize(input.rayDirectionWorld)
            let origin = input.rayOriginWorld + direction * 0.3
            let target = game.aimPoint(from: origin, along: direction)
            print(String(format: "CoolZombie: pinch -> %@ from (%.2f,%.2f,%.2f) toward (%.2f,%.2f,%.2f)", holder.throwsHard ? "throw hard" : "toss", origin.x, origin.y, origin.z, target.x, target.y, target.z))
            game.throwBall(from: origin, toward: target, speed: speed)
        }
        if holder.takeThrowRequest() != nil, let pose = session.headPose() {
            let origin = pose.position + pose.forward * 0.3
            game.throwBall(from: origin, toward: game.aimPoint(from: origin, along: pose.forward), speed: speed)
        }
        if autoThrowInterval > 0, game.isReady, let pose = session.headPose() {
            autoThrowClock += deltaTime
            if autoThrowClock >= autoThrowInterval {
                autoThrowClock = 0
                autoThrowCount += 1
                game.throwBall(from: pose.position + pose.forward * 0.3, toward: game.chestPosition, speed: autoThrowCount % 2 == 1 ? 4 : 7)
            }
        }
        if let set = holder.takeClipSetRequest() {
            game.setClipSet(set)
        }
        if let mode = holder.takeInputWaitRequest() {
            setRendering(.optimalInputWait(mode))
            print("CoolZombie: optimal input wait \(mode)")
        }
        if let pacing = holder.takeFramePacingRequest() {
            setRendering(.framePacing(pacing))
            print("CoolZombie: frame pacing \(pacing)")
        }
        if let mode = holder.takeAntiAliasingRequest() {
            setRendering(.antiAliasing(mode))
            print("CoolZombie: anti-aliasing \(mode)")
        }
        // Test hooks: `-autoProvoke` starts the chase as soon as the zombie
        // is loaded, so a simulator run shows the chase without walking;
        // `-autoRoam walk|jog|run` starts roaming, `-autoMode idle|freeze`
        // the other inspection modes.
        if !autoProvoked, game.isReady {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-autoProvoke") {
                autoProvoked = true
                game.provoke()
            } else if let index = arguments.firstIndex(of: "-autoRoam") {
                autoProvoked = true
                let speed = index + 1 < arguments.count ? ZombieChaseGame.RoamSpeed(named: arguments[index + 1]) : nil
                game.setInspection(.roaming(speed ?? .walk))
            } else if let index = arguments.firstIndex(of: "-autoMode"), index + 1 < arguments.count {
                autoProvoked = true
                switch arguments[index + 1] {
                case "idle": game.setInspection(.idling)
                case "freeze": game.setInspection(.frozen)
                case "tpose", "bind": game.setInspection(.bindPose)
                default: break
                }
            }
        }

        // On device the detected floor plane replaces the world origin's
        // estimate of the floor; the simulator detects no planes and keeps
        // the configured height.
        // The floor the zombie stands on is calibrated at run time: the
        // detected plane sits a centimetre off the real floor in either
        // direction from one room to the next (the office: 1 cm low), so
        // when the scene mesh has enough floor around the zombie its median
        // height is used instead, as long as the two agree within 5 cm. The
        // window's trim applies on top, at once, through the dead band.
        if let plane = session.floorHeight() {
            let calibrated: Float
            if let mesh = meshFloor, abs(mesh - plane) < 0.05 {
                calibrated = mesh
                floorSource = "mesh"
            } else {
                calibrated = plane
                floorSource = "plane"
            }
            let trim = holder.floorTrim
            game.setFloorHeight(calibrated + trim, immediately: trim != floorTrimApplied)
            floorTrimApplied = trim
        }

        // The room: the surfaces and the scan ARKit found (or the saved
        // room) become the obstacles, re-read twice a second — ARKit keeps
        // refining its planes and meshes for a while after they appear.
        roomClock += deltaTime
        if roomClock >= 0.5 {
            roomClock = 0
            refreshRoom()
        }
        if holder.takeRoomSaveRequest() {
            saveRoom()
        }
        if holder.showRoom {
            roomRenderer.show(obstacles, color: Color(red: 0.55, green: 0.7, blue: 0.9), opacity: 0.35)
        } else if roomRenderer.isShowing {
            roomRenderer.clear()
        }
        // The floor the zombie stands on, shown where it can be judged: a
        // 60 cm pad under it whose top is that height (the detected plane
        // plus the trim), and beside it a post of 1 cm bands, green and
        // white alternating from the floor up, so a sole can be read against
        // the bands and the pad's edge against the real floor. The whole
        // plane in green hid the floor it was meant to be compared with.
        if holder.showFloor, session.floorHeight() != nil {
            let floor = game.floorHeight
            let p = game.position
            let key = simd_float4((p.x * 20).rounded() / 20, floor, (p.z * 20).rounded() / 20, 0)
            if key != shownFloorKey {
                shownFloorKey = key
                var green = [NavObstacle(center: simd_float3(key.x, floor - 0.005, key.z), size: simd_float3(0.6, 0.01, 0.6))]
                var white: [NavObstacle] = []
                for band in 0 ..< 20 {
                    let box = NavObstacle(center: simd_float3(key.x + 0.45, floor + (Float(band) + 0.5) * 0.01, key.z),
                                          size: simd_float3(0.04, 0.01, 0.04))
                    if band % 2 == 0 { green.append(box) } else { white.append(box) }
                }
                floorRenderer.show(green, color: Color(red: 0.3, green: 0.85, blue: 0.4), opacity: 0.85)
                rulerRenderer.show(white, color: Color(red: 0.95, green: 0.95, blue: 0.95), opacity: 0.85)
            }
        } else if floorRenderer.isShowing {
            floorRenderer.clear()
            rulerRenderer.clear()
            shownFloorKey = nil
        }

        let head = session.headPosition()
        game.update(deltaTime: deltaTime, playerPosition: head)

        let phase: String = switch game.phase {
        case .waiting: game.isReady ? "waiting" : "loading"
        case .chasing: "chasing"
        case .holding: "holding"
        case .roaming: "roaming"
        case .idling: "idling"
        case .frozen: "frozen"
        case .bindPose: "T-pose"
        case .contact: "contact"
        case .downed: "downed"
        }
        holder.setDiagnostics(
            phase: phase, distance: game.distanceToPlayer, tracked: head != nil,
            floor: game.floorHeight, floorMeasured: session.floorHeight() != nil,
            clipSet: game.clipSet.rawValue, position: game.position, meshFloor: meshFloor,
            planeFloor: session.floorHeight(), floorSource: session.floorHeight() == nil ? "assumed" : floorSource
        )
        // A body that should stand still and moved anyway: measured from where
        // it stood when it stopped, so a slow drift counts as much as a step,
        // reported at every further centimetre with what changed in the frame
        // (the Xcode console). A move of 20 cm or more is a placement and
        // starts a new reference.
        let standing = [.waiting, .idling, .frozen, .bindPose, .holding].contains(game.phase)
        let position = game.position
        if standing, let origin = standingOrigin {
            let drift = simd_distance(position, origin)
            if drift >= 0.2 {
                standingOrigin = position
                reportedDrift = 0
            } else if drift >= reportedDrift + 0.01 {
                reportedDrift = floor(drift * 100) / 100
                print(String(format: "CoolZombie: standing zombie drifted %.1f cm to (%.2f, %.3f, %.2f); floor %+.3f%@%@",
                             drift * 100, position.x, position.y, position.z, game.floorHeight,
                             roomChangedThisFrame ? ", room boxes changed this frame" : "",
                             abs(game.floorHeight - lastFloor) > 0.0005 ? ", floor changed this frame" : ""))
            }
        } else {
            standingOrigin = standing ? position : nil
            reportedDrift = 0
        }
        lastFloor = game.floorHeight
        roomChangedThisFrame = false
    }

    /// Rebuilds the obstacles when the surfaces or the floor changed, and
    /// hands them to the chase only when they differ from the last set.
    private func refreshRoom() {
        meshFloor = session.meshFloorHeight(near: game.position)
        let floor = game.floorHeight
        var next: [NavObstacle]?
        if let fixedRoom {
            if floor != roomFloor {
                roomFloor = floor
                next = ZombieRoom.obstacles(of: fixedRoom, onFloor: floor)
            }
        } else {
            let (surfaces, version) = session.roomSurfaces()
            let (scan, scanned) = session.roomScan()
            if version != roomVersion || scanned != scanVersion || floor != roomFloor {
                roomVersion = version
                scanVersion = scanned
                roomFloor = floor
                let boxes = ZombieRoom.obstacles(from: surfaces, scan: scan, floor: floor)
                scannedBoxes = boxes.scan.count
                next = boxes.planes + boxes.scan
            }
        }
        guard let next, next != obstacles else { return }
        obstacles = next
        roomChangedThisFrame = true
        game.setObstacles(next)
        publishRoom()
    }

    /// Writes the room to the app's Documents folder, for the Mac
    /// sandbox's `-layoutFile`.
    private func saveRoom() {
        do {
            let url = try ZombieRoom.save(obstacles, floor: game.floorHeight)
            savedName = url.lastPathComponent
            print("CoolZombie: room saved to \(url.path)")
        } catch {
            savedName = "failed (\(error.localizedDescription))"
            print("CoolZombie: saving the room failed — \(error)")
        }
        publishRoom()
    }

    private func publishRoom() {
        ZombieXRHolder.shared.setRoomDiagnostics(
            room: "\(ZombieRoom.summary(of: obstacles, scanned: scannedBoxes)) (\(roomSource))", saved: savedName
        )
    }
}

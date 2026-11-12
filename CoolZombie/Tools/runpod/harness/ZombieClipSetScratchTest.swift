//  ZombieClipSetScratchTest.swift — scratch tuning harness, NOT for commit.
//  Replays the CoolZombie chase loop headless with a chosen clip set and logs the
//  matcher's behaviour, so clip sets and settings compare on identical target paths.
//  Holding works as in ZombieChaseGame: the matcher stays on with a zero velocity and a
//  facing goal (its pivots turn the standing zombie); HOLDOFF=1 tries the alternative.
//  Env: CLIPSET=style100|kimodo|mixed|pack  SCENARIO=approach|flip|orbit|solo  PROFILE=clusters|ramp
//       CLIP=<name> (solo: play that clip alone with root motion, matcher off)
//       MAX=<ramp top m/s>  TP TD PH HCR MPT SMG MTR TH SI (descriptor)  SECONDS=25  VERBOSE=1
//       FIK=1 FL=1 (foot IK and stance lock, as the demo runs them)  LES LXS MLD RHL (lock thresholds)
//       POP=<m/s^2> threshold for counting displayed-pose acceleration spikes ("snaps")
//       ONESHOT=none|auto|all|<comma list>: clips the database never wraps (auto = all but idles/holds)
//       JOINTS=1 prints the skeleton's joint paths
//       HW=<hand weight> (0 = no hand features)  HCS=<heading warp full-rate speed>  PEN=<one-shot runway penalty>
//       HOLDOFF=1 switches the matcher off on the waiting clip while holding (the demo keeps it on)
//       LAYER=<clip> puts that clip's arms on the pose layer at full weight for the whole run
//       REACH=1 points the arms at the target as the demo does (weight from 3 m in, full at 1.8 m); RH=<target height>
//       CC=1 stance lock from the clip's own contact (CES/CXS enter/exit authored speeds); FP=<foot position weight>
import Foundation
import simd
@testable import UntoldEngine
import XCTest

final class ZombieClipSetScratchTest: BaseRenderSetup {
    override func initializeAssets() {}
    private let res = "/Users/godshadow/Projects/Untold/UntoldArcade-zombie/CoolZombie/Sources/CoolZombieKit/Resources"

    static let style100 = ["s100_idle", "s100_walk", "s100_run", "s100_walk_back", "s100_run_back",
                           "s100_side_walk", "s100_side_run", "s100_transitions"]
    static let kimodoCore = ["k_idle", "k_hold_1", "k_hold_2", "k_shamble", "k_walk", "k_walk_fast", "k_run",
                             "k_walk_back", "k_side_walk_l", "k_side_walk_r",
                             "k_walk_turn_l_45", "k_walk_turn_r_45", "k_run_turn_l_45", "k_run_turn_r_45",
                             "k_stand_turn_l_90", "k_stand_turn_r_90", "k_stand_turn_l_180", "k_stand_turn_r_180"]
    static let kimodoExtra = ["k_run_fast", "k_run_hyper",
                              "k_walk_turn_l_90", "k_walk_turn_r_90", "k_walk_turn_l_180", "k_walk_turn_r_180",
                              "k_run_turn_l_90", "k_run_turn_r_90", "k_run_turn_l_180", "k_run_turn_r_180",
                              "k_pivot_l_90", "k_pivot_r_90", "k_pivot_l_180", "k_pivot_r_180",
                              "k_start_walk", "k_start_run", "k_stop_walk", "k_stop_run"]
    static let pack = ["idle_1", "shamble_1", "hold_1", "hold_2", "hold_3", "hold_4", "walk_3", "walk_6",
                       "chase_1", "chase_2", "chase_3", "chase_5", "hyper_1", "hyper_2", "hyper_3", "hyper_5",
                       "hyper_1_cir_l", "hyper_1_cir_r", "hyper_3_cir_l", "hyper_3_cir_r", "hyper_5_cir_l", "hyper_5_cir_r",
                       "turn_l_45", "turn_r_45", "turn_l_90", "turn_r_90", "turn_l_180", "turn_r_180",
                       "start_chase", "start_hyper"]

    func test_clipSetChase() {
        let env = ProcessInfo.processInfo.environment
        let set = env["CLIPSET"] ?? "kimodo"
        let scenario = env["SCENARIO"] ?? "approach"
        let profile = env["PROFILE"] ?? "clusters"
        func f(_ key: String, _ fallback: Float) -> Float { Float(env[key] ?? "") ?? fallback }
        let seconds = f("SECONDS", 25)
        let layerClip = env["LAYER"] ?? ""
        let verbose = env["VERBOSE"] == "1"
        let clips: [String]
        let waitingClip: String
        switch set {
        case "style100": clips = Self.style100; waitingClip = "s100_idle"
        case "pack": clips = Self.pack; waitingClip = "idle_1"
        case "mixed": clips = Self.style100 + Self.kimodoExtra; waitingClip = "s100_idle"
        default: clips = Self.kimodoCore + Self.kimodoExtra; waitingClip = "k_idle" // kimodo: the pure set
        }
        let maxSpeed = f("MAX", set == "style100" ? 1.2 : (set == "pack" ? 5.56 : 3.3)) // kimodo and mixed ramp to 3.3
        let tp = f("TP", scenario == "orbit" ? 2.5 : 5.0), td = f("TD", 1.25), ph = f("PH", 0.12)
        let hcr = f("HCR", 1.5), mpt = f("MPT", 0.3), smg = f("SMG", 0.05), mtr = f("MTR", 2.0)
        let th = f("TH", 0.1), si = f("SI", 0.1)
        let hw = f("HW", 0), hcs = f("HCS", 0.5), pen = f("PEN", 1)
        let holdOff = env["HOLDOFF"] == "1"
        let reach = env["REACH"] == "1", reachHeight = f("RH", 0.15)
        let clipContact = env["CC"] == "1", fp = f("FP", 0.75)
        let footIK = env["FIK"] != "0", footLock = env["FL"] != "0"
        let popThreshold = f("POP", 150)
        let solo = scenario == "solo"
        let oneShotMode = env["ONESHOT"] ?? "none"
        let soloClip = env["CLIP"] ?? "k_walk"
        let leftFootPath = "/root/pelvis/thigh_l/calf_l/foot_l", rightFootPath = "/root/pelvis/thigh_r/calf_r/foot_r"
        let leftHandPath = "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l/upperarm_l/lowerarm_l/hand_l"
        let rightHandPath = "/root/pelvis/spine_01/spine_02/spine_03/clavicle_r/upperarm_r/lowerarm_r/hand_r"

        let zombie = createEntity()
        let exp = XCTestExpectation(description: "loaded")
        setEntityMeshAsync(entityId: zombie, filename: "\(res)/Models/ZombieAA/ZombieAA", withExtension: "untold") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 30)
        for clip in clips + (layerClip.isEmpty || clips.contains(layerClip) ? [] : [layerClip]) {
            setEntityAnimations(entityId: zombie, filename: "\(res)/Animations/\(clip)/\(clip)", withExtension: "untold", name: clip)
        }
        setRootMotionEnabled(entityId: zombie, enabled: true)
        if footIK {
            // As ZombieChaseGame configures it: flat floor at 0, stance lock on.
            setFootIKChains(entityId: zombie, chains: [
                FootIKChainDescriptor(hipPath: "/root/pelvis/thigh_l", kneePath: "/root/pelvis/thigh_l/calf_l", anklePath: leftFootPath),
                FootIKChainDescriptor(hipPath: "/root/pelvis/thigh_r", kneePath: "/root/pelvis/thigh_r/calf_r", anklePath: rightFootPath),
            ])
            setFootIKGroundQuery(entityId: zombie) { _ in FootIKGroundSample(height: 0) }
            setFootIKEnabled(entityId: zombie, enabled: true)
            setFootIKStanceLocking(entityId: zombie, enabled: footLock, source: clipContact ? .clipContact : .displayedFoot)
        }
        let oneShot: Set<String>
        switch oneShotMode {
        case "none": oneShot = []
        case "all": oneShot = Set(clips)
        case "auto": oneShot = Set(clips.filter { !$0.contains("idle") && !$0.contains("hold") })
        default: oneShot = Set(oneShotMode.split(separator: ",").map(String.init))
        }
        setMotionMatching(entityId: zombie, descriptor: MotionMatchingDescriptor(
            leftFootPath: leftFootPath,
            rightFootPath: rightFootPath,
            leftHandPath: hw > 0 ? leftHandPath : nil,
            rightHandPath: hw > 0 ? rightHandPath : nil,
            clipNames: clips,
            searchInterval: si,
            transitionHalflife: th,
            predictionHalflife: ph,
            maxTurnRate: mtr,
            headingCorrectionRate: hcr,
            headingCorrectionSpeed: hcs,
            switchMinimumGain: smg,
            minPlayTime: mpt,
            oneShotClipNames: oneShot,
            oneShotRunwayPenalty: pen,
            weights: MotionMatchingWeights(footPosition: fp, trajectoryPosition: tp, trajectoryDirection: td, handPosition: hw)))
        let t0 = Date()
        prepareMotionMatching(entityId: zombie)
        let animEntity = resolveEntityWithAnimationComponent(entityId: zombie)!
        let ac = scene.get(component: AnimationComponent.self, for: animEntity)!
        let skeleton = scene.get(component: SkeletonComponent.self, for: animEntity)!.skeleton!
        let parents = skeleton.parentIndices
        let leftFootIndex = skeleton.jointPaths.firstIndex(of: leftFootPath)!
        let rightFootIndex = skeleton.jointPaths.firstIndex(of: rightFootPath)!
        let leftBallIndex = skeleton.jointPaths.firstIndex(of: leftFootPath + "/ball_l")!
        let rightBallIndex = skeleton.jointPaths.firstIndex(of: rightFootPath + "/ball_r")!
        if footIK {
            ac.footIK.lockEnterSpeed = f("LES", ac.footIK.lockEnterSpeed)
            ac.footIK.lockExitSpeed = f("LXS", ac.footIK.lockExitSpeed)
            ac.footIK.maxLockDistance = f("MLD", ac.footIK.maxLockDistance)
            ac.footIK.releaseHalflife = f("RHL", ac.footIK.releaseHalflife)
            ac.footIK.contactEnterSpeed = f("CES", ac.footIK.contactEnterSpeed)
            ac.footIK.contactExitSpeed = f("CXS", ac.footIK.contactExitSpeed)
        }
        if env["JOINTS"] == "1" { print("CS joints: " + skeleton.jointPaths.joined(separator: " ")) }
        if !layerClip.isEmpty {
            setPoseLayerMask(entityId: zombie, rootJointPaths: [
                "/root/pelvis/spine_01/spine_02/spine_03/clavicle_l", "/root/pelvis/spine_01/spine_02/spine_03/clavicle_r",
            ])
            setPoseLayerClip(entityId: zombie, name: layerClip, transitionHalflife: 0)
            setPoseLayerWeight(entityId: zombie, weight: 1, halflife: 0)
        }
        if reach {
            let spine = "/root/pelvis/spine_01/spine_02/spine_03"
            setReachIKChains(entityId: zombie, chains: [
                ReachIKChainDescriptor(shoulderPath: spine + "/clavicle_l/upperarm_l", elbowPath: spine + "/clavicle_l/upperarm_l/lowerarm_l", handPath: leftHandPath),
                ReachIKChainDescriptor(shoulderPath: spine + "/clavicle_r/upperarm_r", elbowPath: spine + "/clavicle_r/upperarm_r/lowerarm_r", handPath: rightHandPath),
            ])
        }
        let leftHandIndex = skeleton.jointPaths.firstIndex(of: leftHandPath)!
        let rightHandIndex = skeleton.jointPaths.firstIndex(of: rightHandPath)!
        let db = ac.motionMatching.database
        print(String(format: "CS prepare %.0f ms, %d frames; clips: %@", Date().timeIntervalSince(t0) * 1000, db?.frames.count ?? 0,
                     db?.clips.map { String(format: "%@=%.2f", $0.name, $0.speed) }.joined(separator: " ") ?? "none"))

        // Scenario state
        let approach = scenario != "orbit" && !solo
        let stopDistance: Float = approach ? 1.4 : 1.0
        let resumeDistance: Float = approach ? 2.0 : 1.6
        let floorSpeed: Float = approach ? 0.3 : 0.15
        translateTo(entityId: zombie, position: approach ? simd_float3(0, 0, -4) : simd_float3(0, 0, 0))
        rotateTo(entityId: zombie, rotation: simd_quatf(angle: 0, axis: simd_float3(0, 1, 0)))
        var hunting = !approach
        if approach {
            setMotionMatchingEnabled(entityId: zombie, enabled: false)
            changeAnimation(entityId: zombie, name: waitingClip, transitionHalflife: 0.3)
        } else if solo {
            setMotionMatchingEnabled(entityId: zombie, enabled: false)
            changeAnimation(entityId: zombie, name: soloClip, transitionHalflife: 0)
        } else {
            setMotionMatchingEnabled(entityId: zombie, enabled: true)
        }
        var moving = !approach, hyper = false
        var targetAngle: Float = 0
        var circleCenter = simd_float3.zero, circleAngle: Float = 0, circleStarted = false
        var player = simd_float3(0, 0, 0)

        // Metrics
        let dt: Float = 1 / 60
        var lastPos = getPosition(entityId: zombie), lastClip = "", lastTime: Float = -1
        var movingFrames = 0, holdFrames = 0, jumpsMoving = 0, jumpsHolding = 0, backward = 0, errOver30 = 0
        var sumErr: Float = 0, sumSpeed: Float = 0, sumGoal: Float = 0, sumSpeedErr: Float = 0
        var sumDist: Float = 0, sumHoldDist: Float = 0, firstHold: Float = -1
        var usage: [String: Int] = [:]
        var flipFrame = -1, facing = true
        var faceTimes: [Float] = []
        let frames = Int(seconds * 60)
        // Pose continuity: FK of the displayed pose (model space, root grounded) for
        // acceleration spikes, the raw incoming pose at each jump for the pop size the
        // inertializer has to hide, and world ankle tracks for foot sliding.
        var fkPos: [simd_float3] = [], fkRot: [simd_quatf] = []
        var prevPos: [simd_float3] = [], prevPrevPos: [simd_float3] = []
        var srcPos: [simd_float3] = [], srcRot: [simd_quatf] = []
        var inPos: [simd_float3] = [], inRot: [simd_quatf] = []
        var probe = ClipSampler(), probePose = PoseBuffer()
        var popSum: Float = 0, popFeetSum: Float = 0, popMax: Float = 0, popCount = 0
        var accSamples: [Float] = [], snaps = 0
        var handAccSamples: [Float] = []
        var footTrack: [[simd_float3]] = [[], []], ballTrack: [[simd_float3]] = [[], []]
        var footHunt: [Bool] = [], footMoving: [Bool] = []
        var skateSum: Float = 0, skateFrames = 0, skateMax: Float = 0
        var warpSum: Float = 0, warpMoving: Float = 0, warpSlow: Float = 0, slowFrames = 0
        var lastYaw: Float? = nil, lastEntityYaw: Float? = nil
        var rawPose = PoseBuffer(), rawSampler = ClipSampler()
        var rawFk: [simd_float3] = [], rawRot: [simd_quatf] = [], prevRawFeet: [simd_float3] = []
        var prevRawValid = false
        var plantDrift: Float = 0, plantFrames = 0, plantFramesMoving = 0, plantDriftMoving: Float = 0
        var previousFeetWorld: [simd_float3] = []
        // Solo: how far the clip's last frame sits from its first (the loop seam is a hard
        // cut, never inertialized).
        var seam: Float = -1, seamFeet: Float = -1
        if solo, let clipObj = ac.animationClips[soloClip] {
            let compiled = ac.compiledClip(for: clipObj, skeleton: skeleton)
            var first = PoseBuffer(), last = PoseBuffer()
            probe.sample(compiled, time: 0, duration: clipObj.duration, speed: clipObj.speed, into: &first)
            probe.sample(compiled, time: max(0, clipObj.duration - dt), duration: clipObj.duration, speed: clipObj.speed, into: &last)
            if let root = compiled.rootJointIndex {
                stripRootMotion(from: &first, rootIndex: root); stripRootMotion(from: &last, rootIndex: root)
            }
            computeForwardKinematics(pose: first, parentIndices: parents, positions: &inPos, rotations: &inRot)
            computeForwardKinematics(pose: last, parentIndices: parents, positions: &srcPos, rotations: &srcRot)
            seam = 0
            for j in 0 ..< inPos.count { seam = max(seam, simd_length(inPos[j] - srcPos[j])) }
            seamFeet = max(simd_length(inPos[leftFootIndex] - srcPos[leftFootIndex]), simd_length(inPos[rightFootIndex] - srcPos[rightFootIndex]))
        }

        for frame in 0 ..< frames {
            let t = Float(frame) / 60
            let zPos = getPosition(entityId: zombie)
            // Target: the player (approach) or the Mac scene's orbiting cube.
            if solo {
                let fwdNow = getForwardAxisVector(entityId: zombie)
                player = zPos + simd_normalize(simd_float3(fwdNow.x, 0, fwdNow.z)) * 10
            } else if scenario == "flip" {
                // Sharp heading changes: the player jumps behind, then to the left,
                // then to the right of the zombie, 3 m away each time.
                if frame == 8 * 60 || frame == 14 * 60 || frame == 20 * 60 {
                    let fwd0 = getForwardAxisVector(entityId: zombie)
                    let fh0 = simd_normalize(simd_float3(fwd0.x, 0, fwd0.z))
                    let left = simd_float3(fh0.z, 0, -fh0.x)
                    let offset = frame == 8 * 60 ? -fh0 * 3 : (frame == 14 * 60 ? left * 3 : -left * 3)
                    player = simd_float3(zPos.x, 0, zPos.z) + offset
                    flipFrame = frame; facing = false
                }
            } else if approach {
                if t >= 8, t < 18 {
                    if !circleStarted {
                        circleStarted = true
                        circleCenter = simd_float3(zPos.x, 0, zPos.z)
                        circleAngle = atan2(player.z - circleCenter.z, player.x - circleCenter.x)
                    }
                    circleAngle += dt * (1.0 / 2.8) // 1 m/s along a 2.8 m circle around where the zombie held
                    player = circleCenter + 2.8 * simd_float3(cos(circleAngle), 0, sin(circleAngle))
                }
            } else {
                targetAngle += dt * 0.35
                let radius: Float = 3.5 + sinf(targetAngle * 0.7) * 1.5
                player = simd_float3(cosf(targetAngle) * radius, 0.15, sinf(targetAngle) * radius)
            }
            var toPlayer = player - zPos; toPlayer.y = 0
            let distance = simd_length(toPlayer)
            let direction = distance > 1e-4 ? toPlayer / distance : simd_float3(0, 0, 1)

            if approach, !hunting, t >= 1 {
                hunting = true; moving = true
                setMotionMatchingEnabled(entityId: zombie, enabled: true)
            }
            var goal = simd_float3.zero
            if hunting, !solo {
                if moving, distance < stopDistance {
                    moving = false
                    if holdOff {
                        setMotionMatchingEnabled(entityId: zombie, enabled: false)
                        changeAnimation(entityId: zombie, name: waitingClip, transitionHalflife: 0.3)
                    }
                } else if !moving, distance > resumeDistance {
                    moving = true
                    if holdOff { setMotionMatchingEnabled(entityId: zombie, enabled: true) }
                }
                if distance > 4.5 { hyper = true } else if distance < 3.0 { hyper = false }
                if moving {
                    let ramp = distance - stopDistance
                    let speed: Float = profile == "ramp"
                        ? min(maxSpeed, max(floorSpeed, ramp))
                        : (hyper ? min(5.56, max(2.73, ramp)) : min(0.91, max(floorSpeed, ramp)))
                    goal = direction * speed
                }
            }
            setMotionMatchingGoal(entityId: zombie, desiredVelocity: goal, desiredFacing: hunting ? direction : nil)
            if reach {
                let weight = hunting ? min(1, max(0, (3.0 - distance) / 1.2)) : 0
                setReachIKTarget(entityId: zombie, worldPosition: weight > 0 ? simd_float3(player.x, reachHeight, player.z) : nil,
                                 weight: weight, halflife: 0.3)
            }
            AnimationSystem.shared.update(dt)

            let p = getPosition(entityId: zombie)
            let v = (p - lastPos) / dt
            let vh = simd_float3(v.x, 0, v.z)
            let fwd = getForwardAxisVector(entityId: zombie)
            let fh = simd_normalize(simd_float3(fwd.x, 0, fwd.z))
            let fwdSpeed = simd_dot(vh, fh)
            let err = atan2f(fh.x * direction.z - fh.z * direction.x, fh.x * direction.x + fh.z * direction.z) * 180 / .pi
            let clip = ac.currentAnimation?.name ?? "nil"
            // Rigid turning: the entity's yaw step minus the clip's own root yaw step.
            let entityYaw = atan2f(fh.x, fh.z)
            var clipYaw: Float? = nil
            var authoredFeet: [Float?] = [nil, nil]
            if let current = ac.currentAnimation {
                let compiled = ac.compiledClip(for: current, skeleton: skeleton)
                rawSampler.sample(compiled, time: ac.currentTime, duration: current.duration, speed: current.speed, into: &rawPose)
                if let root = compiled.rootJointIndex { clipYaw = yawTwist(rawPose.rotations[root]).yaw }
                computeForwardKinematics(pose: rawPose, parentIndices: parents, positions: &rawFk, rotations: &rawRot)
                let feetNow = [rawFk[leftFootIndex], rawFk[rightFootIndex]]
                let wrappedNow = fmod(ac.currentTime, max(current.duration, 1e-4)), wrappedLast = fmod(lastTime, max(current.duration, 1e-4))
                if prevRawValid, clip == lastClip, wrappedNow >= wrappedLast {
                    for foot in 0 ..< 2 { authoredFeet[foot] = simd_length(feetNow[foot] - prevRawFeet[foot]) / dt }
                }
                prevRawFeet = feetNow; prevRawValid = true
            } else { prevRawValid = false }
            if hunting, let lastEntityYaw, let lastYaw, let clipYaw, clip == lastClip, ac.currentTime >= lastTime {
                let rigid = abs(wrapAngle(wrapAngle(entityYaw - lastEntityYaw) - wrapAngle(clipYaw - lastYaw)))
                warpSum += rigid
                if moving { warpMoving += rigid }
                if simd_length(vh) < 0.6 { warpSlow += rigid; slowFrames += 1 }
            }
            lastEntityYaw = entityYaw; lastYaw = clipYaw
            // A matcher jump zeroes timeSinceJump (same-clip forward jumps included; the
            // counter only runs while matching, so it is read only then); a changeAnimation
            // switch shows as a clip name change.
            let jumped = clip != lastClip || ac.currentTime < lastTime
                || (ac.motionMatching.isEnabled && ac.motionMatching.timeSinceJump == 0)
            if flipFrame >= 0, !facing, abs(err) < 15 {
                facing = true
                faceTimes.append(t - Float(flipFrame) / 60)
            }
            if hunting {
                usage[clip, default: 0] += 1
                if moving {
                    movingFrames += 1; sumErr += abs(err); sumSpeed += simd_length(vh); sumGoal += simd_length(goal)
                    sumSpeedErr += abs(simd_length(vh) - simd_length(goal))
                    if abs(err) > 30 { errOver30 += 1 }
                    if fwdSpeed < -0.05 { backward += 1 }
                    if jumped { jumpsMoving += 1 }
                } else {
                    holdFrames += 1; sumHoldDist += distance
                    if firstHold < 0 { firstHold = t }
                    if jumped { jumpsHolding += 1 }
                }
                sumDist += distance
            }

            // Displayed pose continuity (model space, root grounded).
            computeForwardKinematics(pose: ac.localPose, parentIndices: parents, positions: &fkPos, rotations: &fkRot)
            if fkPos.contains(where: { $0.x.isNaN || $0.y.isNaN || $0.z.isNaN }) {
                let bad = fkPos.indices.filter { fkPos[$0].x.isNaN }.map { skeleton.jointPaths[$0].split(separator: "/").last.map(String.init) ?? "?" }
                print(String(format: "CS NaN at t=%.2f clip=%@ joints=%@", t, clip, bad.prefix(6).joined(separator: ",")))
                XCTFail("NaN pose"); return
            }
            var accMax: Float = 0, accJoint = 0
            if prevPrevPos.count == fkPos.count {
                for j in 0 ..< fkPos.count {
                    let a = simd_length(fkPos[j] - 2 * prevPos[j] + prevPrevPos[j]) / (dt * dt)
                    if a > accMax { accMax = a; accJoint = j }
                }
                if hunting {
                    accSamples.append(accMax); if accMax > popThreshold { snaps += 1 }
                    let handAcc = max(simd_length(fkPos[leftHandIndex] - 2 * prevPos[leftHandIndex] + prevPrevPos[leftHandIndex]),
                                      simd_length(fkPos[rightHandIndex] - 2 * prevPos[rightHandIndex] + prevPrevPos[rightHandIndex])) / (dt * dt)
                    handAccSamples.append(handAcc)
                }
            }
            var pop: Float = -1
            if jumped, hunting, ac.hasPreviousPose, let current = ac.currentAnimation {
                let compiled = ac.compiledClip(for: current, skeleton: skeleton)
                probe.sample(compiled, time: max(0, ac.currentTime - dt), duration: current.duration, speed: current.speed, into: &probePose)
                if let root = compiled.rootJointIndex { stripRootMotion(from: &probePose, rootIndex: root) }
                computeForwardKinematics(pose: probePose, parentIndices: parents, positions: &inPos, rotations: &inRot)
                computeForwardKinematics(pose: ac.previousPose, parentIndices: parents, positions: &srcPos, rotations: &srcRot)
                if inPos.count == srcPos.count {
                    pop = 0
                    for j in 0 ..< inPos.count { pop = max(pop, simd_length(inPos[j] - srcPos[j])) }
                    popSum += pop; popMax = max(popMax, pop); popCount += 1
                    popFeetSum += max(simd_length(inPos[leftFootIndex] - srcPos[leftFootIndex]),
                                      simd_length(inPos[rightFootIndex] - srcPos[rightFootIndex]))
                }
            }
            let world = scene.get(component: WorldTransformComponent.self, for: animEntity)?.space ?? .identity
            func toWorld(_ p: simd_float3) -> simd_float3 { let w = world * simd_float4(p, 1); return simd_float3(w.x, w.y, w.z) }
            footTrack[0].append(toWorld(fkPos[leftFootIndex])); footTrack[1].append(toWorld(fkPos[rightFootIndex]))
            let feetWorld = [toWorld(fkPos[leftFootIndex]), toWorld(fkPos[rightFootIndex])]
            if hunting, previousFeetWorld.count == 2 {
                for foot in 0 ..< 2 {
                    if let authored = authoredFeet[foot], authored < 0.15 {
                        let d = feetWorld[foot] - previousFeetWorld[foot]
                        let drift = simd_length(simd_float3(d.x, 0, d.z))
                        plantDrift += drift; plantFrames += 1
                        if moving { plantDriftMoving += drift; plantFramesMoving += 1 }
                    }
                }
            }
            if hunting, previousFeetWorld.count == 2, let current = ac.currentAnimation, let db,
               let index = db.frameIndex(ofClip: current, time: fmod(ac.currentTime, max(current.duration, 1e-4))) {
                let raw = db.rawFeatures(at: index)
                var rotation = getRotationQuaternion(entityId: zombie)
                if simd_length_squared(rotation.vector) < 1e-8 { rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
                for foot in 0 ..< 2 {
                    let authored = rotation.act(simd_float3(raw[6 + foot * 3], raw[7 + foot * 3], raw[8 + foot * 3]))
                    let displayed = (feetWorld[foot] - previousFeetWorld[foot]) / dt
                    let d = displayed - authored
                    let skate = simd_length(simd_float3(d.x, 0, d.z))
                    skateSum += skate; skateFrames += 1; skateMax = max(skateMax, skate)
                }
            }
            previousFeetWorld = feetWorld
            ballTrack[0].append(toWorld(fkPos[leftBallIndex])); ballTrack[1].append(toWorld(fkPos[rightBallIndex]))
            footHunt.append(hunting); footMoving.append(hunting && moving)
            prevPrevPos = prevPos; prevPos = fkPos

            if verbose ? (frame % 15 == 0 || jumped || accMax > popThreshold) : (frame % 30 == 0) {
                let accName = skeleton.jointPaths[accJoint].split(separator: "/").last.map(String.init) ?? "?"
                print(String(format: "CS t=%5.2f d=%.2f goal=%.2f v=%.2f err=%+6.1f %@ %-18@ t=%.2f acc=%4.0f(%@)%@%@",
                             t, distance, simd_length(goal), simd_length(vh), err,
                             hunting ? (moving ? "MOVE" : "HOLD") : "wait", clip, ac.currentTime, accMax, accName,
                             jumped && hunting ? " JUMP" : "", pop >= 0 ? String(format: " pop=%.1fcm", pop * 100) : ""))
            }
            lastPos = p; lastClip = clip; lastTime = ac.currentTime
        }
        let huntFrames = max(1, movingFrames + holdFrames)
        let top = usage.sorted { $0.value > $1.value }.prefix(8).map { String(format: "%@=%.1fs", $0.key, Float($0.value) / 60) }.joined(separator: " ")
        let face = faceTimes.map { String(format: "%.1f", $0) }.joined(separator: ",")

        // Foot sliding: while the ankle or the ball is at its planted height (own 10th
        // percentile + 2.5 cm), the smaller horizontal displacement of the two counts as
        // slide (a rolling foot keeps one of them still); per second of hunting, and
        // moving-only alongside.
        var slideAll: Float = 0, slideMoving: Float = 0, contactFrames = 0
        for foot in 0 ..< 2 {
            let ankleHeights = footTrack[foot].map { $0.y }.sorted()
            let ballHeights = ballTrack[foot].map { $0.y }.sorted()
            let ankleLimit = ankleHeights[Int(Float(ankleHeights.count) * 0.1)] + 0.025
            let ballLimit = ballHeights[Int(Float(ballHeights.count) * 0.1)] + 0.025
            var previousContact = false
            for i in 1 ..< footTrack[foot].count {
                let contact = footTrack[foot][i].y < ankleLimit || ballTrack[foot][i].y < ballLimit
                if contact, previousContact, footHunt[i] {
                    let da = footTrack[foot][i] - footTrack[foot][i - 1]
                    let db = ballTrack[foot][i] - ballTrack[foot][i - 1]
                    let horizontal = min(simd_length(simd_float3(da.x, 0, da.z)), simd_length(simd_float3(db.x, 0, db.z)))
                    slideAll += horizontal; contactFrames += 1
                    if footMoving[i] { slideMoving += horizontal }
                }
                previousContact = contact
            }
        }
        accSamples.sort()
        handAccSamples.sort()
        let handP95 = handAccSamples.isEmpty ? 0 : handAccSamples[Int(Float(handAccSamples.count) * 0.95)]
        let handMean = handAccSamples.isEmpty ? 0 : handAccSamples.reduce(0, +) / Float(handAccSamples.count)
        let accP95 = accSamples.isEmpty ? 0 : accSamples[Int(Float(accSamples.count) * 0.95)]
        let accMaxAll = accSamples.last ?? 0
        let huntSeconds = Float(huntFrames) / 60, movingSeconds = max(1, Float(movingFrames)) / 60
        print(String(format: "CS SUMMARY set=%@ scen=%@ prof=%@ max=%.1f TP=%.1f TD=%.2f PH=%.2f HCR=%.1f MPT=%.2f SMG=%.2f MTR=%.1f TH=%.2f SI=%.2f FIK=%d FL=%d LES=%.2f LXS=%.2f MLD=%.2f RHL=%.2f OS=%@ HW=%.2f HCS=%.1f PEN=%.1f HOLDOFF=%d LAYER=%@ CC=%d CES=%.2f CXS=%.2f FP=%.2f | jumps move=%d (%.2f/s) hold=%d (%.2f/s) | err mean=%.1f >30=%d%% back=%d face=[%@] | speed v=%.2f goal=%.2f |dv|=%.2f | dist mean=%.2f hold=%.2f firstHold=%.1fs | pop n=%d mean=%.1fcm feet=%.1fcm max=%.1fcm | acc p95=%.0f max=%.0f snaps=%d hands mean=%.0f p95=%.0f | slide=%.1fcm/s moving=%.1fcm/s contact=%d%% skate=%.1fcm/s max=%.0f | warp=%.0fdeg/s moving=%.0fdeg/s slow=%.0fdeg/s | plant=%.1fcm/s moving=%.1fcm/s frames=%d%%%@ | %@",
                     solo ? "\(set)/\(soloClip)" : set, scenario, profile, maxSpeed, tp, td, ph, hcr, mpt, smg, mtr, th, si, footIK ? 1 : 0, footLock ? 1 : 0,
                     ac.footIK.lockEnterSpeed, ac.footIK.lockExitSpeed, ac.footIK.maxLockDistance, ac.footIK.releaseHalflife, oneShotMode,
                     hw, hcs, pen, holdOff ? 1 : 0, layerClip.isEmpty ? "none" : layerClip,
                     clipContact ? 1 : 0, ac.footIK.contactEnterSpeed, ac.footIK.contactExitSpeed, fp,
                     jumpsMoving, Float(jumpsMoving) / max(1, Float(movingFrames) / 60), jumpsHolding, Float(jumpsHolding) / max(1, Float(holdFrames) / 60),
                     sumErr / max(1, Float(movingFrames)), Int(100 * Float(errOver30) / max(1, Float(movingFrames))), backward, face,
                     sumSpeed / max(1, Float(movingFrames)), sumGoal / max(1, Float(movingFrames)), sumSpeedErr / max(1, Float(movingFrames)),
                     sumDist / Float(huntFrames), holdFrames > 0 ? sumHoldDist / Float(holdFrames) : -1, firstHold,
                     popCount, popCount > 0 ? popSum / Float(popCount) * 100 : 0, popCount > 0 ? popFeetSum / Float(popCount) * 100 : 0, popMax * 100,
                     accP95, accMaxAll, snaps, handMean, handP95,
                     slideAll * 100 / huntSeconds, slideMoving * 100 / movingSeconds, Int(100 * Float(contactFrames) / Float(2 * huntFrames)),
                     skateFrames > 0 ? skateSum / Float(skateFrames) * 100 : 0, skateMax * 100,
                     warpSum * 180 / .pi / huntSeconds, warpMoving * 180 / .pi / movingSeconds,
                     slowFrames > 0 ? warpSlow * 180 / .pi / (Float(slowFrames) / 60) : 0,
                     plantFrames > 0 ? plantDrift * 100 / (Float(plantFrames) / 60) : 0,
                     plantFramesMoving > 0 ? plantDriftMoving * 100 / (Float(plantFramesMoving) / 60) : 0,
                     Int(100 * Float(plantFrames) / Float(2 * huntFrames)),
                     seam >= 0 ? String(format: " | seam=%.1fcm feet=%.1fcm", seam * 100, seamFeet * 100) : "",
                     top))
    }
}

//
//  ZombieResources.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum ZombieResources {
    /// Root of the kit's bundled assets (`Models/`, `Animations/`), for
    /// `setEngine(.assetBasePath(_:))`. The model and clips are marketplace
    /// assets that ship only inside compiled apps — see the README.
    public static var baseURL: URL? {
        Bundle.module.resourceURL
    }

    /// Which motion data drives the demo. `style100` is the Zombie style of
    /// the 100STYLE dataset (CC BY 4.0) retargeted onto the rig — the
    /// default, and the clips ship in the repository. `kimodo` is a full
    /// set generated with NVIDIA Kimodo in one zombie style (idle and hold
    /// idles, a shamble-to-sprint ladder, backward and side walks, turns,
    /// pivots, starts and stops; NVIDIA Open Model License). `mixed` is the
    /// 100STYLE set plus the Kimodo gap clips, the first combination tried.
    /// `pack` is MoCap Online's Zombie Pro (binary-only license, not in the
    /// repository; faster sprints and pivots). Pick with the launch
    /// argument `-clipSet <name>`, or switch at runtime.
    public enum ClipSet: String, Sendable, CaseIterable, Identifiable {
        case pack
        case style100
        case kimodo
        case mixed

        public var id: String { rawValue }

        /// Label for a control.
        public var title: String {
            switch self {
            case .pack: return "Pack"
            case .style100: return "100STYLE"
            case .kimodo: return "Kimodo"
            case .mixed: return "Mixed"
            }
        }
    }

    /// How the chase turns distance into a goal speed for a clip set. A
    /// continuous profile ramps from the floor to `maxSpeed` with distance;
    /// a clustered one keeps the pack's two gaits — walks up to
    /// `walkTopSpeed`, hyper chases from `chaseFloorSpeed` — because that
    /// data has nothing in between and a goal in the hole only churns.
    /// Measured with the headless chase harness (2026-09-08): the ramp
    /// reaches the player sooner and tracks a moving target closer for
    /// both continuous sets, and is neutral where the data tops out.
    public struct SpeedProfile: Sendable {
        public var maxSpeed: Float
        public var walkTopSpeed: Float?
        public var chaseFloorSpeed: Float?
        /// Orientation warp: how fast (rad/s) the entity may be turned
        /// under the clips toward the goal, and the travel speed at which
        /// that reaches its full rate. A set with arcs and pivots turns
        /// through them and gets a low rate, so the feet do the turning
        /// (the warp reads as the mesh rotating under still feet); a set
        /// without turn clips cannot turn any other way.
        public var warpRate: Float = 1.5
        public var warpSpeed: Float = 0.5
        /// Foot-position weight in the matching features: higher lands a
        /// jump where the feet already are (fewer, smaller foot pops for
        /// the stance lock to absorb), but past a point a standing goal
        /// treadmills on a still frame whose feet match. 2 suits the
        /// Kimodo set; the 100STYLE takes churn while holding above 0.75.
        public var footWeight: Float = 0.75

        public var isClustered: Bool { walkTopSpeed != nil && chaseFloorSpeed != nil }

        /// Goal speed for a distance-driven ramp (metres past the stop line
        /// per second), never below `floor`.
        public func speed(ramp: Float, floor: Float, hyper: Bool) -> Float {
            if let walkTop = walkTopSpeed, let chaseFloor = chaseFloorSpeed {
                return hyper ? min(maxSpeed, max(chaseFloor, ramp)) : min(walkTop, max(floor, ramp))
            }
            return min(maxSpeed, max(floor, ramp))
        }
    }

    public static func speedProfile(for set: ClipSet) -> SpeedProfile {
        switch set {
        // Authored speeds: walk/chase 0.4-0.91, hyper 2.73-5.56.
        case .pack: return SpeedProfile(maxSpeed: 5.56, walkTopSpeed: 0.91, chaseFloorSpeed: 2.73)
        // 100STYLE Zombie: walk ~0.4, run ~1.2 m/s; no turn clips, so the
        // warp is all the turning it has.
        case .style100: return SpeedProfile(maxSpeed: 1.2)
        // Kimodo runs at 2.5 and 3.5 m/s. The pure set turns through its
        // 45°/90°/180° arcs and standing pivots: the warp only trims the
        // residual (headless harness 2026-09-09: rigid turning in the
        // orbit 22 -> 15 deg/s, heading error 2 -> 8 deg). The mix has
        // the 90°/180° turns but no gentle arcs.
        case .kimodo: return SpeedProfile(maxSpeed: 3.3, warpRate: 0.3, warpSpeed: 1.0, footWeight: 2.0)
        case .mixed: return SpeedProfile(maxSpeed: 3.3, warpRate: 0.6, warpSpeed: 1.0)
        }
    }

    /// The set the demo starts with: the launch argument when it names an
    /// available set, else the 100STYLE clips. Hosts may switch at runtime
    /// through `ZombieChaseGame.setClipSet`.
    public static var clipSet: ClipSet {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-clipSet"), index + 1 < arguments.count,
           let set = ClipSet(rawValue: arguments[index + 1]), availableClipSets.contains(set)
        {
            return set
        }
        return .style100
    }

    /// Sets whose every clip is in the bundle. The pack never ships in the
    /// repository, so a fresh clone offers the other two.
    public static var availableClipSets: [ClipSet] {
        ClipSet.allCases.filter { set in clips(for: set).allSatisfy(clipExists) }
    }

    /// Every clip of every available set, each once, in set order, plus the
    /// scripted clips when present — what a host loads up front so the set
    /// can change at runtime without file IO.
    /// Arm-posture takes for the pose layer (`clips_arms.json`): reaching
    /// and grasping, and arms raised high grabbing at the air. Not in any
    /// database; loaded when present so `armClips` can pick them.
    public static let armPostureClips = ["k_arms_grab", "k_arms_high"]

    public static var allAvailableClips: [String] {
        var seen = Set<String>()
        let sets = availableClipSets.flatMap { clips(for: $0) }
        let extras = ([contactClip] + armPostureClips).filter(clipExists)
        return (sets + extras).filter { seen.insert($0).inserted }
    }

    /// Hands planted on a wall, in place (the hold segment of the Kimodo
    /// hands-on-wall take, static root). Played by the chase's contact
    /// behaviour, never by the matcher.
    public static let contactClip = "k_wall_hold"

    public static var contactClipAvailable: Bool { clipExists(contactClip) }

    private static func clipExists(_ clip: String) -> Bool {
        guard let base = baseURL else { return false }
        return FileManager.default.fileExists(atPath: base.appendingPathComponent("Animations/\(clip)/\(clip).untold").path)
    }

    /// The calm idle played directly while the zombie waits to be provoked
    /// — the stillest idle (no root travel, a slow sway). Motion matching
    /// would pick the aggressive attack idles for a zero goal.
    public static var waitingClip: String { waitingClip(for: clipSet) }

    public static func waitingClip(for set: ClipSet) -> String {
        switch set {
        case .pack: return "idle_1"
        case .style100, .mixed: return "s100_idle"
        case .kimodo: return "k_idle"
        }
    }

    /// 100STYLE Zombie (Mason, Starke, Komura 2022; CC BY 4.0), one long
    /// capture per locomotion type: idle, forward/backward/sideways walks
    /// and runs, and a transitions take. Cooked from the BVH with
    /// `retarget_100style.py` (world-space delta retarget, smoothed root
    /// path and heading).
    public static let style100Clips: [String] = [
        "s100_idle", "s100_walk", "s100_run",
        "s100_walk_back", "s100_run_back",
        "s100_side_walk", "s100_side_run",
        "s100_transitions",
    ]

    /// The gap clips generated with NVIDIA Kimodo (`nvidia/Kimodo-SOMA-RP-v1.1`,
    /// weights under the NVIDIA Open Model License) from text prompts and
    /// root-path constraints — see `Tools/runpod/README.md` (`clips.json`).
    /// Generated by `Tools/runpod/gen_clips.py`, retargeted with
    /// `Tools/retarget_kimodo.py`: chase runs at 2.5 and 3.5 m/s, 90°/180°
    /// turns at walking and running pace, walking pivots, and start/stop
    /// transitions. The hands-on-a-wall take (`k_wall_hands`) is cooked too
    /// but kept out of every database: its hold segment is the contact clip.
    public static let kimodoGapClips: [String] = [
        "k_run_fast", "k_run_hyper",
        "k_walk_turn_l_90", "k_walk_turn_r_90", "k_walk_turn_l_180", "k_walk_turn_r_180",
        "k_run_turn_l_90", "k_run_turn_r_90", "k_run_turn_l_180", "k_run_turn_r_180",
        "k_pivot_l_90", "k_pivot_r_90", "k_pivot_l_180", "k_pivot_r_180",
        "k_start_walk", "k_start_run", "k_stop_walk", "k_stop_run",
    ]

    /// The locomotion core in the same style (`clips_core.json`): a long
    /// idle and two aggressive hold idles (all in place), a shamble-to-jog
    /// ladder, backward and side walks, 45° arcs and standing pivots.
    public static let kimodoCoreClips: [String] = [
        "k_idle", "k_hold_1", "k_hold_2",
        "k_shamble", "k_walk", "k_walk_fast", "k_run",
        "k_walk_back", "k_side_walk_l", "k_side_walk_r",
        "k_walk_turn_l_45", "k_walk_turn_r_45", "k_run_turn_l_45", "k_run_turn_r_45",
        "k_stand_turn_l_90", "k_stand_turn_r_90", "k_stand_turn_l_180", "k_stand_turn_r_180",
    ]

    /// Everything Kimodo, one style throughout.
    public static let kimodoClips: [String] = kimodoCoreClips + kimodoGapClips

    /// The 100STYLE captures with the Kimodo gap clips filling what they lack.
    public static let mixedClips: [String] = style100Clips + kimodoGapClips

    /// Clip names the chase database is built from: standing idles, a
    /// walk/chase ladder (0.4-0.91 m/s), a hyper-chase ladder (2.73-5.56
    /// m/s), circular sprints, in-place turns and acceleration starts — all
    /// with the pack's authored root motion.
    ///
    /// Standing clips must be truly in place. `idle_3` is not: it has a
    /// shuffle step, and a zero-motion goal refuses to play through it —
    /// the search snaps back to the stillest frame every 0.3 s and the idle
    /// visibly restarts. `shamble_1` and the short attack idles hold.
    /// The 0.2 m/s `walk_1` is left out for the mirror reason: it is close
    /// enough to standing that a zero goal keeps playing it and the zombie
    /// creeps into the player instead of stopping.
    public static var chaseClips: [String] { clips(for: clipSet) }

    public static func clips(for set: ClipSet) -> [String] {
        switch set {
        case .pack: return packClips
        case .style100: return style100Clips
        case .kimodo: return kimodoClips
        case .mixed: return mixedClips
        }
    }

    /// Arm postures for the pose layer, per chase state: hanging while
    /// roaming, clawing while chasing and holding (the second hold take,
    /// whose arms keep grasping rather than sit raised), the same again in
    /// a hyper chase until a frantic "arms high" take exists. In-place
    /// clips whose arms are used over any locomotion; the Kimodo holds
    /// serve every set that lacks its own (every set's clips are loaded),
    /// falling back to the set's idle.
    public static func armClips(for set: ClipSet) -> (hanging: String, raised: String, high: String) {
        let waiting = waitingClip(for: set)
        func pick(_ candidates: [String]) -> String {
            candidates.first(where: clipExists) ?? waiting
        }
        switch set {
        case .pack: return (waiting, pick(["k_arms_grab", "hold_2", "k_hold_2"]), pick(["k_arms_high", "hold_2", "k_hold_2"]))
        case .kimodo: return ("k_idle", pick(["k_arms_grab", "k_hold_2"]), pick(["k_arms_high", "k_hold_2"]))
        case .style100, .mixed: return (waiting, pick(["k_arms_grab", "k_hold_2"]), pick(["k_arms_high", "k_hold_2"]))
        }
    }

    /// Clips the database must never wrap (see
    /// `MotionMatchingDescriptor.oneShotClipNames`): every generated or
    /// captured locomotion take. None of them is cyclic — a generated walk's
    /// last frame sits 20-30 cm from its first, a stop ends standing and
    /// starts running, a pivot ends facing the other way — so a loop wrap is
    /// a hard cut (headless harness, 2026-09-09: 14-68 cm at the seam for
    /// the Kimodo takes, up to 1.1 m for the 100STYLE run). The matcher
    /// leaves them through an inertialized jump instead. The in-place idles
    /// loop (their seams are closed at cook time) and the pack's clips are
    /// authored loops, apart from its two starts.
    public static func oneShotClips(for set: ClipSet) -> Set<String> {
        switch set {
        case .pack: return ["start_chase", "start_hyper"]
        case .style100: return Set(style100Clips).subtracting(["s100_idle"])
        case .kimodo: return Set(kimodoClips).subtracting(["k_idle", "k_hold_1", "k_hold_2"])
        case .mixed: return Set(mixedClips).subtracting(["s100_idle"])
        }
    }

    public static let packClips: [String] = [
        "idle_1",
        "shamble_1", "hold_1", "hold_2", "hold_3", "hold_4",
        "walk_3", "walk_6",
        "chase_1", "chase_2", "chase_3", "chase_5",
        "hyper_1", "hyper_2", "hyper_3", "hyper_5",
        "hyper_1_cir_l", "hyper_1_cir_r", "hyper_3_cir_l", "hyper_3_cir_r",
        "hyper_5_cir_l", "hyper_5_cir_r",
        "turn_l_45", "turn_r_45", "turn_l_90", "turn_r_90",
        "turn_l_180", "turn_r_180",
        "start_chase", "start_hyper",
    ]
}

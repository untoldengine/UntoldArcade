//
//  SceneManifestLoader.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//
//  Maps scene entity names to semantic game roles via scene-manifest.json.
//  Edit the JSON to rename scene objects without touching Swift code.
//

import Foundation
import simd
import UntoldEngine

// MARK: - Match side

/// Which side of the pitch a team or goal belongs to for this match.
/// Goals and teams are linked by side — not by team name — so any two
/// teams can be slotted into a match without changing goal logic.
enum MatchSide {
    case home
    case away

    init?(rawString: String) {
        switch rawString {
        case "home": self = .home
        case "away": self = .away
        default: return nil
        }
    }

    var label: String { self == .home ? "home" : "away" }
    var opposite: MatchSide { self == .home ? .away : .home }
}

// MARK: - Scene Manifest (runtime view)

final class SceneManifest {
    static let shared = SceneManifest()

    struct PlayerEntry {
        let entityName: String
        let role: FormationRole
    }

    struct AnimationEntry {
        let name: String   // logical name used in changeAnimation() — e.g. "idle", "running"
        let file: String   // filename without extension — e.g. "arg_idle_anim"
    }

    struct TeamData {
        let team: Team
        let side: MatchSide
        let modelFilename: String        // e.g. "blueplayer"
        let animations: [AnimationEntry]
        let playerControlledIndex: Int   // -1 means no human player on this team
        let players: [PlayerEntry]
    }

    struct GoalEntry {
        let side: MatchSide
        let position: simd_float3
        let triggerRadius: Float
    }

    struct DebugScenarioEntry {
        let activePlayers: [String]
    }

    struct FieldBounds {
        let width: Float   // X axis (sideline to sideline)
        let height: Float  // Y axis (ground thickness)
        let depth: Float   // Z axis (goal line to goal line)
    }

    // Entity name strings — defaults so the game boots if scene-manifest.json is missing.
    var ballEntityName: String = "Solid_004"
    var fieldEntityName: String = "field"

    // Field size from Blender. The "field" scene entity is a non-renderable
    // container node, so getDimension() returns (2,2,2) on it. We store the
    // real dimensions here so all bounds/clamping code uses authoritative values.
    var fieldBounds: FieldBounds = FieldBounds(width: 68.5264, height: 1.61873, depth: 46.9)

    private(set) var goals: [GoalEntry] = []
    private(set) var teams: [TeamData] = []
    private(set) var debugScenarios: [String: DebugScenarioEntry] = [:]

    var homeTeam: TeamData? { teams.first { $0.side == .home } }
    var awayTeam: TeamData? { teams.first { $0.side == .away } }
    /// The team whose playerControlledIndex >= 0 (has a human player).
    var humanControlledTeam: TeamData? { teams.first { $0.playerControlledIndex >= 0 } }

    func goal(for side: MatchSide) -> GoalEntry? {
        goals.first { $0.side == side }
    }

    /// Returns the logical animation name if the team has that animation registered, nil if not.
    /// Use the returned string directly with changeAnimation() — it matches the name given at spawn time.
    func animationName(for team: Team, logicalName: String) -> String? {
        guard let teamData = teams.first(where: { $0.team == team }) else { return nil }
        return teamData.animations.contains(where: { $0.name == logicalName }) ? logicalName : nil
    }

    func activePlayers(forDebugScenario key: String) -> [String]? {
        debugScenarios[key]?.activePlayers
    }

    private init() {}

    fileprivate func apply(_ file: ManifestFile) {
        ballEntityName  = file.entities.ball
        fieldEntityName = file.entities.field

        if let fb = file.fieldBounds {
            fieldBounds = FieldBounds(width: fb.width, height: fb.height, depth: fb.depth)
        }

        goals = (file.goals ?? []).compactMap { entry -> GoalEntry? in
            guard let side = MatchSide(rawString: entry.side) else {
                Logger.log(message: "⚠️ SceneManifest: Unknown goal side '\(entry.side)' — skipping")
                return nil
            }
            return GoalEntry(
                side: side,
                position: simd_float3(entry.x, entry.y, entry.z),
                triggerRadius: entry.triggerRadius
            )
        }

        teams = file.teams.compactMap { entry -> TeamData? in
            let team = Team(id: entry.teamID)
            guard let side = MatchSide(rawString: entry.side) else {
                Logger.log(message: "⚠️ SceneManifest: Unknown side '\(entry.side)' for team '\(entry.teamID)' — skipping team")
                return nil
            }
            let animations = entry.animations.map { AnimationEntry(name: $0.name, file: $0.file) }
            let players = entry.players.compactMap { p -> PlayerEntry? in
                guard let role = FormationRole(rawString: p.role) else {
                    Logger.log(message: "⚠️ SceneManifest: Unknown role '\(p.role)' for '\(p.entityName)' — skipping player")
                    return nil
                }
                return PlayerEntry(entityName: p.entityName, role: role)
            }
            return TeamData(
                team: team,
                side: side,
                modelFilename: entry.model,
                animations: animations,
                playerControlledIndex: entry.playerControlledIndex,
                players: players
            )
        }

        debugScenarios = file.debugScenarios?.mapValues {
            DebugScenarioEntry(activePlayers: $0.activePlayers ?? [])
        } ?? [:]

        let totalPlayers = teams.reduce(0) { $0 + $1.players.count }
        Logger.log(message: "✅ SceneManifest: loaded \(teams.count) teams (\(totalPlayers) players), \(goals.count) goals, \(debugScenarios.count) debug scenario roster(s)")
    }
}

// MARK: - Decodable file types (private to this file)

private struct ManifestFile: Decodable {
    let entities: EntityNames
    let fieldBounds: FieldBoundsEntry?
    let goals: [GoalEntryRaw]?
    let teams: [TeamEntry]
    let debugScenarios: [String: DebugScenarioEntryRaw]?

    struct EntityNames: Decodable {
        let ball: String
        let field: String
    }

    struct FieldBoundsEntry: Decodable {
        let width: Float
        let height: Float
        let depth: Float
    }

    struct GoalEntryRaw: Decodable {
        let side: String
        let x: Float
        let y: Float
        let z: Float
        let triggerRadius: Float
    }

    struct TeamEntry: Decodable {
        let teamID: String
        let side: String
        let model: String
        let animations: [AnimationEntryRaw]
        let playerControlledIndex: Int
        let players: [PlayerEntry]

        struct AnimationEntryRaw: Decodable {
            let name: String
            let file: String
        }

        struct PlayerEntry: Decodable {
            let entityName: String
            let role: String
        }
    }

    struct DebugScenarioEntryRaw: Decodable {
        let activePlayers: [String]?
    }
}

// MARK: - Load function

func loadSceneManifest() {
    guard let url = bundledSceneManifestURL() else {
        Logger.log(message: "⚠️ SceneManifest: scene-manifest.json not found — using default entity names")
        return
    }

    do {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(ManifestFile.self, from: data)
        SceneManifest.shared.apply(file)
    } catch {
        Logger.log(message: "⚠️ SceneManifest: Failed to parse \(url.lastPathComponent): \(error.localizedDescription)")
    }
}

private func bundledSceneManifestURL() -> URL? {
    if let gameDataURL = assetBasePath {
        let url = gameDataURL
            .appendingPathComponent("Config", isDirectory: true)
            .appendingPathComponent("scene-manifest.json")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
    }

    return Bundle.main.url(
        forResource: "scene-manifest",
        withExtension: "json",
        subdirectory: "GameData/Config"
    )
}

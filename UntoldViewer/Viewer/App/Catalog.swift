//
//  Catalog.swift
//  Untold Viewer
//
//  The objects the viewer can show, each with an engine model under
//  Resources/Models/<id>/<id>.untold and a USDZ twin under
//  Resources/Compare/<id>.usdz made from the same prepared source (see
//  README.md, "Adding an object"), and where the chosen one is placed.
//

import Foundation
import simd

enum Renderer: String {
    case engine
    case realityKit
}

/// Also on stdout and in Documents/viewer.log, which
/// `devicectl device copy from --domain-type appDataContainer` fetches when the
/// console link to the headset will not hold.
func consoleLine(_ line: String) {
    print("viewer: " + line)
    ViewerLog.append(line)
}

enum ViewerLog {
    private static let lock = NSLock()
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("viewer.log")
    private static let clock = ISO8601DateFormatter()

    static func append(_ line: String) {
        guard let url else { return }
        lock.withLock {
            let text = clock.string(from: Date()) + " " + line + "\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

struct ViewerObject: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    /// Where the model's origin sits relative to its visual centre, in the
    /// model's own frame: the board's origin is the bull, a dart's is its tip
    /// with the shaft along +y.
    let originFromCentre: SIMD3<Float>
}

enum Catalog {
    static let all: [ViewerObject] = [
        ViewerObject(id: "board", title: "Dartboard", detail: "170 k triangles, three 4 K maps, wires and digits as geometry",
                     originFromCentre: .zero),
        ViewerObject(id: "dart_red", title: "Dart, red", detail: "8 k triangles, four 1 K maps",
                     originFromCentre: SIMD3<Float>(0, -0.0775, 0)),
        ViewerObject(id: "dart_blue", title: "Dart, blue", detail: "8 k triangles, four 1 K maps",
                     originFromCentre: SIMD3<Float>(0, -0.0775, 0)),
        ViewerObject(id: "dart_green", title: "Dart, green", detail: "8 k triangles, four 1 K maps",
                     originFromCentre: SIMD3<Float>(0, -0.0775, 0)),
        ViewerObject(id: "dart_gold", title: "Dart, gold", detail: "8 k triangles, four 1 K maps",
                     originFromCentre: SIMD3<Float>(0, -0.0775, 0)),
        ViewerObject(id: CalibrationObject.id, title: "Calibration panel", detail: "grey and colour swatches, tone-mapped and exact, and a white, a black and a chrome sphere, built from code in both renderers",
                     originFromCentre: .zero),
    ]

    // UserDefaults keys; a launch argument (`-object dart_red -placement fixed
    // -distance 1.5`) overrides each for one run.
    static let objectKey = "object"
    static let placementModeKey = "placement" // "front" | "fixed"
    static let distanceKey = "distance"
    static let heightKey = "height"
    static let motionKey = "motion" // "still" | "tour"
    static let defaultObject = "board"
    static let defaultDistance: Float = 2.37
    static let defaultHeight: Float = 1.73

    static var selectedID: String {
        UserDefaults.standard.string(forKey: objectKey) ?? defaultObject
    }

    static func selected() -> ViewerObject? {
        let id = selectedID
        return all.first { $0.id == id }
    }

    /// "front": `distance` ahead of where the wearer stands and looks when
    /// the space opens, at eye height, turned to face them. "fixed": in the
    /// room's frame (origin on the floor under the head when the space
    /// opened, −z ahead), `distance` ahead at `height`, facing +z.
    static var placementMode: String {
        UserDefaults.standard.string(forKey: placementModeKey) ?? "front"
    }

    /// The debug tour: the object replays a scripted path relative to its
    /// placement, identically in both renderers, so rendering and recordings
    /// can be compared under motion without a hand on the headset (the
    /// compositor's camera cannot be driven from the app, so the object moves).
    static var motionIsTour: Bool {
        UserDefaults.standard.string(forKey: motionKey) == "tour"
    }

    // `double(forKey:)` reads both the slider's number and a launch argument's string.
    static var distance: Float {
        let value = Float(UserDefaults.standard.double(forKey: distanceKey))
        return value > 0.2 ? value : defaultDistance
    }

    static var height: Float {
        let value = Float(UserDefaults.standard.double(forKey: heightKey))
        return value > 0 ? value : defaultHeight
    }

    struct Placement {
        let object: ViewerObject
        let orientation: simd_quatf
        /// Where the object's visual centre is; a pinch-drag moves it.
        var centre: SIMD3<Float>
        /// Horizontal unit vectors from the object towards the viewer, and to the viewer's right.
        let towardsViewer: SIMD3<Float>
        let right: SIMD3<Float>

        /// The model origin's position for this centre and orientation.
        var position: SIMD3<Float> { centre + orientation.act(object.originFromCentre) }

        /// The pose to draw: the base, or the tour's offset from it at `tourTime`.
        func pose(tourTime: Double?) -> (position: SIMD3<Float>, orientation: simd_quatf) {
            if let tourTime { return Tour.pose(self, at: tourTime) }
            return (position, orientation)
        }
    }

    /// A measurement pass in progress. Its first round (the engine) decides
    /// the placement; the second (RealityKit) reuses it, so both renderers
    /// are judged from the same spot however the wearer moved in between.
    private static let passLock = NSLock()
    private static var passActive = false
    private static var passPlacement: Placement?

    /// Seconds the engine round waits, once its space is open, before taking
    /// the head pose for the placement: time for the wearer to look where the
    /// object should go (the status pill counts it down).
    static let passPlacementDelay = 3.0

    /// During a pass the object's centre sits at eye level (plus this); the
    /// status pill floats a little above it.
    static let passVerticalOffset: Float = 0

    static var isPassActive: Bool { passLock.withLock { passActive } }

    private static let passPlacementKey = "passPlacement"
    private static let passAnchorKey = "passAnchor"

    /// The world anchor the first round pinned the placement to, for the
    /// rounds and runs after it.
    static var storedPassAnchorID: UUID? {
        UserDefaults.standard.string(forKey: passAnchorKey).flatMap(UUID.init(uuidString:))
    }

    static func storePassAnchorID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: passAnchorKey)
        } else {
            UserDefaults.standard.removeObject(forKey: passAnchorKey)
        }
    }

    /// The anchor's transform, as the placement that was pinned to it: the
    /// centre at its origin, the model's +z along its +z.
    static func anchorTransform(of p: Placement) -> simd_float4x4 {
        var t = simd_float4x4(p.orientation)
        t.columns.3 = SIMD4<Float>(p.centre, 1)
        return t
    }

    /// Replaces the stored pass placement with the anchor's current pose, in
    /// this session's frame.
    static func refreshStoredPlacement(from anchor: simd_float4x4) {
        passLock.withLock {
            guard var p = passPlacement else { return }
            let orientation = simd_normalize(simd_quatf(anchor))
            let centre = SIMD3<Float>(anchor.columns.3.x, anchor.columns.3.y, anchor.columns.3.z)
            let towards = orientation.act(SIMD3<Float>(0, 0, 1))
            let forward = -towards
            p = Placement(object: p.object, orientation: orientation, centre: centre,
                          towardsViewer: towards, right: simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0))))
            passPlacement = p
        }
    }

    /// The pass placement in memory, if a round decided or resolved one.
    static var currentPassPlacement: Placement? { passLock.withLock { passPlacement } }

    /// `reusingStored`: a RealityKit-only run takes the placement the last
    /// engine run saved, so two recordings still compare the same spot.
    static func beginPass(reusingStored: Bool = false) {
        passLock.withLock {
            passActive = true
            passPlacement = reusingStored ? loadStoredPassPlacement() : nil
        }
    }

    static func endPass() {
        passLock.withLock {
            passActive = false
            passPlacement = nil
        }
    }

    private static func storePassPlacement(_ p: Placement) {
        let values: [Float] = [p.centre.x, p.centre.y, p.centre.z,
                               p.orientation.vector.x, p.orientation.vector.y, p.orientation.vector.z, p.orientation.vector.w,
                               p.towardsViewer.x, p.towardsViewer.y, p.towardsViewer.z, p.right.x, p.right.y, p.right.z]
        UserDefaults.standard.set(["object": p.object.id, "values": values.map { Double($0) }] as [String: Any], forKey: passPlacementKey)
    }

    private static func loadStoredPassPlacement() -> Placement? {
        guard let dict = UserDefaults.standard.dictionary(forKey: passPlacementKey),
              let id = dict["object"] as? String, let object = all.first(where: { $0.id == id }),
              let values = (dict["values"] as? [Double])?.map({ Float($0) }), values.count == 13 else { return nil }
        return Placement(object: object,
                         orientation: simd_quatf(vector: SIMD4<Float>(values[3], values[4], values[5], values[6])),
                         centre: SIMD3<Float>(values[0], values[1], values[2]),
                         towardsViewer: SIMD3<Float>(values[7], values[8], values[9]),
                         right: SIMD3<Float>(values[10], values[11], values[12]))
    }

    /// In the simulator ARKit's frame (the device anchor, the engine's camera)
    /// has its origin at the head while RealityKit's has it on the floor, so
    /// the RealityKit side lifts a head-relative placement by the simulated
    /// eye height. On the device both frames are the same.
    static var simulatorEyeHeight: Float {
        #if targetEnvironment(simulator)
        return 1.5
        #else
        return 0
        #endif
    }

    /// The chosen object's pose. `head` is the device anchor when the space
    /// opened; without one (or in "fixed" mode) the room's frame is used.
    /// Identical for both renderers; `lift` is the RealityKit side's
    /// simulator correction.
    static func placement(head: simd_float4x4?, lift: Float = 0) -> Placement? {
        guard let object = selected() else { return nil }
        let (inPass, stored) = passLock.withLock { (passActive, passPlacement) }
        if inPass, var stored, stored.object == object {
            stored.centre += SIMD3<Float>(0, lift, 0)
            return stored
        }
        var centre = SIMD3<Float>(0, height, -distance)
        var orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        var forward = SIMD3<Float>(0, 0, -1)
        if placementMode == "front", let head {
            let eye = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
            // The device anchor looks down its −z; keep the horizontal part. Straight
            // ahead, as a measurement pass places it: the Controls window moves aside.
            forward = -SIMD3<Float>(head.columns.2.x, 0, head.columns.2.z)
            forward = simd_length(forward) > 1e-4 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
            centre = eye + forward * distance
            if inPass {
                centre.y += passVerticalOffset
            }
            // The models face +z; turn that towards the wearer.
            orientation = simd_quatf(angle: atan2(-forward.x, -forward.z), axis: SIMD3<Float>(0, 1, 0))
        }
        var placement = Placement(object: object, orientation: orientation, centre: centre,
                                  towardsViewer: -forward, right: simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0))))
        if inPass {
            // The first round's placement, before any simulator lift, for the
            // second — and for a later RealityKit-only run.
            passLock.withLock { passPlacement = placement }
            storePassPlacement(placement)
        }
        placement.centre += SIMD3<Float>(0, lift, 0)
        return placement
    }

    /// The tour's path, a 24 s loop: six seconds coming in to 30 % of the
    /// distance, six going back, six sweeping 0.6 m left and right, six
    /// turning ±25° — far-away shimmer, close-up detail, lateral motion for
    /// the temporal filter, and a turning silhouette, in that order.
    enum Tour {
        static let period = 24.0

        static func pose(_ placement: Placement, at time: Double) -> (position: SIMD3<Float>, orientation: simd_quatf) {
            let phase = time.truncatingRemainder(dividingBy: period)
            // 0 → 1, eased at both ends.
            func ease(_ u: Double) -> Float { Float(0.5 - 0.5 * cos(min(max(u, 0), 1) * .pi)) }
            let approach = Catalog.distance * 0.7
            var offset = SIMD3<Float>(0, 0, 0)
            var yaw: Float = 0
            switch phase {
            case ..<6:
                offset = placement.towardsViewer * (approach * ease(phase / 6))
            case ..<12:
                offset = placement.towardsViewer * (approach * (1 - ease((phase - 6) / 6)))
            case ..<18:
                offset = placement.right * Float(sin((phase - 12) / 6 * 2 * .pi)) * 0.6
            default:
                yaw = Float(sin((phase - 18) / 6 * 2 * .pi)) * (25 * .pi / 180)
            }
            let orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) * placement.orientation
            let centre = placement.centre + offset
            return (centre + orientation.act(placement.object.originFromCentre), orientation)
        }
    }
}

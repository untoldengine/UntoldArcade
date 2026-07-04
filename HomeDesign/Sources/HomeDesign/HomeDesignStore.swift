//
//  HomeDesignStore.swift
//  HomeDesign
//

import Foundation

enum PlacementSurface: Sendable, Equatable {
    case floor
    case wall
}

/// Snapshot of how many of a floor plan's models have finished loading, backed by the
/// engine's `AssetLoadingState` (see `GameSceneUtils.loadSelectedFloorPlan`).
struct LoadProgress: Sendable, Equatable {
    let completed: Int
    let total: Int

    var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}

enum PanelAction: Sendable {
    case remove
    case rotateLeft
    case rotateRight
    case duplicate
    case resetFloorPlanScale
    case toggleMiniature
    case toggleAmbientLighting
    case undo
}

/// Thread-safe bridge for commands flowing SwiftUI → game loop.
/// For state flowing game loop → SwiftUI, see SelectionStore.
final class HomeDesignStore {
    static let shared = HomeDesignStore()

    private let lock = NSLock()
    private var _pendingAction: PanelAction? = nil
    private var _snapEnabled: Bool = true
    private var _placementSurface: PlacementSurface = .floor
    private var _selectedFloorPlanName: String? = nil

    init() {}

    func requestAction(_ action: PanelAction) {
        lock.withLock { _pendingAction = action }
    }

    /// Called once per frame from the game loop. Clears and returns any pending action.
    func consumeAction() -> PanelAction? {
        lock.withLock {
            defer { _pendingAction = nil }
            return _pendingAction
        }
    }

    /// Thread-safe snap toggle — written from main thread, read from game loop every frame.
    var snapEnabled: Bool {
        get { lock.withLock { _snapEnabled } }
        set { lock.withLock { _snapEnabled = newValue } }
    }

    /// Thread-safe placement surface — floor or wall.
    var placementSurface: PlacementSurface {
        get { lock.withLock { _placementSurface } }
        set { lock.withLock { _placementSurface = newValue } }
    }

    /// Thread-safe floor plan choice — the scene name GameScene should load via
    /// `loadUntoldScene(named:)`. Written once from the picker UI, read from the game loop.
    var selectedFloorPlanName: String? {
        get { lock.withLock { _selectedFloorPlanName } }
        set { lock.withLock { _selectedFloorPlanName = newValue } }
    }

    /// Post a selection-changed notification to SelectionStore on the main thread.
    func notifySelectionChanged(hasSelection: Bool) {
        Task { @MainActor in
            SelectionStore.shared.hasSelection = hasSelection
        }
    }

    /// Post an undo-state-changed notification to SelectionStore on the main thread.
    func notifyUndoStateChanged(canUndo: Bool) {
        Task { @MainActor in
            SelectionStore.shared.canUndo = canUndo
        }
    }

    /// Post a floor-plan-scale notification to SelectionStore on the main thread.
    func notifyFloorPlanScaleChanged(_ scale: Float) {
        Task { @MainActor in
            SelectionStore.shared.floorPlanScale = scale
        }
    }

    /// Called once when initial floor placement calibration completes.
    func notifyCalibrationComplete() {
        Task { @MainActor in
            SelectionStore.shared.calibrationComplete = true
        }
    }

    /// Called whenever miniature mode toggles (including at animation end).
    func notifyMiniatureModeChanged(_ isMiniature: Bool) {
        Task { @MainActor in
            SelectionStore.shared.isMiniatureMode = isMiniature
        }
    }

    /// Post a floor-plan loading-progress update to SelectionStore on the main thread.
    /// `nil` means no floor plan load is in flight.
    func notifyFloorPlanLoadProgress(_ progress: LoadProgress?) {
        Task { @MainActor in
            SelectionStore.shared.floorPlanLoadProgress = progress
        }
    }

    /// Post an ambient-lighting-toggle notification to SelectionStore on the main thread.
    func notifyAmbientLightingChanged(_ enabled: Bool) {
        Task { @MainActor in
            SelectionStore.shared.ambientLightingEnabled = enabled
        }
    }

    /// Show a short-lived on-screen notice (e.g. a failed asset load or a
    /// missed calibration tap) so failures are visible instead of console-only.
    /// A newer message won't be clobbered by an older one's auto-dismiss.
    func notifyTransient(_ message: String) {
        Task { @MainActor in
            SelectionStore.shared.transientNotice = message
            try? await Task.sleep(for: .seconds(3))
            if SelectionStore.shared.transientNotice == message {
                SelectionStore.shared.transientNotice = nil
            }
        }
    }
}

/// Main-thread observable store for SwiftUI to react to game-loop state changes.
@MainActor
final class SelectionStore: ObservableObject {
    static let shared = SelectionStore()
    @Published var hasSelection = false
    @Published var canUndo = false
    @Published var floorPlanScale: Float = 1.0
    @Published var snapEnabled: Bool = true
    @Published var placementSurface: PlacementSurface = .floor
    @Published var selectedFloorPlanName: String? = nil
    @Published var floorPlanLoadProgress: LoadProgress? = nil
    @Published var calibrationComplete: Bool = false
    @Published var isMiniatureMode: Bool = false
    @Published var ambientLightingEnabled: Bool = true
    @Published var transientNotice: String? = nil
    private init() {}
}

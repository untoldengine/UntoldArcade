//
//  SaberHaptics.swift  (visionOS)
//  CoolSaber
//
//  Controller haptics for ignite/clash. The engine has no haptics layer, so
//  this talks to GameController/CoreHaptics directly. PSVR2 Sense wands show
//  up as two separate GCController objects; handedness is inferred from which
//  side-prefixed elements each wand's input profile carries. If that ever
//  fails, pulses fall back to every connected wand.
//

import CoolSaber
import CoreHaptics
import Foundation
@preconcurrency import GameController

final class SaberHaptics: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.miolabs.coolsaber.haptics")
    private var engines: [ObjectIdentifier: (engine: CHHapticEngine, hand: SaberHand?)] = [:]
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: nil
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.queue.async { self?.attach(controller) }
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: nil
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.queue.async { self?.detach(controller) }
        })
        queue.async { [weak self] in
            for controller in GCController.controllers() {
                self?.attach(controller)
            }
        }
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        queue.async { [weak self] in
            self?.engines.values.forEach { $0.engine.stop() }
            self?.engines.removeAll()
        }
    }

    func ignitePulse(hand: SaberHand) {
        play(hand: hand, intensity: 0.6, sharpness: 0.4, duration: 0.08)
    }

    func clashPulse(hand: SaberHand, intensity: Float) {
        play(
            hand: hand,
            intensity: min(max(intensity, 0.5), 1.0),
            sharpness: 0.9,
            duration: 0.12
        )
    }

    // MARK: - Internals (all on `queue`)

    private func attach(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        guard engines[key] == nil, let haptics = controller.haptics else { return }
        guard let engine = haptics.createEngine(withLocality: .default) else { return }

        engine.resetHandler = { [weak engine] in try? engine?.start() }
        engine.isAutoShutdownEnabled = true
        // No eager start: during the immersive-space transition it blocks with
        // a startup timeout. play() starts the engine on demand.

        let hand = SaberWandInput.inferHand(of: controller)
        engines[key] = (engine, hand)
        print(
            "CoolSaber: haptics attached to \(controller.vendorName ?? "controller") "
                + "hand=\(hand.map(String.init(describing:)) ?? "unknown")"
        )
    }

    private func detach(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        engines[key]?.engine.stop()
        engines[key] = nil
    }

    private func play(hand: SaberHand, intensity: Float, sharpness: Float, duration: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            let matching = self.engines.values.filter { $0.hand == hand }
            // Unknown handedness: pulse everything rather than nothing.
            let targets = matching.isEmpty ? Array(self.engines.values) : matching
            for target in targets {
                do {
                    let events = [
                        CHHapticEvent(
                            eventType: .hapticTransient,
                            parameters: [
                                .init(parameterID: .hapticIntensity, value: intensity),
                                .init(parameterID: .hapticSharpness, value: sharpness),
                            ],
                            relativeTime: 0
                        ),
                        CHHapticEvent(
                            eventType: .hapticContinuous,
                            parameters: [
                                .init(parameterID: .hapticIntensity, value: intensity * 0.4),
                                .init(parameterID: .hapticSharpness, value: sharpness * 0.5),
                            ],
                            relativeTime: 0.01,
                            duration: duration
                        ),
                    ]
                    let pattern = try CHHapticPattern(events: events, parameters: [])
                    let player = try target.engine.makePlayer(with: pattern)
                    try target.engine.start()
                    try player.start(atTime: CHHapticTimeImmediate)
                } catch {
                    // Haptics are garnish; never let them take the frame down.
                }
            }
        }
    }
}

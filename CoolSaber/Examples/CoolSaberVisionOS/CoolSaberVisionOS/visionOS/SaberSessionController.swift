//
//  SaberSessionController.swift  (visionOS)
//  CoolSaber
//
//  SharePlay plumbing. The controller lives on the main actor; the XR game
//  loop runs on its own thread and must never touch actor state, so all
//  game-facing traffic goes through the lock-guarded SaberDuelMailbox.
//

import Combine
import CoolSaber
import Foundation
import GroupActivities
import simd
import SwiftUI // pulls in the _GroupActivities_SwiftUI overlay (groupImmersionStyle)

/// Thread-safe bridge between the main-actor SharePlay session and the XR
/// game thread. The game writes outgoing poses/events and reads the latest
/// remote state; the session controller does the opposite.
final class SaberDuelMailbox: @unchecked Sendable {
    static let shared = SaberDuelMailbox()

    private let lock = NSLock()

    private var outgoingPacket: SaberPosePacket?
    private var outgoingEvents: [SaberEvent] = []
    private var remotePacket: SaberPosePacket?
    private var remoteArrivalUptime: TimeInterval = 0
    private var remoteEvents: [SaberEvent] = []
    private var sessionActiveStorage = false
    private var isSpatialStorage = false
    private var opponentPresentStorage = false

    // MARK: Game-thread side

    func publishLocalPoses(_ packet: SaberPosePacket) {
        lock.withLock { outgoingPacket = packet }
    }

    func pushLocalEvent(_ event: SaberEvent) {
        lock.withLock { outgoingEvents.append(event) }
    }

    func remoteSnapshot() -> (packet: SaberPosePacket?, arrivalUptime: TimeInterval) {
        lock.withLock { (remotePacket, remoteArrivalUptime) }
    }

    func takeRemoteEvents() -> [SaberEvent] {
        lock.withLock {
            let events = remoteEvents
            remoteEvents.removeAll()
            return events
        }
    }

    var sessionActive: Bool {
        lock.withLock { sessionActiveStorage }
    }

    /// True when the system coordinates a shared immersive-space origin
    /// (spatial Personas). False means remote poses need the opponent anchor.
    var isSpatial: Bool {
        lock.withLock { isSpatialStorage }
    }

    var opponentPresent: Bool {
        lock.withLock { opponentPresentStorage }
    }

    // MARK: Session-controller side

    func takeOutgoing() -> (packet: SaberPosePacket?, events: [SaberEvent]) {
        lock.withLock {
            let packet = outgoingPacket
            let events = outgoingEvents
            outgoingPacket = nil
            outgoingEvents.removeAll()
            return (packet, events)
        }
    }

    func storeRemote(_ packet: SaberPosePacket) {
        lock.withLock {
            if let existing = remotePacket, packet.sequence <= existing.sequence,
               existing.sequence - packet.sequence < UInt32.max / 2 {
                return // stale or out of order
            }
            remotePacket = packet
            remoteArrivalUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    func pushRemoteEvent(_ event: SaberEvent) {
        lock.withLock { remoteEvents.append(event) }
    }

    func setSessionActive(_ active: Bool) {
        lock.withLock {
            sessionActiveStorage = active
            if !active {
                remotePacket = nil
                remoteEvents.removeAll()
                outgoingPacket = nil
                outgoingEvents.removeAll()
                opponentPresentStorage = false
            }
        }
    }

    func setIsSpatial(_ spatial: Bool) {
        lock.withLock { isSpatialStorage = spatial }
    }

    func setOpponentPresent(_ present: Bool) {
        lock.withLock {
            opponentPresentStorage = present
            if !present { remotePacket = nil }
        }
    }
}

@MainActor
@Observable
final class SaberSessionController {
    enum Status: Equatable {
        case idle
        case waiting
        case joined(participants: Int)
    }

    private(set) var status: Status = .idle
    private(set) var statusMessage = "Solo practice — start a duel from a FaceTime call."
    /// Mirrors the system's group-immersion request: true → open the immersive
    /// space, false → dismiss it, nil → no opinion (manual control).
    private(set) var groupImmersionActive: Bool?

    let mailbox = SaberDuelMailbox.shared

    private var session: GroupSession<SaberActivity>?
    private var poseMessenger: GroupSessionMessenger?
    private var eventMessenger: GroupSessionMessenger?
    private var tasks: [Task<Void, Never>] = []
    private var subscriptions: Set<AnyCancellable> = []

    /// Call once at app launch; handles every incoming session for the activity.
    func startSessionObserver() {
        Task {
            for await session in SaberActivity.sessions() {
                configure(session)
            }
        }
    }

    func startDuel() {
        statusMessage = "Starting duel…"
        Task {
            do {
                _ = try await SaberActivity().activate()
            } catch {
                statusMessage = "Could not start SharePlay: \(error.localizedDescription)"
            }
        }
    }

    func leaveDuel() {
        session?.leave()
        cleanup(message: "Left the duel. Solo practice.")
    }

    private func configure(_ session: GroupSession<SaberActivity>) {
        cleanup(message: statusMessage)
        self.session = session
        status = .waiting
        statusMessage = "Duel session found — joining…"

        // Messengers and receive loops must exist before join() so no early
        // message is dropped.
        let poses = GroupSessionMessenger(session: session, deliveryMode: .unreliable)
        let events = GroupSessionMessenger(session: session, deliveryMode: .reliable)
        poseMessenger = poses
        eventMessenger = events

        tasks.append(Task { [mailbox] in
            for await (packet, _) in poses.messages(of: SaberPosePacket.self) {
                mailbox.storeRemote(packet)
            }
        })
        tasks.append(Task { [mailbox] in
            for await (event, _) in events.messages(of: SaberEvent.self) {
                mailbox.pushRemoteEvent(event)
            }
        })

        // Outgoing pump: drain the mailbox at ~45 Hz. Unreliable sends are
        // fire-and-forget; a dropped pose packet is superseded 22 ms later.
        tasks.append(Task { [mailbox, weak self] in
            while !Task.isCancelled {
                let outgoing = mailbox.takeOutgoing()
                if let packet = outgoing.packet {
                    try? await poses.send(packet)
                }
                for event in outgoing.events {
                    try? await events.send(event)
                }
                guard self != nil else { return }
                try? await Task.sleep(nanoseconds: 22_000_000)
            }
        })

        tasks.append(Task { [weak self] in
            await self?.configureSystemCoordinator(for: session)
        })

        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .joined:
                    self.status = .joined(participants: session.activeParticipants.count)
                    self.statusMessage = "Duel joined — waiting for your opponent's blades."
                    self.mailbox.setSessionActive(true)
                case .waiting:
                    self.status = .waiting
                case .invalidated:
                    self.cleanup(message: "Duel ended. Solo practice.")
                @unknown default:
                    break
                }
            }
            .store(in: &subscriptions)

        session.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                guard let self, let session = self.session else { return }
                let opponents = participants.subtracting([session.localParticipant])
                self.mailbox.setOpponentPresent(!opponents.isEmpty)
                if case .joined = self.status {
                    self.status = .joined(participants: participants.count)
                    self.statusMessage = opponents.isEmpty
                        ? "Waiting for an opponent to join…"
                        : "Opponent connected — fight!"
                }
            }
            .store(in: &subscriptions)

        session.join()
    }

    private func configureSystemCoordinator(for session: GroupSession<SaberActivity>) async {
        guard let coordinator = await session.systemCoordinator else { return }

        var configuration = SystemCoordinator.Configuration()
        configuration.supportsGroupImmersiveSpace = true
        // A duel wants the participants facing each other with room between.
        configuration.spatialTemplatePreference = .conversational
        coordinator.configuration = configuration

        tasks.append(Task { [mailbox] in
            for await state in coordinator.localParticipantStates {
                mailbox.setIsSpatial(state.isSpatial)
            }
        })
        tasks.append(Task { [weak self] in
            for await immersionStyle in coordinator.groupImmersionStyle {
                await MainActor.run {
                    self?.groupImmersionActive = immersionStyle != nil
                }
            }
        })
    }

    private func cleanup(message: String) {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        subscriptions.removeAll()
        poseMessenger = nil
        eventMessenger = nil
        session = nil
        status = .idle
        statusMessage = message
        groupImmersionActive = nil
        mailbox.setSessionActive(false)
    }
}

//
//  MocapTransport.swift
//  CoolMirrorMocap
//
//  Bonjour discovery plus UDP datagrams over Network.framework: the mirror
//  listens, the phone browses and streams.
//

import Foundation
import Network

/// visionOS side: advertises the service and keeps the newest frame.
public final class MocapReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.miolabs.coolmirror.mocap-receiver")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var latest: MocapFrame?
    private var latestPreviewFrame: MocapPreviewFrame?
    private var sink: (@Sendable (MocapFrame) -> Void)?
    private var previewAssembler = MocapPreviewAssembler()
    private var previewChunks = 0
    private var previewsAssembled = 0
    private var frameTimes: [TimeInterval] = []
    private var lastFrameTime: TimeInterval?
    private var statusText = "stopped"
    private var peer: String?

    public init() {}

    /// Newest decoded frame, or nil before the first one.
    /// Called with every frame as it arrives (network queue), whether or
    /// not the mirror gets to use it: for recording.
    public var frameSink: (@Sendable (MocapFrame) -> Void)? {
        get { lock.withLock { sink } }
        set { lock.withLock { sink = newValue } }
    }

    public var latestFrame: MocapFrame? {
        lock.withLock { latest }
    }

    /// Newest complete camera preview, or nil before the first one.
    public var latestPreview: MocapPreviewFrame? {
        lock.withLock { latestPreviewFrame }
    }

    /// Preview datagrams received and pictures completed from them.
    public var previewCounts: (chunks: Int, pictures: Int) {
        lock.withLock { (previewChunks, previewsAssembled) }
    }

    /// Frames received during the last second.
    public var framesPerSecond: Int {
        lock.withLock {
            let now = Date().timeIntervalSinceReferenceDate
            frameTimes.removeAll { now - $0 > 1 }
            return frameTimes.count
        }
    }

    public var status: String {
        lock.withLock {
            let now = Date().timeIntervalSinceReferenceDate
            frameTimes.removeAll { now - $0 > 1 }
            if let peer, !frameTimes.isEmpty {
                return "receiving from \(peer) at \(frameTimes.count) Hz"
            }
            return statusText
        }
    }

    /// Whether an iPhone has connected (frames may still be absent while it
    /// sees no body).
    public var isPeerConnected: Bool {
        lock.withLock { peer != nil }
    }

    /// Seconds since the last frame arrived, or nil before the first one.
    public var secondsSinceLastFrame: TimeInterval? {
        lock.withLock {
            guard let last = frameTimes.last ?? lastFrameTime else { return nil }
            return Date().timeIntervalSinceReferenceDate - last
        }
    }

    public func start() {
        stop()
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: MocapService.name, type: MocapService.bonjourType)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let text: String
                switch state {
                case .ready: text = "listening on port \(listener.port?.rawValue ?? 0), waiting for the iPhone"
                case let .failed(error): text = "listener failed: \(error)"
                case .cancelled: text = "stopped"
                default: text = "starting…"
                }
                self.lock.withLock { self.statusText = text }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lock.withLock { statusText = "cannot listen: \(error)" }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        lock.withLock {
            latest = nil
            latestPreviewFrame = nil
            previewAssembler = MocapPreviewAssembler()
            frameTimes.removeAll()
            lastFrameTime = nil
            peer = nil
            statusText = "stopped"
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        let description: String
        if case let .hostPort(host, _) = connection.endpoint {
            description = "\(host)"
        } else {
            description = "\(connection.endpoint)"
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.withLock { self.peer = description }
                if let connection { self.receive(on: connection) }
            case .failed, .cancelled:
                if let connection {
                    self.connections.removeAll { $0 === connection }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, MocapPreviewFrame.isChunk(data) {
                self.lock.withLock {
                    self.previewChunks += 1
                    if let preview = self.previewAssembler.add(data) {
                        self.latestPreviewFrame = preview
                        self.previewsAssembled += 1
                    }
                }
            } else if let data, let frame = MocapFrame(data: data) {
                let sink = self.lock.withLock { () -> (@Sendable (MocapFrame) -> Void)? in
                    if self.latest == nil || frame.sequence >= (self.latest?.sequence ?? 0) || frame.sequence < 16 {
                        self.latest = frame
                    }
                    let now = Date().timeIntervalSinceReferenceDate
                    self.frameTimes.append(now)
                    self.lastFrameTime = now
                    return self.sink
                }
                sink?(frame)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }
}

/// iOS side: finds the mirror through Bonjour and streams frames to it.
public final class MocapSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.miolabs.coolmirror.mocap-sender")
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var statusText = "stopped"
    private var ready = false
    private var sequence: UInt32 = 0

    public init() {}

    public var status: String {
        lock.withLock { statusText }
    }

    public var isConnected: Bool {
        lock.withLock { ready }
    }

    public func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: MocapService.bonjourType, domain: nil), using: .udp)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.lock.withLock { if self.connection == nil { self.statusText = "looking for the mirror…" } }
            case let .failed(error): self.lock.withLock { self.statusText = "browse failed: \(error)" }
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let result = results.first else { return }
            self.connect(to: result.endpoint)
        }
        browser.start(queue: queue)
        self.browser = browser
        lock.withLock { statusText = "looking for the mirror…" }
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        lock.withLock {
            ready = false
            statusText = "stopped"
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.withLock {
                    self.ready = true
                    self.statusText = "streaming to \(endpoint)"
                }
            case let .failed(error):
                self.lock.withLock {
                    self.ready = false
                    self.statusText = "connection failed: \(error)"
                }
                self.connection = nil
            case .cancelled:
                self.lock.withLock { self.ready = false }
                self.connection = nil
            default:
                self.lock.withLock { self.statusText = "connecting…" }
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    /// Sends `frame` (its sequence number is assigned here).
    public func send(_ frame: MocapFrame) {
        guard let connection, isConnected else { return }
        var stamped = frame
        stamped.sequence = lock.withLock {
            sequence &+= 1
            return sequence
        }
        connection.send(content: stamped.encode(), completion: .contentProcessed { _ in })
    }

    /// Sends a camera preview, one datagram per chunk.
    public func send(_ preview: MocapPreviewFrame) {
        guard let connection, isConnected else { return }
        for chunk in preview.chunks() {
            connection.send(content: chunk, completion: .contentProcessed { _ in })
        }
    }
}

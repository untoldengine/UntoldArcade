//
//  CoolBowlingAudio.swift
//  CoolBowling
//
//  Bowling sound design with zero asset files: the ball's thud, the pin
//  clack and the strike fanfare are synthesized at startup and mixed in a single
//  AVAudioSourceNode render callback. Deliberately NO AVAudioPlayerNode and
//  NO scheduleBuffer — on visionOS the engine can report started before
//  audio IO cycles, and player.play() then throws the uncatchable "player
//  did not see an IO cycle" NSException; a source node only renders when IO
//  actually runs, so that failure mode cannot exist. (Pattern proven in
//  CoolSaber's SaberAudio.)
//

import AVFAudio
import Foundation
import os

public final class CoolBowlingAudio: @unchecked Sendable {
    private struct OneShot {
        var bank: Int
        var position: Int = 0
        var volume: Float
    }

    private enum Bank {
        static let thud = 0
        static let strike = 1
        static let pin = 2
    }

    private let queue = DispatchQueue(label: "com.miolabs.coolbowling.audio")
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double = 48000

    // Immutable after synthesis.
    private var sampleBanks: [[Float]] = []

    private let stateLock = NSLock()
    private var oneShots: [OneShot] = []
    private var lastThudTime: TimeInterval = 0
    private var lastPinTime: TimeInterval = 0

    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var retryTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var renderInvocations = 0
    private var watchdogLastSeen = -1

    public init() {}

    // MARK: - Public API (safe from the XR game thread)

    public func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.retryTimer?.cancel()
            self.retryTimer = nil
            self.watchdogTimer?.cancel()
            self.watchdogTimer = nil
            for observer in self.observers {
                NotificationCenter.default.removeObserver(observer)
            }
            self.observers.removeAll()
            self.engine.stop()
            self.started = false
            self.stateLock.withLock { self.oneShots.removeAll() }
        }
    }

    /// The ball landing on the lane. `intensity` 0…1 scales volume; rapid
    /// contacts are rate-limited so a rolling ball doesn't machine-gun.
    public func playThud(intensity: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.withLock {
            guard now - lastThudTime > 0.09 else { return }
            lastThudTime = now
        }
        enqueueOneShot(bank: Bank.thud, volume: min(max(intensity, 0.12), 1.0))
    }

    /// A pin being hit — by the ball, another pin or the floor.
    public func playPinHit(intensity: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.withLock {
            guard now - lastPinTime > 0.035 else { return }
            lastPinTime = now
        }
        enqueueOneShot(bank: Bank.pin, volume: min(max(intensity, 0.15), 1.0))
    }

    public func playStrike() {
        enqueueOneShot(bank: Bank.strike, volume: 0.85)
    }

    /// The fanfare, quieter: ten down over two balls.
    public func playSpare() {
        enqueueOneShot(bank: Bank.strike, volume: 0.45)
    }

    private func enqueueOneShot(bank: Int, volume: Float) {
        stateLock.withLock {
            guard bank < sampleBanks.count, !sampleBanks[bank].isEmpty else { return }
            if oneShots.count < 8 {
                oneShots.append(OneShot(bank: bank, volume: volume))
            }
        }
        coolBowlingLog.debug("audio one-shot bank=\(bank) volume=\(volume, format: .fixed(precision: 2))")
    }

    // MARK: - Engine lifecycle (on `queue`)

    private func startOnQueue() {
        guard !started else { return }

        if sampleBanks.isEmpty {
            sampleBanks = [makeThud(), makeStrike(), makePinClack()]
        }

        if sourceNode == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
                self?.render(frameCount: frameCount, audioBufferList: audioBufferList)
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sourceNode = node

            observers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async {
                    guard let self, self.started else { return }
                    self.engine.stop()
                    self.startEngineWithRetry()
                }
            })
        }

        // Give the immersive-space scene transition a beat to settle: session
        // activation during the transition "succeeds" with a dead proxy.
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startEngineWithRetry()
        }
        startWatchdog()
    }

    /// Session activation can lag the immersive space opening; keep trying
    /// instead of failing silently.
    private func startEngineWithRetry() {
        do {
            #if !os(macOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            engine.prepare()
            try engine.start()
            started = true
            retryTimer?.cancel()
            retryTimer = nil
            coolBowlingLog.log("audio engine running")
        } catch {
            coolBowlingLog.log("audio engine start failed (\(error, privacy: .public)) — retrying")
            started = false
            guard retryTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if self.started {
                    self.retryTimer?.cancel()
                    self.retryTimer = nil
                } else {
                    self.startEngineWithRetry()
                }
            }
            timer.resume()
            retryTimer = timer
        }
    }

    /// The session can activate "successfully" yet be dead (proxy lookup
    /// failure during scene transitions): the engine reports running but the
    /// render callback never fires. Detect the stall and restart.
    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.started else { return }
            let seen = self.stateLock.withLock { self.renderInvocations }
            if seen == self.watchdogLastSeen {
                coolBowlingLog.log("audio IO stalled — restarting engine")
                self.engine.stop()
                self.started = false
                self.startEngineWithRetry()
            }
            self.watchdogLastSeen = seen
        }
        timer.resume()
        watchdogTimer = timer
    }

    // MARK: - Render (audio thread)

    private func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        let frames = Int(frameCount)

        stateLock.lock()
        defer { stateLock.unlock() }
        renderInvocations &+= 1

        for frame in 0 ..< frames {
            var value: Float = 0
            for index in 0 ..< oneShots.count {
                let samples = sampleBanks[oneShots[index].bank]
                if oneShots[index].position < samples.count {
                    value += samples[oneShots[index].position] * oneShots[index].volume
                    oneShots[index].position += 1
                }
            }
            out[frame] = max(-1, min(1, value))
        }
        oneShots.removeAll { $0.position >= sampleBanks[$0.bank].count }

        for buffer in buffers.dropFirst() {
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                data.update(from: out, count: frames)
            }
        }
    }

    // MARK: - DSP (pure, run once at startup)

    /// The pin clack: a bright, woody knock — a short burst of band-passed
    /// noise with two decaying resonances (900 Hz body, 2.4 kHz crack).
    private func makePinClack() -> [Float] {
        let duration = 0.12
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var noiseState: UInt64 = 0x5DEE_CE66_D1D2_A5F3
        var phaseA: Double = 0
        var phaseB: Double = 0
        var lp: Float = 0
        for i in 0 ..< count {
            let t = Double(i) / sampleRate
            noiseState = Self.nextRandom(noiseState)
            let white = Float(Int64(bitPattern: noiseState % 2000) - 1000) / 1000.0
            lp += 0.55 * (white - lp)
            let crack = lp * Float(exp(-t / 0.006))
            phaseA += 900.0 / sampleRate
            phaseB += 2400.0 / sampleRate
            let body = Float(sin(2.0 * .pi * phaseA)) * Float(exp(-t / 0.035)) * 0.6
                + Float(sin(2.0 * .pi * phaseB)) * Float(exp(-t / 0.018)) * 0.35
            samples[i] = (crack * 0.9 + body) * 0.8
        }
        return samples
    }

    /// The thud: a punchy low thump — a pitch-dropping sine (130 → 42 Hz)
    /// under a short slap noise click, both exponentially decayed.
    private func makeThud() -> [Float] {
        let duration = 0.22
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var phase: Double = 0
        var noiseState: UInt64 = 0x9E37_79B9_7F4A_7C15
        var noiseLP: Float = 0

        for i in 0 ..< count {
            let t = Double(i) / sampleRate
            // Body: exponential pitch drop, exponential amplitude decay.
            let frequency = 42.0 + 88.0 * exp(-t / 0.045)
            phase += frequency / sampleRate
            let body = Float(sin(2.0 * .pi * phase)) * Float(exp(-t / 0.075))

            // Slap: 12 ms of lightly lowpassed noise.
            noiseState = Self.nextRandom(noiseState)
            let white = Float(Int64(bitPattern: noiseState % 2000) - 1000) / 1000.0
            noiseLP += 0.35 * (white - noiseLP)
            let slap = noiseLP * Float(exp(-t / 0.012)) * 0.5

            samples[i] = (body * 0.9 + slap) * 0.9
        }
        return samples
    }

    /// The strike: a stadium-horn chord (three detuned voices with vibrato
    /// and odd harmonics) over a crowd-roar swell of shaped noise.
    private func makeStrike() -> [Float] {
        let duration = 2.0
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        let chord: [Double] = [174.61, 220.0, 261.63] // F3, A3, C4
        var phases = [Double](repeating: 0, count: chord.count)
        var noiseState: UInt64 = 0x2545_F491_4F6C_DD1D
        var crowdLP: Float = 0
        var crowdLP2: Float = 0

        for i in 0 ..< count {
            let t = Double(i) / sampleRate

            // Horn envelope: fast attack, sustain, long release.
            let hornEnv: Double
            if t < 0.04 { hornEnv = t / 0.04 }
            else if t < 1.0 { hornEnv = 1.0 }
            else { hornEnv = exp(-(t - 1.0) / 0.35) }

            var horn: Double = 0
            for (index, base) in chord.enumerated() {
                let vibrato = 1.0 + 0.006 * sin(2.0 * .pi * (4.5 + Double(index)) * t)
                let detune = 1.0 + Double(index - 1) * 0.0015
                phases[index] += base * vibrato * detune / sampleRate
                let p = phases[index]
                // Brassy: fundamental + odd harmonics.
                horn += sin(2.0 * .pi * p)
                    + 0.45 * sin(2.0 * .pi * 3.0 * p)
                    + 0.18 * sin(2.0 * .pi * 5.0 * p)
            }
            horn *= hornEnv / Double(chord.count) * 0.5

            // Crowd: double-lowpassed noise swelling in and roaring through.
            noiseState = Self.nextRandom(noiseState)
            let white = Float(Int64(bitPattern: noiseState % 2000) - 1000) / 1000.0
            crowdLP += 0.12 * (white - crowdLP)
            crowdLP2 += 0.25 * (crowdLP - crowdLP2)
            let swell: Double
            if t < 0.35 { swell = t / 0.35 }
            else if t < 1.4 { swell = 1.0 }
            else { swell = max(0.0, 1.0 - (t - 1.4) / 0.6) }
            let crowd = Double(crowdLP2) * swell * 1.6

            samples[i] = Float((horn + crowd) * 0.85)
        }
        return samples
    }

    private static func nextRandom(_ state: UInt64) -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        return x
    }
}

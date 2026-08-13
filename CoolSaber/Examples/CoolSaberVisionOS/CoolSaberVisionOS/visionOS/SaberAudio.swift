//
//  SaberAudio.swift  (visionOS)
//  CoolSaber
//
//  Saber sound design with zero asset files: every sample bank is synthesized
//  at startup (hum loop, ignite/retract sweeps, three clash variants) and
//  mixed in a single AVAudioSourceNode render callback. Deliberately NO
//  AVAudioPlayerNode and NO scheduleBuffer: on visionOS the engine can report
//  started before audio IO cycles, and player.play() then throws the
//  uncatchable "player did not see an IO cycle" NSException. A source node
//  only renders when IO actually runs, so that failure mode cannot exist.
//
//  Threading: the XR game thread writes lock-guarded targets; the audio
//  render callback smooths toward them per sample (no zipper). Engine
//  start/stop happens on a private serial queue with retry, because session
//  activation can lag the immersive space opening.
//

import AVFAudio
import CoolSaber
import Foundation

final class SaberAudio: @unchecked Sendable {
    private struct HumVoice {
        var targetVolume: Float = 0
        var currentVolume: Float = 0
        var targetRate: Float = 1
        var currentRate: Float = 1
        var phase: Float = 0 // fractional sample index into the hum loop
    }

    private struct OneShot {
        var bank: Int // index into sampleBanks
        var position: Int = 0
        var volume: Float
    }

    private enum Bank {
        static let ignite = 0
        static let retract = 1
        static let clashFirst = 2 // 2, 3, 4
        static let clashCount = 3
    }

    private let queue = DispatchQueue(label: "com.miolabs.coolsaber.audio")
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double = 48000

    // Immutable after synthesis.
    private var humLoop: [Float] = []
    private var sampleBanks: [[Float]] = []

    private let stateLock = NSLock()
    private var voices = [HumVoice](repeating: HumVoice(), count: 4)
    private var oneShots: [OneShot] = []
    private var randomState: UInt64 = 0x243F_6A88_85A3_08D3

    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var retryTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var renderInvocations = 0
    private var watchdogLastSeen = -1

    // MARK: - Public API (safe from the XR game thread)

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
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

    /// Per-blade hum: volume tracks ignition, pitch tracks how fast the tip moves.
    func setHum(slot: Int, ignited: Bool, tipSpeed: Float) {
        guard (0 ..< 4).contains(slot) else { return }
        let speed = min(max(tipSpeed, 0), 6)
        let volume: Float = ignited ? 0.22 + speed * 0.05 : 0
        let rate = pow(2, speed * 90 / 1200) // cents → playback-rate multiplier
        stateLock.withLock {
            voices[slot].targetVolume = volume
            voices[slot].targetRate = rate
        }
    }

    func playIgnite() {
        enqueueOneShot(bank: Bank.ignite, volume: 0.7)
    }

    func playRetract() {
        enqueueOneShot(bank: Bank.retract, volume: 0.7)
    }

    func playClash(intensity: Float) {
        let volume = min(max(intensity / 8, 0.4), 1)
        let variant = stateLock.withLock { Int(Self.nextRandom(&randomState) % UInt64(Bank.clashCount)) }
        enqueueOneShot(bank: Bank.clashFirst + variant, volume: volume)
    }

    private func enqueueOneShot(bank: Int, volume: Float) {
        stateLock.withLock {
            guard bank < sampleBanks.count, !sampleBanks[bank].isEmpty else { return }
            if oneShots.count < 12 {
                oneShots.append(OneShot(bank: bank, volume: volume))
            }
        }
    }

    // MARK: - Engine lifecycle (on `queue`)

    private func startOnQueue() {
        guard !started else { return }

        if humLoop.isEmpty {
            humLoop = makeHumLoop()
            sampleBanks = [
                makeSweep(from: 60, to: 220),
                makeSweep(from: 220, to: 60),
                makeClash(seed: 17),
                makeClash(seed: 7919),
                makeClash(seed: 104_729),
            ]
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
        // activation during the transition "succeeds" with a dead proxy
        // ("Session lookup failed", silent output).
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startEngineWithRetry()
        }
        startWatchdog()
    }

    /// Session activation can lag the immersive space opening; keep trying
    /// instead of failing silently (or worse, throwing).
    private func startEngineWithRetry() {
        do {
            // Activation errors are retryable, not ignorable — a swallowed
            // failure here means permanent silence.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
            started = true
            retryTimer?.cancel()
            retryTimer = nil
            print("CoolSaber: audio engine running")
        } catch {
            print("CoolSaber: audio engine start failed (\(error)) — retrying")
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
                print("CoolSaber: audio IO stalled — restarting engine")
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

        let loopCount = Float(humLoop.count)
        // ~40 ms exponential smoothing per sample step.
        let smoothing: Float = 0.0005

        for frame in 0 ..< frames {
            var value: Float = 0

            if !humLoop.isEmpty {
                for index in 0 ..< voices.count {
                    voices[index].currentVolume += (voices[index].targetVolume - voices[index].currentVolume) * smoothing
                    voices[index].currentRate += (voices[index].targetRate - voices[index].currentRate) * smoothing
                    guard voices[index].currentVolume > 0.0005 else { continue }
                    voices[index].phase += voices[index].currentRate
                    if voices[index].phase >= loopCount { voices[index].phase -= loopCount }
                    value += humLoop[Int(voices[index].phase)] * voices[index].currentVolume
                }
            }

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

        // Mirror mono into any additional buffers the engine hands us.
        for buffer in buffers.dropFirst() {
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                data.update(from: out, count: frames)
            }
        }
    }

    // MARK: - DSP (all pure, run once at startup)

    /// 1 s seamless hum loop: two detuned low tones with odd harmonics and a
    /// slow amplitude wobble. All component frequencies are integer Hz, so the
    /// loop is phase-continuous.
    private func makeHumLoop() -> [Float] {
        let frames = Int(sampleRate)
        var samples = [Float](repeating: 0, count: frames)
        let twoPi = 2 * Float.pi
        for frame in 0 ..< frames {
            let t = Float(frame) / Float(sampleRate)
            var value: Float = 0
            for (base, weight) in [(Float(85), Float(1.0)), (Float(113), Float(0.7))] {
                value += weight * sin(twoPi * base * t)
                value += weight * 0.35 * sin(twoPi * base * 3 * t)
                value += weight * 0.15 * sin(twoPi * base * 5 * t)
            }
            let wobble = 1 + 0.15 * sin(twoPi * 6 * t)
            samples[frame] = value * wobble * 0.18
        }
        return samples
    }

    /// 0.4 s exponential frequency sweep plus a noise swish, for ignite/retract.
    private func makeSweep(from: Float, to: Float) -> [Float] {
        let duration: Float = 0.4
        let frames = Int(Float(sampleRate) * duration)
        var samples = [Float](repeating: 0, count: frames)
        let twoPi = 2 * Float.pi
        var phase: Float = 0
        var noiseState: UInt64 = 0x9E37_79B9_7F4A_7C15
        for frame in 0 ..< frames {
            let t = Float(frame) / Float(frames)
            let frequency = from * pow(to / from, t)
            phase += twoPi * frequency / Float(sampleRate)
            let envelope = sin(Float.pi * t)
            let noise = Self.nextNoise(&noiseState) * 0.25 * envelope * envelope
            samples[frame] = (sin(phase) * 0.6 + noise) * envelope * 0.8
        }
        return samples
    }

    /// 0.3 s clash: white-noise burst with instant attack, fast decay, a low
    /// thump, and a couple of crackle ticks. Seed varies the crackle placement.
    private func makeClash(seed: UInt64) -> [Float] {
        let duration: Float = 0.3
        let frames = Int(Float(sampleRate) * duration)
        var samples = [Float](repeating: 0, count: frames)
        let twoPi = 2 * Float.pi
        var noiseState = seed
        var tickState = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let tickTimes: [Float] = (0 ..< 3).map { _ in
            0.02 + Self.nextNoise(&tickState) * 0.04 + 0.06
        }
        for frame in 0 ..< frames {
            let t = Float(frame) / Float(sampleRate)
            let decay = exp(-t * 18)
            var value = Self.nextNoise(&noiseState) * decay * 0.9
            value += sin(twoPi * 150 * t) * exp(-t * 25) * 0.7
            for tick in tickTimes {
                let dt = t - tick
                if dt > 0, dt < 0.01 {
                    value += Self.nextNoise(&noiseState) * exp(-dt * 900) * 0.5
                }
            }
            samples[frame] = value * 0.85
        }
        return samples
    }

    /// Cheap deterministic white noise in [-1, 1] (xorshift64*).
    private static func nextNoise(_ state: inout UInt64) -> Float {
        Float(Int64(bitPattern: nextRandom(&state))) / Float(Int64.max)
    }

    private static func nextRandom(_ state: inout UInt64) -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}

//
//  MocapRecording.swift
//  CoolMirrorMocap
//
//  Raw capture recordings: the frames exactly as the iPhone produced them,
//  in the wire form, one after another in a file, and between them what
//  the headset knew at every frame it rendered (its head and hands, see
//  `MocapHeadsetSample`). A recording taken while a problem shows on the
//  headset can be replayed through the filters on a Mac, measured, and
//  turned into a regression test.
//

import Foundation
import simd

public enum MocapRecording {
    /// File magic, "CMR1"; then records, each a little-endian 32-bit
    /// length and a frame's wire form, a marker ("CMRK", the time as a
    /// double, a UTF-8 label: what the wearer was asked to do from then
    /// on) or a headset sample ("CMRH"). A reader skips the records it
    /// does not know.
    public static let magic: UInt32 = 0x3152_4D43
    public static let markerMagic: UInt32 = 0x4B52_4D43
    public static let fileExtension = "cmr"

    public struct Marker: Equatable, Sendable {
        public var time: Double
        public var label: String

        public init(time: Double, label: String) {
            self.time = time
            self.label = label
        }
    }

    public static func read(url: URL) throws -> [MocapFrame] {
        try readAll(url: url).frames
    }

    public static func readAll(url: URL) throws -> (frames: [MocapFrame], markers: [Marker], headset: [MocapHeadsetSample]) {
        let data = try Data(contentsOf: url)
        return records(in: data)
    }

    public static func frames(in data: Data) -> [MocapFrame] {
        records(in: data).frames
    }

    public static func records(in data: Data) -> (frames: [MocapFrame], markers: [Marker], headset: [MocapHeadsetSample]) {
        var cursor = data.startIndex
        func read32() -> UInt32? {
            guard cursor + 4 <= data.endIndex else { return nil }
            let value = data[cursor ..< cursor + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            cursor += 4
            return UInt32(littleEndian: value)
        }
        guard read32() == magic else { return ([], [], []) }
        var frames: [MocapFrame] = []
        var markers: [Marker] = []
        var headset: [MocapHeadsetSample] = []
        while let length = read32(), length > 0, cursor + Int(length) <= data.endIndex {
            let record = data[cursor ..< cursor + Int(length)]
            if let frame = MocapFrame(data: record) {
                frames.append(frame)
            } else if let marker = marker(in: record) {
                markers.append(marker)
            } else if let sample = MocapHeadsetSample(data: record) {
                headset.append(sample)
            }
            cursor += Int(length)
        }
        return (frames, markers, headset)
    }

    static func markerData(_ marker: Marker) -> Data {
        var data = Data()
        var magic = markerMagic.littleEndian
        data.append(Data(bytes: &magic, count: 4))
        var time = marker.time.bitPattern.littleEndian
        data.append(Data(bytes: &time, count: 8))
        data.append(Data(marker.label.utf8))
        return data
    }

    static func marker(in record: Data) -> Marker? {
        guard record.count >= 12 else { return nil }
        let start = record.startIndex
        let magic = UInt32(littleEndian: record[start ..< start + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard magic == markerMagic else { return nil }
        let bits = UInt64(littleEndian: record[start + 4 ..< start + 12].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        return Marker(time: Double(bitPattern: bits), label: String(decoding: record[(start + 12)...], as: UTF8.self))
    }

    /// How the raw skeleton moves from frame to frame: what a jump on the
    /// headset looks like at the source. Per frame, the root's travel and
    /// turn and the largest travel of any joint relative to the root; the
    /// summary names the frames that moved most.
    /// With markers, the report is given per marked stretch as well; with
    /// headset samples, what the headset saw in each.
    public static func report(_ frames: [MocapFrame], markers: [Marker], headset: [MocapHeadsetSample] = [], worst: Int = 6) -> String {
        var lines = ["whole recording:", report(frames, worst: worst)]
        if !headset.isEmpty {
            lines.append(report(headset: headset))
        }
        let sorted = markers.sorted { $0.time < $1.time }
        for (index, marker) in sorted.enumerated() {
            let end = index + 1 < sorted.count ? sorted[index + 1].time : .infinity
            let stretch = frames.filter { $0.timestamp >= marker.time && $0.timestamp < end }
            lines.append("")
            lines.append("\(marker.label):")
            lines.append(report(stretch, worst: worst))
            let samples = Self.headset(headset, from: marker.time, to: end)
            if !samples.isEmpty {
                lines.append(report(headset: samples))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The samples taken while the mirror showed the phone's frames of a
    /// stretch (times on the phone's clock, as the markers').
    public static func headset(_ samples: [MocapHeadsetSample], from start: Double, to end: Double) -> [MocapHeadsetSample] {
        samples.filter { sample in
            guard let time = sample.frameTime else { return false }
            return time >= start && time < end
        }
    }

    /// What the headset saw: how often, how far the head went, and for
    /// each hand how much of the time it was seen and how often it was
    /// lost.
    public static func report(headset samples: [MocapHeadsetSample]) -> String {
        guard samples.count > 1, let first = samples.first, let last = samples.last else { return "headset: \(samples.count) sample(s)" }
        let duration = max(last.time - first.time, 1e-3)
        var lines = [String(format: "headset: %d samples over %.1f s (%.0f/s), %d without the head", samples.count, duration, Double(samples.count - 1) / duration, samples.filter { $0.head == nil }.count)]
        let heads = samples.compactMap(\.head?.position)
        if let start = heads.first {
            var low = start, high = start
            var largest: Float = 0
            for (a, b) in zip(heads, heads.dropFirst()) {
                low = simd_min(low, b)
                high = simd_max(high, b)
                largest = max(largest, simd_distance(a, b))
            }
            let range = high - low
            lines.append(String(format: "  head: range %.0f × %.0f × %.0f mm (x, y, z), largest step %.1f mm", range.x * 1000, range.y * 1000, range.z * 1000, largest * 1000))
        }
        for side in MocapHandSide.allCases {
            let states = samples.map { $0.hands[side]?.isTracked ?? false }
            let seen = states.filter { $0 }.count
            var losses = 0
            for (was, now) in zip(states, states.dropFirst()) where was && !now {
                losses += 1
            }
            lines.append(String(format: "  %@ hand: seen %.0f%% of the time, lost %d time(s)", side == .left ? "left" : "right", 100 * Double(seen) / Double(states.count), losses))
        }
        return lines.joined(separator: "\n")
    }

    public static func report(_ frames: [MocapFrame], worst: Int = 12) -> String {
        guard frames.count > 1 else { return "\(frames.count) frame(s)" }
        struct Step {
            var index: Int
            var time: Double
            var root: Float
            var yaw: Float
            var joint: Float
            var jointName: String
        }
        var steps: [Step] = []
        let first = frames[0].timestamp
        for index in 1 ..< frames.count {
            let a = frames[index - 1], b = frames[index]
            let root = simd_length(b.rootPosition - a.rootPosition)
            let yaw = abs(Self.yaw(b.rotations[.root]) - Self.yaw(a.rotations[.root])) * 180 / .pi
            var joint: Float = 0
            var jointName = "-"
            for (name, p) in b.positions {
                guard let q = a.positions[name] else { continue }
                let d = simd_length(p - q)
                if d > joint {
                    joint = d
                    jointName = "\(name)"
                }
            }
            steps.append(Step(index: index, time: b.timestamp - first, root: root, yaw: min(yaw, 360 - yaw), joint: joint, jointName: jointName))
        }
        func percentile(_ values: [Float], _ f: Float) -> Float {
            let s = values.sorted()
            return s.isEmpty ? 0 : s[min(s.count - 1, Int(Float(s.count - 1) * f))]
        }
        let duration = frames.last!.timestamp - first
        var lines: [String] = []
        lines.append(String(format: "%d frames over %.1f s (%.0f/s), %d untracked", frames.count, duration, Double(frames.count - 1) / max(duration, 1e-3), frames.filter { !$0.isTracked }.count))
        lines.append(String(format: "root travel per frame: median %.1f mm, p95 %.1f mm, max %.1f mm", percentile(steps.map(\.root), 0.5) * 1000, percentile(steps.map(\.root), 0.95) * 1000, (steps.map(\.root).max() ?? 0) * 1000))
        lines.append(String(format: "root turn per frame: median %.2f°, p95 %.2f°, max %.2f°", percentile(steps.map(\.yaw), 0.5), percentile(steps.map(\.yaw), 0.95), steps.map(\.yaw).max() ?? 0))
        lines.append(String(format: "largest joint travel per frame (relative to the root): median %.1f mm, p95 %.1f mm, max %.1f mm", percentile(steps.map(\.joint), 0.5) * 1000, percentile(steps.map(\.joint), 0.95) * 1000, (steps.map(\.joint).max() ?? 0) * 1000))
        lines.append("worst root moves:")
        for step in steps.sorted(by: { $0.root > $1.root }).prefix(worst) {
            lines.append(String(format: "  frame %d at %.2f s: root %.1f mm, turn %.1f°, %@ %.1f mm", step.index, step.time, step.root * 1000, step.yaw, step.jointName, step.joint * 1000))
        }
        lines.append("worst root turns:")
        for step in steps.sorted(by: { $0.yaw > $1.yaw }).prefix(worst) {
            lines.append(String(format: "  frame %d at %.2f s: turn %.1f°, root %.1f mm, %@ %.1f mm", step.index, step.time, step.yaw, step.root * 1000, step.jointName, step.joint * 1000))
        }
        return lines.joined(separator: "\n")
    }

    static func yaw(_ rotation: simd_quatf?) -> Float {
        guard let rotation else { return 0 }
        let forward = rotation.act(simd_float3(0, 0, 1))
        return atan2(forward.x, forward.z)
    }
}

/// Appends frames to a recording file as they arrive.
public final class MocapRecordingWriter: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var count = 0
    private var headsetCount = 0

    public var frameCount: Int {
        lock.withLock { count }
    }

    public var headsetSampleCount: Int {
        lock.withLock { headsetCount }
    }

    public init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        var magic = MocapRecording.magic.littleEndian
        handle.write(Data(bytes: &magic, count: 4))
    }

    public func append(_ frame: MocapFrame) {
        write(frame.encode())
        lock.withLock { count += 1 }
    }

    public func append(_ sample: MocapHeadsetSample) {
        write(sample.encode())
        lock.withLock { headsetCount += 1 }
    }

    /// Notes what the wearer does from `time` on (the frames' clock).
    public func mark(_ label: String, at time: Double) {
        write(MocapRecording.markerData(.init(time: time, label: label)))
    }

    private func write(_ payload: Data) {
        var length = UInt32(payload.count).littleEndian
        lock.withLock {
            handle.write(Data(bytes: &length, count: 4))
            handle.write(payload)
        }
    }

    public func close() {
        lock.withLock { try? handle.close() }
    }
}

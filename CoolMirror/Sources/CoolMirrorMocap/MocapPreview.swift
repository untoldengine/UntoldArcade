//
//  MocapPreview.swift
//  CoolMirrorMocap
//
//  A small camera picture with the tracked joints drawn in it, sent a few
//  times a second so the person wearing the headset can see whether the
//  phone frames their whole body (its screen faces away from them).
//

import Foundation
import simd

public struct MocapPreviewFrame: Sendable, Equatable {
    public static let chunkMagic: UInt32 = 0x3156_4D43 // "CMV1"
    public static let chunkHeaderSize = 16
    /// Payload bytes per datagram, under the usual Wi-Fi MTU.
    public static let chunkPayloadSize = 1200

    public var id: UInt32
    public var width: UInt16
    public var height: UInt16
    public var jpeg: Data
    /// Joint positions in image pixels, same orientation as the picture.
    public var keypoints: [MocapJoint: SIMD2<Float>]

    public init(id: UInt32, width: UInt16, height: UInt16, jpeg: Data, keypoints: [MocapJoint: SIMD2<Float>]) {
        self.id = id
        self.width = width
        self.height = height
        self.jpeg = jpeg
        self.keypoints = keypoints
    }

    // MARK: - Wire form: keypoints block + JPEG, split into numbered chunks

    /// Chunk: magic, id, index (16 bit), count (16 bit), width, height, then
    /// a slice of the body; the body is a keypoint count (16 bit), the
    /// keypoints (joint 16 bit, x, y) and the JPEG bytes.
    public func chunks() -> [Data] {
        var body = Data()
        appendUInt16(&body, UInt16(keypoints.count))
        for (joint, point) in keypoints.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            appendUInt16(&body, joint.rawValue)
            appendUInt32(&body, point.x.bitPattern)
            appendUInt32(&body, point.y.bitPattern)
        }
        body.append(jpeg)

        let count = max(1, (body.count + Self.chunkPayloadSize - 1) / Self.chunkPayloadSize)
        var chunks: [Data] = []
        chunks.reserveCapacity(count)
        for index in 0 ..< count {
            var chunk = Data()
            chunk.reserveCapacity(Self.chunkHeaderSize + Self.chunkPayloadSize)
            appendUInt32(&chunk, Self.chunkMagic)
            appendUInt32(&chunk, id)
            appendUInt16(&chunk, UInt16(index))
            appendUInt16(&chunk, UInt16(count))
            appendUInt16(&chunk, width)
            appendUInt16(&chunk, height)
            let start = body.startIndex + index * Self.chunkPayloadSize
            let end = min(start + Self.chunkPayloadSize, body.endIndex)
            chunk.append(body[start ..< end])
            chunks.append(chunk)
        }
        return chunks
    }

    /// Whether `data` is a preview chunk (by its magic).
    public static func isChunk(_ data: Data) -> Bool {
        data.count >= chunkHeaderSize && readUInt32(data, at: data.startIndex) == chunkMagic
    }

    struct ChunkHeader {
        var id: UInt32
        var index: Int
        var count: Int
        var width: UInt16
        var height: UInt16
        var payload: Data
    }

    static func header(of data: Data) -> ChunkHeader? {
        guard isChunk(data) else { return nil }
        let base = data.startIndex
        let index = Int(readUInt16(data, at: base + 8))
        let count = Int(readUInt16(data, at: base + 10))
        guard count > 0, index < count else { return nil }
        return ChunkHeader(
            id: readUInt32(data, at: base + 4), index: index, count: count,
            width: readUInt16(data, at: base + 12), height: readUInt16(data, at: base + 14),
            payload: data[(base + chunkHeaderSize)...]
        )
    }

    static func decode(body: Data, id: UInt32, width: UInt16, height: UInt16) -> MocapPreviewFrame? {
        var cursor = body.startIndex
        guard cursor + 2 <= body.endIndex else { return nil }
        let count = Int(readUInt16(body, at: cursor))
        cursor += 2
        var keypoints: [MocapJoint: SIMD2<Float>] = [:]
        for _ in 0 ..< count {
            guard cursor + 10 <= body.endIndex else { return nil }
            let joint = MocapJoint(rawValue: readUInt16(body, at: cursor))
            let x = Float(bitPattern: readUInt32(body, at: cursor + 2))
            let y = Float(bitPattern: readUInt32(body, at: cursor + 6))
            cursor += 10
            if let joint {
                keypoints[joint] = SIMD2(x, y)
            }
        }
        return MocapPreviewFrame(id: id, width: width, height: height, jpeg: Data(body[cursor...]), keypoints: keypoints)
    }
}

/// Reassembles chunks into frames; keeps only the newest frame in flight.
public struct MocapPreviewAssembler: Sendable {
    private var id: UInt32?
    private var parts: [Int: Data] = [:]
    private var count = 0
    private var width: UInt16 = 0
    private var height: UInt16 = 0

    public init() {}

    /// The completed frame when `data` was its last missing chunk.
    public mutating func add(_ data: Data) -> MocapPreviewFrame? {
        guard let header = MocapPreviewFrame.header(of: data) else { return nil }
        if header.id != id {
            // A newer frame supersedes whatever was in flight (ids wrap
            // eventually; a much smaller id is treated as newer too).
            if let id, header.id < id, id - header.id < UInt32.max / 2 { return nil }
            id = header.id
            parts.removeAll()
            count = header.count
            width = header.width
            height = header.height
        }
        parts[header.index] = header.payload
        guard parts.count == count else { return nil }
        var body = Data()
        for index in 0 ..< count {
            guard let part = parts[index] else { return nil }
            body.append(part)
        }
        parts.removeAll()
        return MocapPreviewFrame.decode(body: body, id: header.id, width: width, height: height)
    }
}

private func appendUInt16(_ data: inout Data, _ value: UInt16) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func appendUInt32(_ data: inout Data, _ value: UInt32) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(littleEndian: data[offset ..< offset + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(littleEndian: data[offset ..< offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
}

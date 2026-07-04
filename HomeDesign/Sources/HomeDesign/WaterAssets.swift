//
//  WaterAssets.swift
//  HomeDesign
//
//  Texture loading for the CoolWater pool (tiles + skybox cubemap). Ported from
//  CoolWater's own example app (DemoAssets.swift) — the render extension itself has
//  no asset pipeline of its own, callers load textures however suits them and hand
//  MTLTextures to setCoolWaterTilesTexture/setCoolWaterSkyTexture.
//

import Foundation
import ImageIO
import CoreGraphics
import Metal
import MetalKit
import UntoldEngine

enum WaterAssets {

    /// Loads a 2D texture (e.g. the pool tiles) from GameData/Water.
    static func loadTexture(device: MTLDevice, name: String, ext: String, srgb: Bool, mipmapped: Bool) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "GameData/Water") else {
            Logger.log(message: "⚠️ WaterAssets: missing texture \(name).\(ext)")
            return nil
        }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: srgb,
            .generateMipmaps: mipmapped,
            .textureUsage: NSNumber(value: MTLTextureUsage([.shaderRead]).rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        return try? loader.newTexture(URL: url, options: options)
    }

    /// Builds a cubemap from six face images in GameData/Water, mirroring the CoolWater
    /// example's face assignment (the +Y image is reused for -Y).
    static func loadCubemap(device: MTLDevice) -> MTLTexture? {
        // Metal cube slice order: +X, -X, +Y, -Y, +Z, -Z
        let faceNames = ["xpos", "xneg", "ypos", "ypos", "zpos", "zneg"]
        var faces = [(bytes: [UInt8], size: Int)]()
        for name in faceNames {
            guard let face = decodeRGBA(name: name, ext: "jpg") else {
                Logger.log(message: "⚠️ WaterAssets: missing cube face \(name).jpg")
                return nil
            }
            faces.append(face)
        }
        let size = faces[0].size
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba8Unorm_srgb, size: size, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytesPerRow = size * 4
        let bytesPerImage = bytesPerRow * size
        for (slice, face) in faces.enumerated() where face.size == size {
            face.bytes.withUnsafeBytes { raw in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, slice: slice,
                    withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage
                )
            }
        }
        return texture
    }

    /// Decodes a bundled image into tightly packed RGBA8 bytes (square assumed).
    private static func decodeRGBA(name: String, ext: String) -> (bytes: [UInt8], size: Int)? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "GameData/Water"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let size = min(image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &bytes, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: colorSpace, bitmapInfo: info
        ) else {
            return nil
        }
        // CGContext's origin is bottom-left, but Metal cube faces expect row 0 at the
        // top. Flip vertically so the decoded bytes match Metal's texture orientation
        // (otherwise the sky/water halves of the cube faces are swapped and reflections
        // sample the dark water instead of the bright sky).
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return (bytes, size)
    }
}

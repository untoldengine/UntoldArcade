// Generates CoolBowling textures: bowling ball (equirect, glossy dark with
// three finger holes), pin (white with two red bands along v), lane (maple
// boards with arrows). Run: swift make_bowling_textures.swift <outDir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func savePNG(_ image: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(name)")
}
func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// --- Ball: deep blue-black marble with swirls and three holes (equirect 1024x512).
do {
    let W = 1024, H = 512
    let c = context(W, H)
    c.setFillColor(CGColor(red: 0.06, green: 0.08, blue: 0.20, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    var rng: UInt64 = 0x1234_5678_9ABC_DEF1
    func rnd() -> Double { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Double(rng % 10000) / 10000 }
    for _ in 0 ..< 40 { // marble swirls
        let path = CGMutablePath()
        var x = rnd() * Double(W), y = rnd() * Double(H)
        path.move(to: CGPoint(x: x, y: y))
        for _ in 0 ..< 12 { x += (rnd() - 0.5) * 300; y += (rnd() - 0.5) * 120; path.addLine(to: CGPoint(x: x, y: y)) }
        c.setStrokeColor(CGColor(red: 0.35, green: 0.25, blue: 0.7, alpha: 0.18)); c.setLineWidth(CGFloat(6 + rnd() * 30)); c.setLineCap(.round)
        c.addPath(path); c.strokePath()
    }
    // Three finger holes near the "top" (v ~ 0.75), dark discs with a rim.
    for (u, v, r) in [(0.42, 0.78, 34.0), (0.58, 0.78, 34.0), (0.50, 0.62, 30.0)] {
        let x = u * Double(W), y = v * Double(H)
        c.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)); c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        c.setStrokeColor(CGColor(red: 0.5, green: 0.5, blue: 0.6, alpha: 0.5)); c.setLineWidth(3); c.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    savePNG(c.makeImage()!, "bowlingball_baseColor.png")
}

// --- Pin: white with two red bands (v = height fraction; the neck sits at v ≈ 0.72-0.84).
do {
    let W = 256, H = 1024
    let c = context(W, H)
    c.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    c.setFillColor(CGColor(red: 0.85, green: 0.12, blue: 0.10, alpha: 1))
    for (v0, v1) in [(0.66, 0.70), (0.74, 0.78)] {
        c.fill(CGRect(x: 0, y: Int(v0 * Double(H)), width: W, height: Int((v1 - v0) * Double(H))))
    }
    savePNG(c.makeImage()!, "pin_baseColor.png")
}

// --- Lane: maple boards (repeat along length), foul line at v = 0, arrows at v ≈ 0.25.
do {
    let W = 512, H = 2048
    let c = context(W, H)
    let boards = 39
    for b in 0 ..< boards {
        let t = 0.80 + Double(b % 5) * 0.03 + Double((b * 7) % 3) * 0.015
        c.setFillColor(CGColor(red: t, green: t * 0.82, blue: t * 0.58, alpha: 1))
        c.fill(CGRect(x: Int(Double(b) / Double(boards) * Double(W)), y: 0, width: Int(Double(W) / Double(boards)) + 1, height: H))
    }
    c.setStrokeColor(CGColor(red: 0.55, green: 0.42, blue: 0.25, alpha: 0.5)); c.setLineWidth(1)
    for b in 0 ... boards { let x = Double(b) / Double(boards) * Double(W); c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: Double(H))) }
    c.strokePath()
    // Foul line at the near end.
    c.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)); c.fill(CGRect(x: 0, y: 8, width: W, height: 6))
    // Arrows.
    c.setFillColor(CGColor(red: 0.2, green: 0.15, blue: 0.1, alpha: 0.85))
    for (i, u) in [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8].enumerated() {
        let x = u * Double(W), y = Double(H) * (0.22 + Double(abs(i - 3)) * 0.015)
        let p = CGMutablePath(); p.move(to: CGPoint(x: x, y: y + 40)); p.addLine(to: CGPoint(x: x - 12, y: y)); p.addLine(to: CGPoint(x: x + 12, y: y)); p.closeSubpath()
        c.addPath(p); c.fillPath()
    }
    savePNG(c.makeImage()!, "lane_baseColor.png")
}

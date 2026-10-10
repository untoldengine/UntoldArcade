//
//  main.swift
//  CoolMirrorBake
//
//  Bakes the ML deformer training set of a demo character on this Mac:
//  plays its clips through the engine's XPBD muscle simulation with the
//  demo's muscle rig and records the skin deltas. Then train with the
//  engine's scripts/train_mldeformer.py and drop the .untoldml next to the
//  model.
//
//  swift run CoolMirrorBake <spiderman|batman> <path/to/Assets> <output-base> [passes]
//

import CoolMirror
import Foundation
import UntoldEngine

let arguments = CommandLine.arguments
guard arguments.count >= 4,
      let character = CoolMirrorCharacter(rawValue: arguments[1])
else {
    FileHandle.standardError.write(Data("usage: CoolMirrorBake <spiderman|batman|redplayer> <Assets dir> <output base> [passes]\n".utf8))
    exit(2)
}
let assets = URL(fileURLWithPath: arguments[2])
let outputBase = URL(fileURLWithPath: arguments[3])
let passes = arguments.count > 4 ? Int(arguments[4]) ?? 6 : 6

guard let rig = CoolMirrorMuscles.rig(for: character) else {
    FileHandle.standardError.write(Data("\(character.rawValue) has no muscle rig\n".utf8))
    exit(1)
}

do {
    let loader = NativeFormatLoader()
    let modelURL = assets.appendingPathComponent("Models/\(character.rawValue)/\(character.rawValue).untold")
    let asset = try loader.loadAssetSync(from: modelURL)

    var clips: [RuntimeAnimationClip] = []
    for clip in character.clips where clip.ext == "untoldanim" {
        let url = assets.appendingPathComponent("Animations/\(clip.file)/\(clip.file).\(clip.ext)")
        clips.append(contentsOf: try loader.loadAssetSync(from: url).animationClips)
    }

    // The same rig as JSON, for the engine CLI (`untoldengine bake-mldeformer --muscles`).
    let rigURL = modelURL.deletingLastPathComponent().appendingPathComponent("\(character.rawValue).muscles.json")
    try rig.jsonData().write(to: rigURL)

    var options = MLDeformerBakeOptions()
    options.augmentationPasses = passes
    print("Baking \(character.rawValue): \(clips.count) clip(s), \(rig.muscles.count) muscles, \(passes) augmentation passes")
    let summary = try MLDeformerBaker.bake(asset: asset, clips: clips, rig: rig, options: options, outputBase: outputBase) { message in
        print("  \(message)")
    }
    print("Samples: \(summary.sampleCount), features: \(summary.featureCount), active vertices: \(summary.activeVertexCount), meshes: \(summary.meshNames.joined(separator: ", "))")
    print("Next: python3 scripts/train_mldeformer.py --dataset \(outputBase.path) --output \(modelURL.deletingPathExtension().path).untoldml")
} catch {
    FileHandle.standardError.write(Data("bake failed: \(error)\n".utf8))
    exit(1)
}

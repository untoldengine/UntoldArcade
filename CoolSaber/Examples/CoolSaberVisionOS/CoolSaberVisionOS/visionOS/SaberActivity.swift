//
//  SaberActivity.swift  (visionOS)
//  CoolSaber
//

import Foundation
import GroupActivities

/// The SharePlay activity for a two-player saber duel on a FaceTime call.
struct SaberActivity: GroupActivity {
    static let activityIdentifier = "com.miolabs.CoolSaberVisionOS.duel"

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "CoolSaber Duel"
        metadata.subtitle = "Two-player lightsaber battle"
        metadata.type = .generic
        return metadata
    }
}

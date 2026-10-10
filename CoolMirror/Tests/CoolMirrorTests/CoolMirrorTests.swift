//
//  CoolMirrorTests.swift
//  CoolMirrorTests
//

@testable import CoolMirror
import XCTest

final class CoolMirrorTests: XCTestCase {
    func testEveryCharacterListsItsClips() {
        for character in CoolMirrorCharacter.allCases {
            XCTAssertFalse(character.clips.isEmpty, "\(character) needs at least one clip")
        }
        XCTAssertEqual(CoolMirrorCharacter.redplayer.clips.map(\.name), ["idle", "running"])
    }

    func testHeroesHaveMuscleRigsAndMocapMappings() {
        for character in [CoolMirrorCharacter.spiderman, .batman] {
            XCTAssertNotNil(CoolMirrorMuscles.rig(for: character))
            XCTAssertNotNil(CoolMirrorMocapMapping.mapping(for: character))
        }
        XCTAssertNil(CoolMirrorMuscles.rig(for: .redplayer))
    }
}

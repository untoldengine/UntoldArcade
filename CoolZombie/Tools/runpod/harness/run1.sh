#!/usr/bin/env bash
# run1.sh ENV=VAL ... : one harness run from the built xctest bundle; prints the summary line.
cd "${ENGINE_DIR:?set ENGINE_DIR to the engine worktree that has the harness built}" || exit 1
env -u TOOLCHAINS "$@" xcrun --toolchain XcodeDefault xctest -XCTest UntoldEngineRenderTests.ZombieClipSetScratchTest/test_clipSetChase .build/debug/UntoldEnginePackageTests.xctest 2>&1 | grep -a "^CS SUMMARY\|error:\|Fatal" | sed 's/^CS SUMMARY //'

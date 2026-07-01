#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
shader_dir="$package_root/Sources/CoolWater/Shaders"
resource_dir="$package_root/Sources/CoolWater/Resources"
source_file="$shader_dir/CoolWater.metal"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/CoolWater.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

build_library() {
    sdk=$1
    output_name=$2
    sdk_work_dir="$work_dir/$sdk"
    mkdir -p "$sdk_work_dir"

    xcrun -sdk "$sdk" metal \
        -c "$source_file" \
        -I "$shader_dir" \
        -fmodules-cache-path="$sdk_work_dir/ModuleCache" \
        -o "$sdk_work_dir/CoolWater.air"

    xcrun -sdk "$sdk" metallib \
        "$sdk_work_dir/CoolWater.air" \
        -o "$resource_dir/$output_name"
}

mkdir -p "$resource_dir"

build_library macosx CoolWater-macos.metallib
build_library iphoneos CoolWater-ios.metallib
build_library iphonesimulator CoolWater-iossim.metallib
build_library xros CoolWater-xros.metallib
build_library xrsimulator CoolWater-xrossim.metallib

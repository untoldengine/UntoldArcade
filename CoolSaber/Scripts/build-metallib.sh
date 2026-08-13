#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
shader_dir="$package_root/Sources/CoolSaber/Shaders"
resource_dir="$package_root/Sources/CoolSaber/Resources"
source_file="$shader_dir/CoolSaber.metal"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/CoolSaber.XXXXXX")
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
        -o "$sdk_work_dir/CoolSaber.air"

    xcrun -sdk "$sdk" metallib \
        "$sdk_work_dir/CoolSaber.air" \
        -o "$resource_dir/$output_name"
}

mkdir -p "$resource_dir"

build_library macosx CoolSaber-macos.metallib
build_library iphoneos CoolSaber-ios.metallib
build_library iphonesimulator CoolSaber-iossim.metallib
build_library xros CoolSaber-xros.metallib
build_library xrsimulator CoolSaber-xrossim.metallib

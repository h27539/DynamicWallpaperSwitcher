#!/bin/sh
set -eu

# The App's main executable is built by Xcode for ARCHS_STANDARD. This helper is
# compiled separately, so explicitly emit both macOS slices before signing.
helper_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
source_file="${SRCROOT}/Sources/TemporalSampleWriterPOC/main.swift"
staging="${TARGET_TEMP_DIR}/AerialMediaHelper-universal"
mkdir -p "$helper_dir" "$staging"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
for architecture in x86_64 arm64; do
    xcrun swiftc -O -sdk "$sdk_path" \
        -target "${architecture}-apple-macos${MACOSX_DEPLOYMENT_TARGET}" \
        "$source_file" -o "$staging/AerialMediaHelper-$architecture"
done
xcrun lipo -create \
    "$staging/AerialMediaHelper-x86_64" \
    "$staging/AerialMediaHelper-arm64" \
    -output "$helper_dir/AerialMediaHelper"
xcrun lipo "$helper_dir/AerialMediaHelper" -verify_arch x86_64 arm64

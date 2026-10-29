#!/bin/bash
# Builds a universal (Apple Silicon and Intel) Release of Cleanori, ad-hoc signed, and zips it for a GitHub release
# and the Homebrew cask. Prints the zip's path and SHA-256.
# Run from anywhere: scripts/make-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(awk -F'"' '/MARKETING_VERSION/ { print $2 }' project.yml)
data=build/ReleaseData
out=build/release
app=$data/Build/Products/Release/Cleanori.app
zip=$out/Cleanori-$version.zip

xcodegen generate --quiet
xcodebuild -project Cleanori.xcodeproj -scheme Cleanori -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$data" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet clean build

archs=$(lipo -archs "$app/Contents/MacOS/Cleanori")
[[ $archs == *arm64* && $archs == *x86_64* ]] || { echo "expected arm64 and x86_64, got: $archs" >&2; exit 1; }
codesign --verify --deep --strict "$app"

rm -rf "$out"
mkdir -p "$out"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip ($archs)"
shasum -a 256 "$zip"

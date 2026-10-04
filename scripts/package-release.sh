#!/bin/bash
set -euo pipefail

# Run from the repository root. No signing credentials are needed.
arch="${ARCH:-$(uname -m)}"
case "$arch" in
  arm64|x86_64) ;;
  *) echo 'ARCH must be arm64 or x86_64.' >&2; exit 1 ;;
esac
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Config/App-Info.plist)"
if [[ -n "${RELEASE_TAG:-}" ]]; then
  if [[ ! "$RELEASE_TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo 'Release tags must use vMAJOR.MINOR.PATCH (for example v0.1.0).' >&2
    exit 1
  fi
  version="${BASH_REMATCH[1]}"
fi
build_number="${BUILD_NUMBER:-1}"
if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
  echo 'BUILD_NUMBER must be a non-negative integer.' >&2
  exit 1
fi

xcodegen generate
xcodebuild \
  -project MacAIUsage.xcodeproj -scheme MacAIUsage -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "build/ci-$arch" \
  ARCHS="$arch" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

app="build/ci-$arch/Build/Products/Release/MacAIUsage.app"
widget="$app/Contents/PlugIns/UsageWidget.appex"
for bundle in "$app" "$widget"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$bundle/Contents/Info.plist"
done

test "$(lipo -archs "$app/Contents/MacOS/MacAIUsage")" = "$arch"
test "$(lipo -archs "$widget/Contents/MacOS/UsageWidget")" = "$arch"
# Sign nested bundles first, preserving each target's entitlements.
codesign --force --sign - --options runtime --entitlements Config/Widget.entitlements "$widget"
codesign --force --sign - --options runtime --entitlements Config/App.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"

mkdir -p build/release
archive="MacAIUsage-${version}-${arch}.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "build/release/$archive"
(
  cd build/release
  shasum -a 256 "$archive" > "$archive.sha256"
)

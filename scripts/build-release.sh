#!/usr/bin/env bash
#
# Builds a universal (Apple Silicon + Intel) MoodPlay.app and packages it
# into a drag-to-install DMG under build/.
#
#   ./scripts/build-release.sh
#
# Signing: ad-hoc by default. Set SIGN_IDENTITY to a "Developer ID Application"
# identity to produce a build that can be notarized.
set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUILD_DIR="build"
DERIVED="$BUILD_DIR/DerivedData"
APP="$DERIVED/Build/Products/Release/MoodPlay.app"
ENTITLEMENTS="MoodPlay/MoodPlay.entitlements"

VERSION=$(xcodebuild -project MoodPlay.xcodeproj -scheme MoodPlay -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION = / { print $2; exit }')
DMG="$BUILD_DIR/MoodPlay-$VERSION.dmg"

echo "▸ Building MoodPlay $VERSION (universal)…"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project MoodPlay.xcodeproj \
  -scheme MoodPlay \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  build -quiet

echo "▸ Signing with hardened runtime ($SIGN_IDENTITY)…"
codesign --force --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=1 "$APP"
lipo -info "$APP/Contents/MacOS/MoodPlay"

echo "▸ Packaging DMG…"
STAGE="$BUILD_DIR/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "MoodPlay $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov "$DMG" >/dev/null
rm -rf "$STAGE"

(cd "$BUILD_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "✓ $DMG"
cat "$DMG.sha256"

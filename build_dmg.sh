#!/bin/bash
set -euo pipefail

PROJECT="ClaudeIsland.xcodeproj"
SCHEME="ClaudeIsland"
APP_NAME="Coding Island"
VERSION=$(xcodebuild -project "$PROJECT" -showBuildSettings 2>/dev/null | grep MARKETING_VERSION | head -1 | awk '{print $3}')
BUILD_NUMBER=$(xcodebuild -project "$PROJECT" -showBuildSettings 2>/dev/null | grep CURRENT_PROJECT_VERSION | head -1 | awk '{print $3}')
DMG_NAME="ClaudeIsland-${VERSION}-${BUILD_NUMBER}-Release.dmg"
BUILD_DIR="build_release"
DMG_STAGE_DIR="$BUILD_DIR/dmg_stage"

echo "==> Building ${APP_NAME} v${VERSION} (${BUILD_NUMBER})"

# Clean old build
rm -rf "$BUILD_DIR"

# Build Release (skip code signing, use -Onone to avoid Swift compiler crash on beta Xcode)
echo "==> Compiling..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_OPTIMIZATION_LEVEL="-Onone" \
  EXPLICIT_MODULE_BUILD=NO \
  | tail -1

APP_PATH="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Build failed, app not found at $APP_PATH"
  exit 1
fi

rm -rf "$DMG_STAGE_DIR"
mkdir -p "$DMG_STAGE_DIR"
cp -R "$APP_PATH" "$DMG_STAGE_DIR/"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

# Remove old DMG
rm -f "$DMG_NAME"

# Create DMG
echo "==> Creating DMG..."
hdiutil create \
  -volname "ClaudeIsland" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_NAME"

rm -rf "$DMG_STAGE_DIR"

SIZE=$(ls -lh "$DMG_NAME" | awk '{print $5}')
echo ""
echo "==> Done! ${DMG_NAME} (${SIZE})"

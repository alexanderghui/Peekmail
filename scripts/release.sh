#!/bin/bash
set -euo pipefail

# Peekmail Release Script
# Builds, signs, notarizes, and packages Peekmail for distribution

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="Peekmail"
ARCHIVE_PATH="$PROJECT_DIR/build/Peekmail.xcarchive"
EXPORT_DIR="$PROJECT_DIR/build/Release"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"
DERIVED_DATA_PATH="$PROJECT_DIR/build/DerivedData"
APPCAST_STAGING_DIR="$PROJECT_DIR/build/appcast-staging"
GENERATE_APPCAST="$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
NOTARIZE_PROFILE="Peekmail-Notarize"

# Get version from Info.plist
VERSION=$(defaults read "$PROJECT_DIR/Peekmail/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
BUILD=$(defaults read "$PROJECT_DIR/Peekmail/Info.plist" CFBundleVersion 2>/dev/null || echo "1")
DMG_NAME="Peekmail-${VERSION}.dmg"
DMG_PATH="$PROJECT_DIR/build/$DMG_NAME"

echo "========================================="
echo "  Peekmail Release Build v${VERSION} (${BUILD})"
echo "========================================="
echo ""

# Clean previous build artifacts
echo "🧹 Cleaning previous builds..."
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_PATH" "$APPCAST_STAGING_DIR"

# Step 1: Archive
echo "📦 Archiving..."
xcodebuild archive \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -configuration Release \
  CODE_SIGN_IDENTITY="Developer ID Application: Alex Hui (43WKQQ4453)" \
  DEVELOPMENT_TEAM="43WKQQ4453" \
  CODE_SIGN_STYLE="Manual" \
  2>&1 | tail -3

echo "✅ Archive complete"

# Step 2: Export signed app
echo "🔏 Exporting signed app..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  2>&1 | tail -3

APP_PATH="$EXPORT_DIR/Peekmail.app"

if [ ! -d "$APP_PATH" ]; then
  echo "❌ Export failed — Peekmail.app not found at $APP_PATH"
  exit 1
fi

echo "✅ Signed app exported"

# Step 3: Verify code signature
echo "🔍 Verifying code signature..."
codesign --verify --deep --strict "$APP_PATH"
echo "✅ Code signature valid"

# Step 4: Create DMG
echo "💿 Creating DMG..."
STAGING_DIR="$PROJECT_DIR/build/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname "Peekmail" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DMG_PATH" \
  2>&1 | tail -1

rm -rf "$STAGING_DIR"
echo "✅ DMG created"

# Sign the DMG itself so it passes spctl's disk-image assessment
echo "🔏 Signing DMG..."
codesign --sign "Developer ID Application: Alex Hui (43WKQQ4453)" "$DMG_PATH"
echo "✅ DMG signed"

# Step 5: Notarize
echo "📤 Submitting for notarization (this may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARIZE_PROFILE" \
  --wait

echo "✅ Notarization complete"

# Step 6: Staple
echo "📎 Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"
echo "✅ Stapled"

# Step 7: Final verification
echo "🔍 Final verification..."
spctl --assess --type open --context context:primary-signature "$DMG_PATH"
echo "✅ DMG passes Gatekeeper"

# Step 8: Sign the final notarized DMG and generate Sparkle's update feed.
echo "📝 Generating signed Sparkle appcast..."
if [ ! -x "$GENERATE_APPCAST" ]; then
  echo "❌ Sparkle generate_appcast tool not found at $GENERATE_APPCAST"
  exit 1
fi

mkdir -p "$APPCAST_STAGING_DIR"
cp "$DMG_PATH" "$APPCAST_STAGING_DIR/$DMG_NAME"

"$GENERATE_APPCAST" \
  --download-url-prefix "https://github.com/alexanderghui/Peekmail/releases/download/v${VERSION}/" \
  --link "https://github.com/alexanderghui/Peekmail/releases/tag/v${VERSION}" \
  --maximum-versions 1 \
  -o "$PROJECT_DIR/appcast.xml" \
  "$APPCAST_STAGING_DIR"

rm -rf "$APPCAST_STAGING_DIR"
echo "✅ Signed appcast generated"

echo ""
echo "========================================="
echo "  🎉 Release build complete!"
echo "  DMG: $DMG_PATH"
echo "  Appcast: $PROJECT_DIR/appcast.xml"
echo "  Version: $VERSION ($BUILD)"
echo "========================================="

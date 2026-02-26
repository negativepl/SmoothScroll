#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="SmoothScroll"
DMG_NAME="SmoothScroll-1.0"
BUILD_DIR="build"
DMG_DIR="$BUILD_DIR/dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"

# Check that the .app exists
if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
    echo "Error: $BUILD_DIR/$APP_NAME.app not found. Run build.sh first."
    exit 1
fi

echo "Preparing DMG contents..."
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"

# Copy app bundle
cp -R "$BUILD_DIR/$APP_NAME.app" "$DMG_DIR/"

# Create symlink to Applications folder
ln -s /Applications "$DMG_DIR/Applications"

# Remove old DMG if exists
rm -f "$DMG_PATH"

echo "Creating DMG..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

# Cleanup
rm -rf "$DMG_DIR"

echo ""
echo "Done! DMG created: $DMG_PATH"
echo ""
echo "Users can open the DMG and drag SmoothScroll to Applications."

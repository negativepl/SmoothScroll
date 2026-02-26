#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="SmoothScroll"
BUILD_DIR="build"

echo "Compiling..."
mkdir -p "$BUILD_DIR"
swiftc -O -o "$BUILD_DIR/$APP_NAME" Sources/main.swift \
    -framework Cocoa \
    -framework CoreGraphics \
    -framework SwiftUI

echo "Creating app bundle..."
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp Info.plist "$APP_BUNDLE/Contents/"
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true

echo "Code signing (ad-hoc)..."
codesign --force --sign - "$APP_BUNDLE"

echo ""
echo "Done! Built: $APP_BUNDLE"
echo ""
echo "To install:"
echo "  cp -r $APP_BUNDLE /Applications/"
echo ""
echo "After first launch, go to:"
echo "  System Settings → Privacy & Security → Accessibility"
echo "  and enable SmoothScroll."

#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

APP_DIR="$PROJECT_DIR/dist/FaceTime Audio Bridge.app"
mkdir -p "$APP_DIR/Contents/MacOS"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc \
  -swift-version 5 \
  -O \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -framework AppKit \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework ServiceManagement \
  "$PROJECT_DIR/Sources/FaceTimeAudioBridge/main.swift" \
  -o "$APP_DIR/Contents/MacOS/FaceTimeAudioBridge"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR"
echo "$APP_DIR"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_VERSION="${APP_VERSION:-$(cat VERSION)}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'APP_VERSION must be a version such as 0.1.0\n' >&2
  exit 1
fi
APP="$PWD/build/Cropper.app"
mkdir -p "$APP/Contents/MacOS"
# Separate scratch directories avoid mixing host builds with release architectures.
if [[ "${1:-}" == "--universal" ]]; then
  for architecture in arm64 x86_64; do
    swift build -c release --scratch-path ".build/release-$architecture" --triple "$architecture-apple-macosx14.0"
    binary_directory=$(swift build -c release --scratch-path ".build/release-$architecture" --triple "$architecture-apple-macosx14.0" --show-bin-path)
    cp "$binary_directory/Cropper" "build/Cropper-$architecture"
  done
  lipo -create build/Cropper-arm64 build/Cropper-x86_64 -output "$APP/Contents/MacOS/Cropper"
else
  swift build -c release
  binary_directory=$(swift build -c release --show-bin-path)
  cp "$binary_directory/Cropper" "$APP/Contents/MacOS/Cropper"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Cropper</string>
<key>CFBundleIdentifier</key><string>io.github.ThatXliner.Cropper</string>
<key>CFBundleName</key><string>Cropper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$APP_VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Built %s (%s)\n' "$APP" "$APP_VERSION"

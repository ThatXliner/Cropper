#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_VERSION="${APP_VERSION:-$(cat VERSION)}"
export APP_VERSION
./scripts/build-app.sh --universal
lipo build/Cropper.app/Contents/MacOS/Cropper -verify_arch arm64 x86_64
mkdir -p build/release
archive="Cropper-$APP_VERSION-universal.zip"
ditto -c -k --sequesterRsrc --keepParent build/Cropper.app "build/release/$archive"
(cd build/release && shasum -a 256 "$archive" > SHA256SUMS.txt)
printf 'Release archive: build/release/%s\n' "$archive"

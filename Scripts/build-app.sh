#!/bin/bash
# Builds "build/MKV Pipeline.app" with SwiftPM; Xcode is not required.
#
#   Scripts/build-app.sh            release build
#   Scripts/build-app.sh debug      debug build
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-release}"
app="build/MKV Pipeline.app"

# pkg-config (from Homebrew) lets SwiftPM locate libmpv when it is installed outside the default prefix.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

swift build -c "$configuration" --product MKVPipeline
binary="$(swift build -c "$configuration" --show-bin-path)/MKVPipeline"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/MKVPipeline"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app" 2>/dev/null

echo "Built $app"

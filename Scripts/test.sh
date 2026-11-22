#!/bin/bash
# Runs the unit tests. Extra arguments are passed to `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# With only the Command Line Tools installed, SwiftPM does not hand the
# compiler the swift-testing macro plugin; Xcode toolchains find it themselves.
flags=()
plugins="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* && -d "$plugins" ]]; then
    flags=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi

swift test ${flags[@]+"${flags[@]}"} "$@"

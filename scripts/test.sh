#!/bin/zsh
# Builds and runs the logic tests: Foundation only, no app and no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tmp
swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/MenuLogic.swift Sources/PowerAdvice.swift Tests/main.swift Tests/PowerAdviceTests.swift -o build/tmp/logic-tests
build/tmp/logic-tests

#!/bin/bash
# Build and test without real service calls or access to the user's app data.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -scheme BuildMate -destination 'platform=macOS' -derivedDataPath .build build-for-testing
xcrun xctest .build/Build/Products/Debug/BuildMateTests.xctest

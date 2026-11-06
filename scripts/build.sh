#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p build
xcrun clang -c -fobjc-arc -target arm64-apple-macos15.0 -O2 native/Loader.m -o build/Loader.o
build_flags=(-swift-version 5)
if [[ "${1:-}" == "--probe" ]]; then build_flags+=(-DPROBE); fi
xcrun swiftc -emit-library -module-name RexAgent -target arm64-apple-macos15.0 -O \
  -framework AppKit -framework SwiftUI "${build_flags[@]}" native/*.swift build/Loader.o \
  -Xlinker -install_name -Xlinker @executable_path/../Frameworks/RexAgent.dylib \
  -o build/RexAgent.dylib
codesign -f -s - build/RexAgent.dylib
node scripts/prepare-app.mjs

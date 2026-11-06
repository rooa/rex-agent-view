#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/rex-agent-attachment.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 -DPROBE -target arm64-apple-macos15.0 -framework AppKit \
  native/Injection.swift native/AgentAppearance.swift scripts/check-attachment.swift \
  -o "$check_dir/check-attachment"
"$check_dir/check-attachment" "$check_dir"

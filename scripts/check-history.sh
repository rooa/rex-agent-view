#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/rex-agent-history.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 -framework AppKit \
  native/AgentTheme.swift native/AgentAppearance.swift native/AgentBridge.swift native/AgentControls.swift \
  scripts/check-history.swift -o "$check_dir/check-history"
"$check_dir/check-history" "$check_dir"

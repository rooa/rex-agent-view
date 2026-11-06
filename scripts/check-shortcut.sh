#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/rex-agent-shortcut.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 -DPROBE -target arm64-apple-macos15.0 -framework AppKit \
  native/Injection.swift native/AgentAppearance.swift \
  scripts/check-shortcut.swift -o "$check_dir/check-shortcut"
"$check_dir/check-shortcut" "$check_dir"

#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/rex-agent-models.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 -framework AppKit \
  native/AgentControls.swift native/AgentTheme.swift scripts/check-models.swift -o "$check_dir/check-models"
"$check_dir/check-models"

#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/rex-agent-table.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 -framework AppKit \
  native/AgentPane.swift native/AgentMarkdown.swift native/AgentTable.swift \
  native/AgentControls.swift native/AgentTheme.swift native/AgentAppearance.swift native/AgentLinks.swift \
  scripts/check-table.swift -o "$check_dir/check-table"
"$check_dir/check-table"

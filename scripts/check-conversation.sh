#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/rex-agent-conversation.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
cd "$project_dir"
sources=(native/AgentPane.swift native/AgentMarkdown.swift native/AgentTable.swift native/AgentControls.swift native/AgentTheme.swift native/AgentAppearance.swift)
if [[ -f native/AgentLinks.swift ]]; then sources+=(native/AgentLinks.swift); fi
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 -framework AppKit \
  "${sources[@]}" scripts/check-conversation.swift -o "$check_dir/check-conversation"
"$check_dir/check-conversation" "$check_dir"

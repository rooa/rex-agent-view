#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/rex-agent-links.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
cd "$project_dir"
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 \
  native/AgentLinks.swift scripts/check-links.swift -o "$check_dir/check-links"
"$check_dir/check-links"

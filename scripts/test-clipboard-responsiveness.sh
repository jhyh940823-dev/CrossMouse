#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
crossmouse_executable="${1:-.build/debug/CrossMouseMac}"
if [[ ! -x "$crossmouse_executable" ]]; then
  printf '%s\n' 'Build CrossMouseMac first, or pass its executable path.' >&2
  exit 1
fi
fixture_dir="diagnostics/clipboard-responsiveness"
mkdir -p "$fixture_dir"
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/CrossMouseCore/TextClipboard.swift \
  Sources/CrossMouseCore/TextClipboardReadProcess.swift \
  Sources/CrossMouseCore/WireProtocol.swift \
  scripts/Test-ClipboardResponsiveness.swift \
  -o "$fixture_dir/native-clipboard-responsiveness"
"$fixture_dir/native-clipboard-responsiveness" "$crossmouse_executable"

#!/usr/bin/env bash
# Compile and run the pure-logic unit tests (no XCTest/SPM — just swiftc).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(mktemp -d)/usagelogic-tests"
swiftc -o "$BIN" "$HERE/../standalone/UsageLogic.swift" "$HERE/main.swift"
"$BIN"

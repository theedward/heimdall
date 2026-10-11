#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TEST_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-tests.XXXXXX")"
trap 'rm -rf "$TEST_WORKDIR"' EXIT
xcrun swiftc "$ROOT/Sources/Features.swift" "$ROOT/Sources/Cleanup.swift" "$ROOT/Tests/main.swift" -o "$TEST_WORKDIR/tests"
"$TEST_WORKDIR/tests"

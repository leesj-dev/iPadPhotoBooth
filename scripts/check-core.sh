#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/portable
swiftc -parse-as-library -swift-version 6 -D PORTABLE_TEST_RUNNER \
  Sources/BoothCore/*.swift Tests/BoothCoreTests/BoothCoreTests.swift \
  -o .build/portable/core-checks
.build/portable/core-checks

#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/callback-check
swiftc -emit-library -emit-module -parse-as-library -swift-version 6 \
  -module-name BoothCore Sources/BoothCore/*.swift \
  -emit-module-path .build/callback-check/BoothCore.swiftmodule \
  -o .build/callback-check/libBoothCore.dylib
swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
  -I .build/callback-check -L .build/callback-check -lBoothCore \
  -Xlinker -rpath -Xlinker "$(pwd)/.build/callback-check" \
  PhotoBooth/Camera/USBTransport.swift scripts/check-camera-callbacks.swift \
  -o .build/callback-check/callback-check
.build/callback-check/callback-check

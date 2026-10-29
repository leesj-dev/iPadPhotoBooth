#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/image-check
booth_sim_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
booth_sim_arch=$(uname -m)
booth_sim_target="$booth_sim_arch-apple-ios18.0-simulator"
xcrun swiftc -emit-library -emit-module -parse-as-library -swift-version 6 \
  -sdk "$booth_sim_sdk" -target "$booth_sim_target" \
  -module-name BoothCore Sources/BoothCore/*.swift \
  -emit-module-path .build/image-check/BoothCore.swiftmodule \
  -Xlinker -install_name -Xlinker @rpath/libBoothCore.dylib \
  -o .build/image-check/libBoothCore.dylib
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
  -sdk "$booth_sim_sdk" -target "$booth_sim_target" \
  -I .build/image-check -L .build/image-check -lBoothCore \
  -Xlinker -rpath -Xlinker "$(pwd)/.build/image-check" \
  PhotoBooth/Imaging/PhotoRenderer.swift PhotoBooth/Printing/AirPrinter.swift scripts/check-image-orientation.swift \
  -o .build/image-check/image-check
xcrun simctl spawn booted "$(pwd)/.build/image-check/image-check" "$(pwd)/PhotoBooth/Resources/Templates/templates.json" "$(pwd)/.build/diagnostics/landscape-composite-check.jpg"

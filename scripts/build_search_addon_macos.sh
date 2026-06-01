#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-build/JLYSearchAddon.dylib}"
mkdir -p "$(dirname "$OUT")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
clang -isysroot "$SDK" \
  -target arm64-apple-ios12.0 \
  -dynamiclib \
  -fobjc-arc \
  -miphoneos-version-min=12.0 \
  -framework Foundation \
  -framework UIKit \
  -framework Photos \
  -framework AVFoundation \
  addon/JLYSearchAddon.m \
  -o "$OUT"

echo "Built $OUT"

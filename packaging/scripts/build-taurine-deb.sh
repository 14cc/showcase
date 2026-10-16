#!/usr/bin/env bash
# Builds com.rostane.showcase-taurine, the rootful package for Taurine on iOS 14.
# The BTdaemon and BTQuiet are built on the Mac with the procursus SDK; the app
# and package are built on the rootful device like the regular package:
#   IPAD_PORT=4444 ./scripts/build-taurine-deb.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
SDK="${SDK:-$REPO_ROOT/../iOS-SDKs/procursus/iPhoneOS.sdk}"
OUT="$REPO_ROOT/build/taurine"
mkdir -p "$OUT"
SDK="$SDK" ENT="$REPO_ROOT/source/ent_btdaemon.xml" OUT="$OUT/BTdaemon" \
  zsh "$REPO_ROOT/btstack-rootless/build_btdaemon.sh"
clang -isysroot "$SDK" -miphoneos-version-min=12.0 -arch arm64 -arch arm64e -Os \
  -dynamiclib -o "$OUT/BTQuiet.dylib" "$REPO_ROOT/tweak/BTQuiet.m"
ldid -S "$OUT/BTQuiet.dylib"
VARIANT=taurine "$ROOT/scripts/build-rootful-deb.sh"

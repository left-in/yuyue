#!/bin/bash
# Builds the Rust core for Android into the app module:
#
#   app/src/main/jniLibs/<abi>/libyuyue_core.so    the core, for 64-bit and 32-bit ARM phones
#   app/src/main/java/uniffi/yuyue_core/           the Kotlin side of the bindings (UniFFI)
#
# Usage: android/build-core.sh [--debug] [--arm64]   --arm64 builds only the 64-bit library
# Needs ANDROID_NDK_HOME (or ANDROID_HOME with the NDK installed) and `cargo install cargo-ndk`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
APP="$ROOT/android/app/src/main"

PROFILE=release
ABIS=(arm64-v8a armeabi-v7a)
for arg in "$@"; do
  case "$arg" in
    --debug) PROFILE=dev ;;
    --arm64) ABIS=(arm64-v8a) ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
: "${ANDROID_HOME:=/Volumes/T2214/android-sdk}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME="$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)"
fi
export ANDROID_NDK_HOME

TARGETS=()
for abi in "${ABIS[@]}"; do TARGETS+=(-t "$abi"); done
echo "▸ core for ${ABIS[*]} ($PROFILE)"
# Android 8 (API 26) is the oldest the app supports.
(cd "$CORE" && cargo ndk --platform 26 "${TARGETS[@]}" -o "$APP/jniLibs" build -p yuyue-core --lib --profile "$PROFILE" --quiet)

echo "▸ Kotlin bindings"
OUT_DIR=$([ "$PROFILE" = dev ] && echo debug || echo release)
LIB="$CORE/target/aarch64-linux-android/$OUT_DIR/libyuyue_core.so"
rm -rf "$APP/java/uniffi"
(cd "$CORE" && cargo run -p uniffi-bindgen --quiet -- generate "$LIB" --language kotlin --out-dir "$APP/java" --no-format)
echo "✓ $APP/jniLibs, $APP/java/uniffi"

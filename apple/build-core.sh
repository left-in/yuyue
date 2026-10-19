#!/bin/bash
# Builds the Rust core for Apple platforms as the local Swift package apple/YuyueCore:
#
#   YuyueCoreFFI.xcframework           the static library for Mac, iPhone/iPad and the simulator
#   Sources/YuyueCore/yuyue_core.swift  the Swift side of the bindings (UniFFI)
#
# Usage: apple/build-core.sh [--debug] [--mac]     --mac builds only the Mac slice (faster)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
PACKAGE="$ROOT/apple/YuyueCore"
BUILD="$CORE/target/apple"

PROFILE=release
TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)
for arg in "$@"; do
  case "$arg" in
    --debug) PROFILE=dev ;;
    --mac) TARGETS=(aarch64-apple-darwin) ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
OUT_DIR=$([ "$PROFILE" = dev ] && echo debug || echo release)

# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Same minimums as the app, so the linker doesn't warn about newer object files.
export MACOSX_DEPLOYMENT_TARGET=15.0
export IPHONEOS_DEPLOYMENT_TARGET=18.0

for target in "${TARGETS[@]}"; do
  echo "▸ core for $target ($PROFILE)"
  cargo rustc --manifest-path "$CORE/Cargo.toml" -p yuyue-core --lib --crate-type staticlib \
    --profile "$PROFILE" --target "$target" --quiet
done

echo "▸ Swift bindings"
GENERATED="$BUILD/generated"
rm -rf "$GENERATED"
mkdir -p "$GENERATED"
# uniffi-bindgen reads the workspace's cargo metadata from the current folder.
(cd "$CORE" && cargo run -p uniffi-bindgen --quiet -- generate \
  "target/${TARGETS[0]}/$OUT_DIR/libyuyue_core.a" \
  --language swift --out-dir "$GENERATED" --no-format)

# Headers sit in a folder named after the C module, so Swift finds the module map by name.
HEADERS="$BUILD/headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS/yuyue_coreFFI"
cp "$GENERATED/yuyue_coreFFI.h" "$HEADERS/yuyue_coreFFI/"
cp "$GENERATED/yuyue_coreFFI.modulemap" "$HEADERS/yuyue_coreFFI/module.modulemap"

echo "▸ XCFramework"
ARGS=()
for target in "${TARGETS[@]}"; do
  ARGS+=(-library "$CORE/target/$target/$OUT_DIR/libyuyue_core.a" -headers "$HEADERS")
done
rm -rf "$PACKAGE/YuyueCoreFFI.xcframework"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$PACKAGE/YuyueCoreFFI.xcframework" >/dev/null

mkdir -p "$PACKAGE/Sources/YuyueCore"
cp "$GENERATED/yuyue_core.swift" "$PACKAGE/Sources/YuyueCore/yuyue_core.swift"
echo "✓ $PACKAGE"

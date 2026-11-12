#!/bin/sh
set -eu

# 统一构建 Rust 静态 XCFramework，避免把二进制产物提交到源码仓库。
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT_DIR/target"}
OUTPUT_DIR=${1:-"$ROOT_DIR/dist/ZDObfRuntime.xcframework"}

cd "$ROOT_DIR"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo build --locked --release -p zd_string_runtime --target aarch64-apple-ios
cargo build --locked --release -p zd_string_runtime --target aarch64-apple-ios-sim
cargo build --locked --release -p zd_string_runtime --target x86_64-apple-ios

rm -rf "$OUTPUT_DIR"
mkdir -p "$(dirname -- "$OUTPUT_DIR")"
SIMULATOR_LIBRARY="$TARGET_DIR/zd_string_runtime-simulator.a"
lipo -create \
  "$TARGET_DIR/aarch64-apple-ios-sim/release/libzd_string_runtime.a" \
  "$TARGET_DIR/x86_64-apple-ios/release/libzd_string_runtime.a" \
  -output "$SIMULATOR_LIBRARY"
xcodebuild -create-xcframework \
  -library "$TARGET_DIR/aarch64-apple-ios/release/libzd_string_runtime.a" \
  -headers "$ROOT_DIR/crates/runtime/include" \
  -library "$SIMULATOR_LIBRARY" \
  -headers "$ROOT_DIR/crates/runtime/include" \
  -output "$OUTPUT_DIR"

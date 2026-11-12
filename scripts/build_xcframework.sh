#!/bin/sh
set -eu

# 构建覆盖 Apple 平台的 Rust static XCFramework。
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT_DIR/target"}
OUTPUT_DIR=${1:-"$ROOT_DIR/dist/ZDObfRuntime.xcframework"}
HEADERS_DIR="$ROOT_DIR/crates/runtime/include"

cd "$ROOT_DIR"

# Rust 1.99 stable 提供这些 Apple targets；rustup 对已安装 target 是幂等的。
rustup target add \
    aarch64-apple-ios \
    aarch64-apple-ios-sim \
    x86_64-apple-ios \
    aarch64-apple-tvos \
    aarch64-apple-tvos-sim \
    aarch64-apple-watchos \
    aarch64-apple-watchos-sim \
    aarch64-apple-visionos \
    aarch64-apple-visionos-sim \
    aarch64-apple-darwin \
    x86_64-apple-darwin \
    aarch64-apple-ios-macabi \
    x86_64-apple-ios-macabi

for target in \
    aarch64-apple-ios \
    aarch64-apple-ios-sim \
    x86_64-apple-ios \
    aarch64-apple-tvos \
    aarch64-apple-tvos-sim \
    aarch64-apple-watchos \
    aarch64-apple-watchos-sim \
    aarch64-apple-visionos \
    aarch64-apple-visionos-sim \
    aarch64-apple-darwin \
    x86_64-apple-darwin \
    aarch64-apple-ios-macabi \
    x86_64-apple-ios-macabi
do
    cargo build --locked --release -p zd_string_runtime --target "$target"
done

rm -rf "$OUTPUT_DIR"
mkdir -p "$(dirname -- "$OUTPUT_DIR")"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zdobf-xcframework.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

library() {
    printf '%s/%s/release/libzd_string_runtime.a' "$TARGET_DIR" "$1"
}

make_universal() {
    output=$1
    shift
    xcrun lipo -create "$@" -output "$output"
}

mkdir -p "$WORK_DIR/ios-simulator" "$WORK_DIR/macos" "$WORK_DIR/catalyst"
IOS_SIMULATOR="$WORK_DIR/ios-simulator/libzd_string_runtime.a"
MACOS_LIBRARY="$WORK_DIR/macos/libzd_string_runtime.a"
CATALYST_LIBRARY="$WORK_DIR/catalyst/libzd_string_runtime.a"
make_universal "$IOS_SIMULATOR" \
    "$(library aarch64-apple-ios-sim)" \
    "$(library x86_64-apple-ios)"
make_universal "$MACOS_LIBRARY" \
    "$(library aarch64-apple-darwin)" \
    "$(library x86_64-apple-darwin)"
make_universal "$CATALYST_LIBRARY" \
    "$(library aarch64-apple-ios-macabi)" \
    "$(library x86_64-apple-ios-macabi)"

xcodebuild -create-xcframework \
    -library "$(library aarch64-apple-ios)" -headers "$HEADERS_DIR" \
    -library "$IOS_SIMULATOR" -headers "$HEADERS_DIR" \
    -library "$(library aarch64-apple-tvos)" -headers "$HEADERS_DIR" \
    -library "$(library aarch64-apple-tvos-sim)" -headers "$HEADERS_DIR" \
    -library "$(library aarch64-apple-watchos)" -headers "$HEADERS_DIR" \
    -library "$(library aarch64-apple-watchos-sim)" -headers "$HEADERS_DIR" \
    -library "$(library aarch64-apple-visionos)" -headers "$HEADERS_DIR" \
    -library "$(library aarch64-apple-visionos-sim)" -headers "$HEADERS_DIR" \
    -library "$MACOS_LIBRARY" -headers "$HEADERS_DIR" \
    -library "$CATALYST_LIBRARY" -headers "$HEADERS_DIR" \
    -output "$OUTPUT_DIR"

printf 'Created %s\n' "$OUTPUT_DIR"

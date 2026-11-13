#!/bin/sh
set -eu

# 构建覆盖 Apple 平台的 Rust static XCFramework。
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT_DIR/target"}
OUTPUT_DIR=${1:-"$ROOT_DIR/dist/ZDObfRuntime.xcframework"}
HEADERS_DIR="$ROOT_DIR/crates/runtime/include"

# 输出目录会被整体删除，拒绝空值、根目录和非 .xcframework 路径，避免参数写错造成误删。
case "$OUTPUT_DIR" in
    *.xcframework) ;;
    *)
        printf 'Output path must end with .xcframework: %s\n' "$OUTPUT_DIR" >&2
        exit 64
        ;;
esac

cd "$ROOT_DIR"

export IPHONEOS_DEPLOYMENT_TARGET=15.0
export MACOSX_DEPLOYMENT_TARGET=15.0
export TVOS_DEPLOYMENT_TARGET=15.0
export WATCHOS_DEPLOYMENT_TARGET=8.0
export XROS_DEPLOYMENT_TARGET=1.0

# 产物不应带构建机的绝对路径（用户名、CARGO_HOME、工具链位置），统一映射成固定前缀。
CARGO_HOME_DIR=${CARGO_HOME:-"$HOME/.cargo"}
RUSTUP_HOME_DIR=${RUSTUP_HOME:-"$HOME/.rustup"}
# 用 CARGO_ENCODED_RUSTFLAGS（0x1f 分隔）传参，路径含空格时不会被按空白拆开。
# 它优先于 RUSTFLAGS，所以把调用方已有的 RUSTFLAGS 一并带上（这部分仍按空白拆分）。
unit_separator=$(printf '\037')
encoded_flags=""
for flag in ${RUSTFLAGS:-}; do
    encoded_flags="${encoded_flags:+$encoded_flags$unit_separator}$flag"
done
for flag in \
    "--remap-path-prefix=$ROOT_DIR=/zdobf" \
    "--remap-path-prefix=$CARGO_HOME_DIR=/cargo" \
    "--remap-path-prefix=$RUSTUP_HOME_DIR=/rustup"
do
    encoded_flags="${encoded_flags:+$encoded_flags$unit_separator}$flag"
done
export CARGO_ENCODED_RUSTFLAGS="$encoded_flags"
unset RUSTFLAGS

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

# arm64_32（32 位指针的 watchOS 真机，Series 4–8 / SE 1）是 tier 3 目标，没有预编译 std，
# 必须用 nightly 的 -Zbuild-std 构建。64 位 arm64 的 watchOS 真机/模拟器代码在 LLVM 中最低即为
# watchOS 26，所以声明的 watchOS 8 最低版本实际由 arm64_32 切片承担。
rustup toolchain install nightly --profile minimal --component rust-src

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
cargo +nightly build --locked --release -p zd_string_runtime \
    --target arm64_32-apple-watchos -Zbuild-std=std,panic_unwind

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

mkdir -p "$WORK_DIR/ios-simulator" "$WORK_DIR/macos" "$WORK_DIR/catalyst" "$WORK_DIR/watchos"
IOS_SIMULATOR="$WORK_DIR/ios-simulator/libzd_string_runtime.a"
MACOS_LIBRARY="$WORK_DIR/macos/libzd_string_runtime.a"
CATALYST_LIBRARY="$WORK_DIR/catalyst/libzd_string_runtime.a"
WATCHOS_LIBRARY="$WORK_DIR/watchos/libzd_string_runtime.a"
make_universal "$IOS_SIMULATOR" \
    "$(library aarch64-apple-ios-sim)" \
    "$(library x86_64-apple-ios)"
make_universal "$MACOS_LIBRARY" \
    "$(library aarch64-apple-darwin)" \
    "$(library x86_64-apple-darwin)"
make_universal "$CATALYST_LIBRARY" \
    "$(library aarch64-apple-ios-macabi)" \
    "$(library x86_64-apple-ios-macabi)"
make_universal "$WATCHOS_LIBRARY" \
    "$(library aarch64-apple-watchos)" \
    "$(library arm64_32-apple-watchos)"

xcodebuild -create-xcframework \
    -library "$(library aarch64-apple-ios)" -headers "$HEADERS_DIR" \
    -library "$IOS_SIMULATOR" -headers "$HEADERS_DIR" \
    -library "$(library aarch64-apple-tvos)" -headers "$HEADERS_DIR" \
    -library "$(library aarch64-apple-tvos-sim)" -headers "$HEADERS_DIR" \
    -library "$WATCHOS_LIBRARY" -headers "$HEADERS_DIR" \
    -library "$(library aarch64-apple-watchos-sim)" -headers "$HEADERS_DIR" \
    -library "$(library aarch64-apple-visionos)" -headers "$HEADERS_DIR" \
    -library "$(library aarch64-apple-visionos-sim)" -headers "$HEADERS_DIR" \
    -library "$MACOS_LIBRARY" -headers "$HEADERS_DIR" \
    -library "$CATALYST_LIBRARY" -headers "$HEADERS_DIR" \
    -output "$OUTPUT_DIR"

# 校验每个切片里所有目标文件的最低系统版本都不高于声明值，否则链接到较低部署目标时会出现
# "built for newer" 警告，或实际抬高部署目标。
assert_minos() {
    label=$1
    library=$2
    architecture=$3
    maximum=$4
    inspect_dir=$(mktemp -d "$WORK_DIR/minos.XXXXXX")
    if ! xcrun lipo -thin "$architecture" "$library" -output "$inspect_dir/thin.a" 2>/dev/null; then
        cp "$library" "$inspect_dir/thin.a"
    fi
    (cd "$inspect_dir" && ar x thin.a)
    highest=$(
        for object in "$inspect_dir"/*.o; do
            xcrun vtool -show-build "$object" 2>/dev/null | awk '/^ *minos /{ print $2 } /^ *version /{ print $2 }'
        done | sort -V | tail -1
    )
    if [ -z "$highest" ]; then
        printf 'No Mach-O build version found in %s (%s)\n' "$label" "$architecture" >&2
        exit 1
    fi
    if [ "$(printf '%s\n%s\n' "$highest" "$maximum" | sort -V | tail -1)" != "$maximum" ]; then
        printf 'Slice %s (%s) requires %s, above the declared minimum %s\n' "$label" "$architecture" "$highest" "$maximum" >&2
        exit 1
    fi
    printf 'ok  %s (%s): minos %s <= %s\n' "$label" "$architecture" "$highest" "$maximum"
}

assert_minos ios "$(library aarch64-apple-ios)" arm64 15.0
assert_minos ios-simulator "$IOS_SIMULATOR" arm64 15.0
assert_minos ios-simulator "$IOS_SIMULATOR" x86_64 15.0
assert_minos tvos "$(library aarch64-apple-tvos)" arm64 15.0
assert_minos tvos-simulator "$(library aarch64-apple-tvos-sim)" arm64 15.0
# 64 位 arm64 的 watchOS 真机代码在 LLVM 中最低即为 watchOS 26；watchOS 8 的真机由 arm64_32 覆盖。
assert_minos watchos "$WATCHOS_LIBRARY" arm64_32 8.0
assert_minos watchos "$WATCHOS_LIBRARY" arm64 26.0
assert_minos watchos-simulator "$(library aarch64-apple-watchos-sim)" arm64 8.0
assert_minos visionos "$(library aarch64-apple-visionos)" arm64 1.0
assert_minos visionos-simulator "$(library aarch64-apple-visionos-sim)" arm64 1.0
assert_minos macos "$MACOS_LIBRARY" arm64 15.0
assert_minos macos "$MACOS_LIBRARY" x86_64 15.0
assert_minos catalyst "$CATALYST_LIBRARY" arm64 15.0
assert_minos catalyst "$CATALYST_LIBRARY" x86_64 15.0

printf 'Created %s\n' "$OUTPUT_DIR"

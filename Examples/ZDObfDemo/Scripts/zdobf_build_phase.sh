#!/bin/sh
set -eu

# Xcode Run Script Build Phase：扫描受保护源码 → 加密 → 生成链接用的 section object。
# 受保护的原始文件不参与编译；只有 Generated/ 下的生成文件进入 Compile Sources。
library_dir=$(CDPATH= cd -- "$SRCROOT/../.." && pwd)
generator="$library_dir/Generator/zig-out/bin/zdstring-gen"
crypto_cli="$library_dir/target/release/zdstring-crypto"
if [ ! -x "$generator" ] || [ ! -x "$crypto_cli" ]; then
    echo "error: host tools are missing; run Examples/ZDObfDemo/Scripts/bootstrap.sh first" >&2
    exit 1
fi

# ⚠️ Demo 默认 key（0x00...0x1f）。真实项目应由 CI Secret 注入，不要写进仓库或工程设置。
export ZD_STRING_RUNTIME_KEY_B64="${ZD_STRING_RUNTIME_KEY_B64:-AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=}"

generated="$SRCROOT/Generated"
export ZD_STRING_DERIVED_DIR="${ZD_STRING_DERIVED_DIR:-$DERIVED_FILE_DIR/ZDObf}"
export ZD_STRING_SECTION_OBJECT="${ZD_STRING_SECTION_OBJECT:-$ZD_STRING_DERIVED_DIR/zdstring-section.o}"
mkdir -p "$generated" "$ZD_STRING_DERIVED_DIR"

# 每行：原始源码|生成源码|语言（swift 或 objc）。
source_map="$ZD_STRING_DERIVED_DIR/source-map.txt"
printf '%s|%s|%s\n' \
    "$SRCROOT/App/Protected/ProtectedAPI.swift" "$generated/ProtectedAPI.swift" swift \
    "$SRCROOT/App/Protected/ProtectedAPIObjC.m" "$generated/ProtectedAPIObjC.m" objc \
    > "$source_map"

ZD_STRING_GENERATOR="$generator" ZD_STRING_CRYPTO_CLI="$crypto_cli" \
    "$library_dir/scripts/xcode_build_phase.sh" "$source_map"

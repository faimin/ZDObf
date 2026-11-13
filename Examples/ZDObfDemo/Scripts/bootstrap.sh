#!/bin/sh
set -eu

# 构建 Demo 需要的 host 工具：Zig 源码扫描器和 Rust 加密 CLI。只需执行一次。
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
cd "$root"
cargo build --locked --release -p zd_string_crypto_cli
(cd Generator && zig build -Doptimize=ReleaseSafe)
printf 'Tools ready:\n  %s\n  %s\n' \
    "$root/target/release/zdstring-crypto" \
    "$root/Generator/zig-out/bin/zdstring-gen"

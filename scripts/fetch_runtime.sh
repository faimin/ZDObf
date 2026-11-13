#!/bin/sh
set -eu

# 下载 Package.swift 固定的 Runtime Release 资产，校验 SHA-256 后解压到 dist/。
# 用法: fetch_runtime.sh [--force]；ZDOBF_RUNTIME_URL 可覆盖下载地址（仅用于测试镜像或离线缓存）。
force=0
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--force" ]; }; then
    printf '%s\n' "usage: fetch_runtime.sh [--force]" >&2
    exit 64
fi
[ "$#" -eq 1 ] && force=1

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$root_dir/Package.swift"
output="$root_dir/dist/ZDObfRuntime.xcframework"

version=$(sed -n 's/^let runtimeReleaseVersion = "\(.*\)"$/\1/p' "$manifest")
checksum=$(sed -n 's/^let runtimeReleaseChecksum = "\(.*\)"$/\1/p' "$manifest")
if [ -z "$version" ] || [ -z "$checksum" ]; then
    printf '%s\n' "No Runtime release is pinned in Package.swift; build it with scripts/build_xcframework.sh" >&2
    exit 65
fi
if [ -d "$output" ] && [ "$force" -eq 0 ]; then
    printf 'Runtime already present: %s\n' "$output"
    exit 0
fi

url=${ZDOBF_RUNTIME_URL:-"https://github.com/faimin/ZDObf/releases/download/v$version/ZDObfRuntime.xcframework.zip"}
work=$(mktemp -d "${TMPDIR:-/tmp}/zdobf-runtime.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
curl --fail --silent --show-error --location "$url" --output "$work/runtime.zip"
actual=$(shasum -a 256 "$work/runtime.zip" | awk '{ print $1 }')
if [ "$actual" != "$checksum" ]; then
    printf 'Checksum mismatch for %s\n  expected %s\n  actual   %s\n' "$url" "$checksum" "$actual" >&2
    exit 1
fi
mkdir "$work/extracted"
ditto -x -k "$work/runtime.zip" "$work/extracted"
if [ ! -f "$work/extracted/ZDObfRuntime.xcframework/Info.plist" ]; then
    printf '%s\n' "Archive does not contain ZDObfRuntime.xcframework" >&2
    exit 1
fi
mkdir -p "$root_dir/dist"
rm -rf "$output"
mv "$work/extracted/ZDObfRuntime.xcframework" "$output"
printf 'Installed %s (Runtime %s)\n' "$output" "$version"

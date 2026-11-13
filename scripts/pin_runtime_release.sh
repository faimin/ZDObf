#!/bin/sh
set -eu

# 发布时把 Package.swift 固定到某个 GitHub Release 的 Runtime 资产（URL 由版本号推导，校验和由 zip 计算）。
if [ "$#" -ne 2 ]; then
    printf '%s\n' "usage: pin_runtime_release.sh <version, e.g. 0.1.0> <ZDObfRuntime.xcframework.zip>" >&2
    exit 64
fi
version=$1
archive=$2
case "$version" in
    ''|*[!0-9A-Za-z.+-]*)
        printf 'Invalid version: %s\n' "$version" >&2
        exit 64
        ;;
esac
if [ ! -f "$archive" ]; then
    printf 'Archive not found: %s\n' "$archive" >&2
    exit 66
fi

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$root_dir/Package.swift"
# SwiftPM 的 binaryTarget checksum 就是 zip 的 SHA-256。
checksum=$(shasum -a 256 "$archive" | awk '{ print $1 }')

temporary=$(mktemp "${TMPDIR:-/tmp}/zdobf-package.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM
sed -e "s/^let runtimeReleaseVersion = \".*\"\$/let runtimeReleaseVersion = \"$version\"/" \
    -e "s/^let runtimeReleaseChecksum = \".*\"\$/let runtimeReleaseChecksum = \"$checksum\"/" \
    "$manifest" > "$temporary"
if ! grep -q "^let runtimeReleaseVersion = \"$version\"\$" "$temporary" ||
   ! grep -q "^let runtimeReleaseChecksum = \"$checksum\"\$" "$temporary"; then
    printf '%s\n' "Package.swift does not contain the runtimeRelease* constants" >&2
    exit 65
fi
cat "$temporary" > "$manifest"
printf 'Pinned Runtime %s (sha256 %s)\n' "$version" "$checksum"

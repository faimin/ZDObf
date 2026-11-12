#!/bin/sh
set -eu

# 将 Blob 转为可被最终链接器合并的 Mach-O relocatable object。
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    printf '%s\n' "usage: embed_macho_section.sh <blob> <output-object> [arch-or-quoted-arch-list]" >&2
    exit 64
fi

blob=$1
output=$2
arch=${3:-${ZD_STRING_ARCH:-${ARCHS:-arm64}}}

if [ ! -f "$blob" ]; then
    printf 'Blob not found: %s\n' "$blob" >&2
    exit 66
fi
mkdir -p "$(dirname "$output")"
sdk=${ZD_STRING_SDK:-iphoneos}
# 查找 SDK 工具不会设置目标平台，编译和 relocatable 链接都必须显式指定。
case "$sdk" in
    iphoneos)
        platform=ios
        ;;
    iphonesimulator)
        platform=ios-simulator
        ;;
    *)
        printf 'Unsupported iOS SDK: %s\n' "$sdk" >&2
        exit 64
        ;;
esac
ld_path=$(xcrun --sdk "$sdk" --find ld)
clang_path=$(xcrun --sdk "$sdk" --find clang)
sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
sdk_version=$(xcrun --sdk "$sdk" --show-sdk-version)

# ld -r 需要空 object；每个架构单独生成，再合并以兼容 Xcode 的共享构建阶段。
temporary_dir=$(mktemp -d "${output}.zdstring.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM
set --
for target_arch in $arch; do
    case "$target_arch" in
        arm64|arm64e|x86_64) ;;
        *) printf 'Unsupported architecture: %s\n' "$target_arch" >&2; exit 64 ;;
    esac
    minimum=${IPHONEOS_DEPLOYMENT_TARGET:-13.0}
    if [ "$sdk" = "iphonesimulator" ]; then
        # Apple Silicon Simulator 自 iOS 14 起可用，避免 stub 与 ld 的最低版本不一致。
        if [ "$target_arch" = "arm64" ] && [ "${minimum%%.*}" -lt 14 ]; then
            minimum=14.0
        fi
        target="${target_arch}-apple-ios${minimum}-simulator"
    else
        target="${target_arch}-apple-ios${minimum}"
    fi
    stub="$temporary_dir/$target_arch-stub.o"
    section="$temporary_dir/$target_arch.o"
    "$clang_path" -target "$target" -isysroot "$sdk_path" -c -x c /dev/null -o "$stub"
    "$ld_path" -r -arch "$target_arch" -platform_version "$platform" "$minimum" "$sdk_version" \
        -sectcreate __DATA __zdstring "$blob" "$stub" -o "$section"
    set -- "$@" "$section"
done
if [ "$#" -eq 0 ]; then
    printf '%s\n' "At least one architecture is required" >&2
    exit 64
elif [ "$#" -eq 1 ]; then
    mv "$1" "$output"
else
    xcrun lipo -create "$@" -output "$output"
fi

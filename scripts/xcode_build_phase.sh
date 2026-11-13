#!/bin/sh
set -eu

# Xcode 在编译前运行本脚本：生成无明文源码、Blob 与最终链接使用的 section object。
if [ "$#" -gt 1 ]; then
    printf '%s\n' "usage: xcode_build_phase.sh [source-map]" >&2
    exit 64
fi

source_map=${1:-}
# 独立仓库从脚本自身定位工具，避免依赖接入 App 的 SRCROOT 布局。
library_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
catalog_mapping=${ZD_STRING_CATALOG_MAPPING:-}
generator=${ZD_STRING_GENERATOR:-"$library_root/Generator/zig-out/bin/zdstring-gen"}
crypto_cli=${ZD_STRING_CRYPTO_CLI:-"$library_root/target/release/zdstring-crypto"}
namespace=${ZD_STRING_NAMESPACE:-${PRODUCT_BUNDLE_IDENTIFIER:-}}
derived_dir=${ZD_STRING_DERIVED_DIR:-"${DERIVED_FILE_DIR:?DERIVED_FILE_DIR is required}/ZDObf"}
section_object=${ZD_STRING_SECTION_OBJECT:-"$derived_dir/zdstring-section.o"}
embed_script=${ZD_STRING_EMBED_SCRIPT:-"$(dirname "$0")/embed_macho_section.sh"}
profile=${ZD_STRING_PROFILE:-debug}
nonce_mode=${ZD_STRING_NONCE_MODE:-deterministic}

if [ -z "$namespace" ] || { [ -z "$source_map" ] && [ -z "$catalog_mapping" ]; }; then
    printf '%s\n' "ZD_STRING_NAMESPACE and source map or catalog mapping are required" >&2
    exit 65
fi
if [ -n "$source_map" ] && [ ! -f "$source_map" ]; then
    printf 'Source map not found: %s\n' "$source_map" >&2
    exit 66
fi
if [ -n "$catalog_mapping" ] && [ ! -f "$catalog_mapping" ]; then
    printf 'Catalog mapping not found: %s\n' "$catalog_mapping" >&2
    exit 66
fi
if [ "${CONFIGURATION:-}" = "Release" ] && [ -z "${ZD_STRING_PROFILE:-}" ]; then
    profile=release
fi
if [ "${CONFIGURATION:-}" = "Release" ] && [ -z "${ZD_STRING_NONCE_MODE:-}" ]; then
    nonce_mode=random
fi

mkdir -p "$derived_dir/manifests"
merged_manifest="$derived_dir/strings.manifest.json"
blob="$derived_dir/strings.zdstr"
set -- merge-manifests --output "$merged_manifest"
entry_index=0

if [ -n "$catalog_mapping" ]; then
    catalog_manifest="$derived_dir/manifests/catalog.json"
    "$generator" catalog-manifest --input "$catalog_mapping" --output "$catalog_manifest" --namespace "$namespace"
    set -- "$@" --input "$catalog_manifest"
    entry_index=$((entry_index + 1))
fi

# source-map 每行格式为：原始源码绝对路径|生成源码绝对路径|swift 或 objc。
if [ -n "$source_map" ]; then
    while IFS='|' read -r source generated language || [ -n "$source$generated$language" ]; do
        case "$source" in
            ''|'#'*) continue ;;
        esac
        if [ -z "$generated" ] || [ -z "$language" ]; then
            printf 'Invalid source map row for %s\n' "$source" >&2
            exit 65
        fi
        mkdir -p "$(dirname "$generated")"
        manifest="$derived_dir/manifests/$entry_index.json"
        "$generator" scan --input "$source" --output "$generated" --manifest "$manifest" --language "$language" --namespace "$namespace"
        set -- "$@" --input "$manifest"
        entry_index=$((entry_index + 1))
    done < "$source_map"
fi

if [ "$entry_index" -eq 0 ]; then
    printf '%s\n' "No source files found in source map" >&2
    exit 65
fi
"$generator" "$@"

set -- --manifest "$merged_manifest" --output "$blob" --crypto-cli "$crypto_cli" --profile "$profile" --nonce-mode "$nonce_mode"
if [ -n "${ZD_STRING_BUILD_SALT_B64:-}" ]; then
    set -- "$@" --build-salt-b64 "$ZD_STRING_BUILD_SALT_B64"
fi
"$generator" "$@"

case "${PLATFORM_NAME:-iphoneos}" in
    iphoneos) sdk=iphoneos ;;
    iphonesimulator) sdk=iphonesimulator ;;
    appletvos) sdk=appletvos ;;
    appletvsimulator) sdk=appletvsimulator ;;
    watchos) sdk=watchos ;;
    watchsimulator) sdk=watchsimulator ;;
    xros) sdk=xros ;;
    xrsimulator) sdk=xrsimulator ;;
    macosx) sdk=macosx ;;
    *)
        printf 'Unsupported Apple platform: %s\n' "${PLATFORM_NAME:-}" >&2
        exit 64
        ;;
esac
# 共享 Build Phase 的 CURRENT_ARCH 可能是占位值，此时必须保留 ARCHS 的全部 slice。
arch=${ZD_STRING_ARCH:-${CURRENT_ARCH:-}}
case "$arch" in
    ''|undefined_arch) arch=${ARCHS:-arm64} ;;
esac
ZD_STRING_SDK="$sdk" ZD_STRING_ARCH="$arch" "$embed_script" "$blob" "$section_object" "$arch"

#!/bin/sh
set -eu

# CI 验收最终可执行文件：必须存在密文 section，且不得出现传入的敏感明文。
if [ "$#" -lt 3 ]; then
    printf '%s\n' "usage: verify_macho_artifact.sh --binary <Mach-O> --forbid <plaintext> [--forbid <plaintext> ...]" >&2
    exit 64
fi

binary=
forbidden_file=$(mktemp "${TMPDIR:-/tmp}/zdstring-forbidden.XXXXXX")
trap 'rm -f "$forbidden_file"' EXIT HUP INT TERM
while [ "$#" -gt 0 ]; do
    case "$1" in
        --binary)
            [ "$#" -ge 2 ] || exit 64
            binary=$2
            shift 2
            ;;
        --forbid)
            [ "$#" -ge 2 ] || exit 64
            # 空串会匹配任何内容，必然误报。
            if [ -z "$2" ]; then
                printf '%s\n' "--forbid value must not be empty" >&2
                exit 64
            fi
            printf '%s\n' "$2" >> "$forbidden_file"
            shift 2
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 64
            ;;
    esac
done

if [ -z "$binary" ] || [ ! -f "$binary" ]; then
    printf 'Mach-O not found: %s\n' "$binary" >&2
    exit 66
fi
if ! otool -l "$binary" | awk '$1 == "sectname" && $2 == "__zdstring" { found = 1 } END { exit !found }'; then
    printf '%s\n' "Missing __zdstring Mach-O section" >&2
    exit 1
fi
while IFS= read -r value; do
    if strings -a "$binary" | grep -F -- "$value" >/dev/null; then
        printf 'Plaintext leaked into Mach-O: %s\n' "$value" >&2
        exit 1
    fi
done < "$forbidden_file"

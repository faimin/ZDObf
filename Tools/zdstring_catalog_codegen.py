#!/usr/bin/env python3
"""生成不包含目录明文的 Objective-C 和 Swift 兼容访问器。"""

import argparse
import hashlib
import json
import re
from pathlib import Path


CATALOG_ID_DOMAIN = b"LMStringProtection/catalog-id/v1"
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def catalog_id(value: str) -> int:
    """按 crypto-core 的目录 ID 域取 SHA-256 小端前 64 位。"""
    digest = hashlib.sha256(CATALOG_ID_DOMAIN + value.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "little")


def validate_mapping(mapping: object) -> list[tuple[str, str]]:
    """校验旧目录的 identifier 和路径，拒绝生成不完整的访问器。"""
    if not isinstance(mapping, dict) or not mapping:
        raise ValueError("catalog mapping must be a non-empty object")
    entries = []
    for identifier, value in mapping.items():
        if not isinstance(identifier, str) or not IDENTIFIER_PATTERN.fullmatch(identifier):
            raise ValueError(f"invalid catalog identifier: {identifier!r}")
        if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
            raise ValueError(f"invalid catalog value for {identifier!r}")
        entries.append((identifier, value))
    return entries


def render_catalog(mapping: object) -> dict[str, str]:
    """返回仅由 stable ID 组成的 ObjC 和 Swift 源码。"""
    entries = validate_mapping(mapping)
    declarations = "\n".join(f"+ (NSString *){identifier};" for identifier, _ in entries)
    methods = []
    properties = []
    for identifier, value in entries:
        stable_id = catalog_id(value)
        objc_bytes = ", ".join(f"0x{byte:02x}" for byte in stable_id.to_bytes(8, "little"))
        swift_bytes = ", ".join(f"0x{byte:02x}" for byte in stable_id.to_bytes(8, "little"))
        methods.append(
            "\n".join(
                [
                    f"+ (NSString *){identifier} {{",
                    f"    NSString *value = ZDStringDecodeBytes((const unsigned char[]){{{objc_bytes}}}, 8);",
                    "    return value ?: @\"\";",
                    "}",
                ]
            )
        )
        properties.append(
            "\n".join(
                [
                    f"    public static var {identifier}: String {{",
                    f"        ZDStringDecodeBytes([{swift_bytes}]) ?? \"\"",
                    "    }",
                ]
            )
        )
    objc_header = "\n".join(
        [
            "#import <Foundation/Foundation.h>",
            "",
            "NS_ASSUME_NONNULL_BEGIN",
            "@interface ZDURLPathCatalogObjC : NSObject",
            declarations,
            "@end",
            "NS_ASSUME_NONNULL_END",
            "",
        ]
    )
    objc_implementation = "\n".join(
        [
            '#import "ZDURLPathCatalog.h"',
            '#import <ZDObf/ZDObf.h>',
            "",
            "@implementation ZDURLPathCatalogObjC",
            "",
            "\n\n".join(methods),
            "",
            "@end",
            "",
        ]
    )
    swift = "\n".join(
        [
            "import ZDObf",
            "",
            "public enum ZDURLPathCatalog {",
            "\n\n".join(properties),
            "}",
            "",
        ]
    )
    return {"objc_header": objc_header, "objc": objc_implementation, "swift": swift}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--objc-header", required=True, type=Path)
    parser.add_argument("--objc-implementation", required=True, type=Path)
    parser.add_argument("--swift-output", required=True, type=Path)
    arguments = parser.parse_args()
    mapping = json.loads(arguments.input.read_text(encoding="utf-8"))
    generated = render_catalog(mapping)
    outputs = {
        arguments.objc_header: generated["objc_header"],
        arguments.objc_implementation: generated["objc"],
        arguments.swift_output: generated["swift"],
    }
    for path, content in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    main()

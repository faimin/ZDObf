#!/usr/bin/env python3
"""重新生成 Tests/ZDObfKitTests/Fixture.swift 和 Tests/ZDObfKitObjCTests/Fixture.h（真实工具链生成的 Blob 与 ID）。

用法：先构建 host 工具（cargo build --release -p zd_string_crypto_cli、Generator 的 zig build），再运行本脚本。
Blob 使用 debug + deterministic 模式，同样输入得到同样字节，便于代码审查。
"""
import base64
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "Generator/zig-out/bin/zdstring-gen"
CRYPTO = ROOT / "target/release/zdstring-crypto"
NAMESPACE = "com.example.zdobf.tests"
KEY = bytes(range(32))
SOURCE = '''let url = ZDString("https://api.example.com/v1/user")
let unicode = ZDString("你好，ZDObf!\\n")
let empty = ZDString("")
'''
NAMES = ["url", "unicode", "empty"]
VALUES = ["https://api.example.com/v1/user", "你好，ZDObf!\n", ""]


def main():
    env = {**os.environ, "ZD_STRING_RUNTIME_KEY_B64": base64.b64encode(KEY).decode()}
    with tempfile.TemporaryDirectory() as directory:
        temporary = Path(directory)
        (temporary / "in.swift").write_text(SOURCE, encoding="utf-8")
        run = lambda *arguments: subprocess.run([str(a) for a in arguments], check=True, env=env)
        run(GENERATOR, "scan", "--input", temporary / "in.swift", "--output", temporary / "out.swift",
            "--manifest", temporary / "m.json", "--language", "swift", "--namespace", NAMESPACE)
        run(GENERATOR, "merge-manifests", "--input", temporary / "m.json", "--output", temporary / "merged.json")
        run(GENERATOR, "--manifest", temporary / "merged.json", "--output", temporary / "blob",
            "--crypto-cli", CRYPTO, "--profile", "debug", "--nonce-mode", "deterministic")
        generated = (temporary / "out.swift").read_text(encoding="utf-8")
        blob = (temporary / "blob").read_bytes()
    ids = []
    for match in re.finditer(r"ZDStringDecodeBytes\(\[([^\]]+)\]\)", generated):
        raw = bytes(int(token, 16) for token in match.group(1).replace(" ", "").split(","))
        ids.append(int.from_bytes(raw, "little"))
    assert len(ids) == len(NAMES), ids
    lines = [
        "// 由 regenerate_fixture.py 生成，请勿手工修改。",
        "import Foundation",
        "",
        "enum Fixture {",
        f"    static let namespace = {NAMESPACE!r}".replace("'", '"'),
        "    /// debug + deterministic 模式生成的 Blob（Base64）。",
        f'    static let blobBase64 = "{base64.b64encode(blob).decode()}"',
        "    static var blob: Data { Data(base64Encoded: blobBase64)! }",
        "    /// 构建所用的 32 字节 key：0x00...0x1f。",
        "    static let key = Data((0..<32).map { UInt8($0) })",
        "",
    ]
    for name, value, identifier in zip(NAMES, VALUES, ids):
        lines.append(f"    static let {name}ID: UInt64 = 0x{identifier:016x}")
        escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        lines.append(f'    static let {name}Value = "{escaped}"')
    lines.append("}")
    (ROOT / "Tests/ZDObfKitTests/Fixture.swift").write_text("\n".join(lines) + "\n", encoding="utf-8")

    header = [
        "// 由 Tests/ZDObfKitTests/regenerate_fixture.py 生成，请勿手工修改。",
        "#import <Foundation/Foundation.h>",
        "",
        f'static NSString *const kFixtureBlobBase64 = @"{base64.b64encode(blob).decode()}";',
    ]
    for name, value, identifier in zip(NAMES, VALUES, ids):
        header.append(f"static const uint64_t kFixture{name.capitalize()}ID = 0x{identifier:016x}ULL;")
    (ROOT / "Tests/ZDObfKitObjCTests/Fixture.h").write_text("\n".join(header) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

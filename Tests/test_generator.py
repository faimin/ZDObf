import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
GENERATOR_ROOT = ROOT / "Generator"
GENERATOR = GENERATOR_ROOT / "zig-out" / "bin" / "zdstring-gen"
CATALOG_ID_DOMAIN = b"LMStringProtection/catalog-id/v1"
# 优先使用显式工具链，其次使用 PATH，避免测试绑定开发者机器目录。
ZIG = os.environ.get("ZD_STRING_ZIG") or shutil.which("zig")


class GeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # 通过真实 Zig 二进制构建后再调用，避免只覆盖实现细节而遗漏命令行契约。
        subprocess.run([str(ZIG), "build"], cwd=GENERATOR_ROOT, check=True)

    def scan_source(self, source, language="swift"):
        # 通过真实 CLI 校验改写后的源码和实际送入加密流程的文本。
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            input_path = temporary / "source.txt"
            output_path = temporary / "generated.txt"
            manifest_path = temporary / "manifest.json"
            input_path.write_text(source, encoding="utf-8")
            result = subprocess.run(
                [str(GENERATOR), "scan", "--input", str(input_path),
                 "--output", str(output_path), "--manifest", str(manifest_path),
                 "--language", language, "--namespace", "com.example.scanner"],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                return result, None, None
            return result, output_path.read_text(encoding="utf-8"), json.loads(
                manifest_path.read_text(encoding="utf-8")
            )

    def test_scanner_rewrites_zd_string_to_internal_byte_expression(self):
        result, rewritten, manifest = self.scan_source('let value = ZDString("secret")\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ZDStringDecodeBytes", rewritten)
        self.assertIn("0x", rewritten)
        self.assertNotIn("ZDStringID", rewritten)
        self.assertNotIn('"secret"', rewritten)
        self.assertEqual([entry["text"] for entry in manifest["strings"]], ["secret"])

    def test_scanner_rewrites_objc_zd_string_to_internal_byte_expression(self):
        result, rewritten, manifest = self.scan_source(
            'NSString *value = ZDString(@"secret");\n', "objc"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ZDStringDecodeBytes", rewritten)
        self.assertIn("0x", rewritten)
        self.assertNotIn("ZDStringID", rewritten)
        self.assertNotIn('@"secret"', rewritten)
        self.assertEqual([entry["text"] for entry in manifest["strings"]], ["secret"])

    def test_scanner_preserves_swift_literal_and_nested_comment_contents(self):
        # 普通文本中的示例调用不能被改写，嵌套注释也不能中断真实调用的扫描。
        prefixes = [
            'let example = #"literal " ZDString("secret") "#',
            'let example = ##"literal "# ZDString("secret") "##',
            'let example = """\nExample: " ZDString("secret") "\n"""',
            'let example = #"""\nExample: " ZDString("secret") "\n"""#',
            '/* outer /* inner */ ZDString(dynamic) */',
            'let example = "value \\(String("nested")) ZDString(\\"example\\")"',
            'let example = ##"value \\##(String("nested")) ZDString("secret")"##',
        ]
        for prefix in prefixes:
            with self.subTest(prefix=prefix):
                result, rewritten, manifest = self.scan_source(
                    prefix + '\nlet value = ZDString("real")'
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([entry["text"] for entry in manifest["strings"]], ["real"])
                self.assertIn("ZDStringDecodeBytes", rewritten)

    def test_scanner_preserves_swift_regex_literals(self):
        # Swift 正则字面量中的 ZDString 文本属于正则内容，不能被改写为查询调用。
        prefixes = [
            'let pattern = #/ZDString("example")/#',
            'let pattern = ##/slash /# ZDString("example")/##',
            'let pattern = #/\nZDString("example")\n/#',
            r'let pattern = #/escaped \/ ZDString("example")/#',
        ]
        for prefix in prefixes:
            with self.subTest(prefix=prefix):
                result, rewritten, manifest = self.scan_source(
                    prefix + '\nlet value = ZDString("real")\n'
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("ZDStringDecodeBytes", rewritten)
                self.assertEqual([entry["text"] for entry in manifest["strings"]], ["real"])

    def test_scanner_preserves_objc_cpp_raw_strings(self):
        # 各种 C++ raw 前缀和定界符中的引号不能让扫描器提前进入代码状态。
        for prefix in ("R", "u8R", "uR", "UR", "LR"):
            for delimiter in ("", "tag", "0123456789abcdef"):
                literal = f'{prefix}"{delimiter}(literal " ZDString("raw") "){delimiter}"'
                with self.subTest(literal=literal):
                    source = f'auto raw = {literal};\nNSString *value = ZDString(@"real");\n'
                    result, rewritten, manifest = self.scan_source(source, "objc")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(literal, rewritten)
                    self.assertIn("ZDStringDecodeBytes", rewritten)
                    self.assertEqual([entry["text"] for entry in manifest["strings"]], ["real"])

    def test_scanner_preserves_objc_line_spliced_comments(self):
        # LF 和 CRLF 续行都仍属于 ObjC 单行注释，不能把注释内容加入 Manifest。
        for newline in ("\n", "\r\n"):
            with self.subTest(newline=newline):
                source = (
                    '// continued comment \\' + newline
                    + 'NSString *commented = ZDString(@"commented");\n'
                    + 'NSString *value = ZDString(@"real");\n'
                )
                result, rewritten, manifest = self.scan_source(source, "objc")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('ZDString(@"commented")', rewritten)
                self.assertIn("ZDStringDecodeBytes", rewritten)
                self.assertEqual([entry["text"] for entry in manifest["strings"]], ["real"])

    def test_scanner_rejects_ambiguous_bare_regex_with_protected_call(self):
        # 无 # 的正则与除法词法歧义暂不自动改写，避免静默修改正则内容。
        result, _, _ = self.scan_source('let pattern = /ZDString("example")/\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UnsupportedLiteral", result.stderr)

    def test_scanner_keeps_division_and_swift_comment_semantics(self):
        # 普通除法不应被当成带定界符正则，Swift 注释也不采用 ObjC 的续行语义。
        source = '// Swift comment \\\nlet ratio = 10 / 2\nlet value = ZDString("real")\n'
        result, rewritten, manifest = self.scan_source(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("let ratio = 10 / 2", rewritten)
        self.assertEqual([entry["text"] for entry in manifest["strings"]], ["real"])

    def test_scanner_rejects_protected_calls_inside_interpolation(self):
        # 插值中的调用暂不改写，必须失败以免无提示地把敏感明文交给编译器。
        for source in (
            r'let value = "prefix \(ZDString("secret"))"',
            r'let value = #"prefix \#(ZDString("secret"))"#',
            r'let value = "prefix \(String("nested \(ZDString("secret"))"))"',
        ):
            with self.subTest(source=source):
                result, _, _ = self.scan_source(source)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("UnsupportedLiteral", result.stderr)

    def test_scanner_rejects_objc_octal_escapes_without_corrupting_text(self):
        # 不支持的八进制转义必须构建失败，不能当作 NUL 和后续数字处理。
        for escaped in (r"\01", r"\012", r"\077"):
            with self.subTest(escaped=escaped):
                result, _, _ = self.scan_source(
                    f'NSString *value = ZDString(@"{escaped}");', "objc"
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("UnsupportedLiteral", result.stderr)

    def test_scanner_keeps_supported_nul_escapes_and_objc_character_literals(self):
        # Swift 不采用八进制转义，ObjC 字符常量里的引号也不能污染词法状态。
        cases = [
            ("swift", r'let value = ZDString("\012")', "\x0012"),
            ("objc", r'''char quote = '"'; NSString *value = ZDString(@"\08");''', "\x008"),
            ("objc", r'NSString *value = ZDString(@"\0tail");', "\x00tail"),
        ]
        for language, source, expected in cases:
            with self.subTest(language=language, source=source):
                result, _, manifest = self.scan_source(source, language)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(manifest["strings"][0]["text"], expected)

    def test_catalog_manifest_uses_stable_path_ids(self):
        # 兼容目录的查询 ID 必须与 App namespace 解耦，后续由 Blob 加密层实现 App 差异。
        paths = {
            "token": "/api/thanos/im/token/get",
            "device": "/device/isBanned",
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            input_path = temporary_path / "catalog.json"
            output_path = temporary_path / "catalog.manifest.json"
            input_path.write_text(json.dumps(paths), encoding="utf-8")

            subprocess.run(
                [
                    str(GENERATOR),
                    "catalog-manifest",
                    "--input",
                    str(input_path),
                    "--output",
                    str(output_path),
                    "--namespace",
                    "com.example.catalog",
                ],
                check=True,
            )

            manifest = json.loads(output_path.read_text(encoding="utf-8"))

        self.assertEqual(manifest["version"], 1)
        self.assertEqual(manifest["app_namespace"], "com.example.catalog")
        self.assertEqual(
            manifest["strings"][0]["id"],
            self.catalog_id(paths["token"]),
        )
        self.assertEqual(
            manifest["strings"][1]["id"],
            self.catalog_id(paths["device"]),
        )

    @staticmethod
    def catalog_id(value):
        # Python 仅复算公开字节协议，验证 Zig 输出可被 Rust 兼容 Manifest 解析。
        digest = hashlib.sha256(CATALOG_ID_DOMAIN + value.encode("utf-8")).digest()
        return f"0x{int.from_bytes(digest[:8], 'little'):016x}"


if __name__ == "__main__":
    unittest.main()

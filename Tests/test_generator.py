import base64
import hashlib
import hmac
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
# 扫描阶段的稳定 ID 由构建 key 派生，所有 scan 调用都必须提供 key。
TEST_KEY = bytes([0x11]) * 32
SCAN_ENV = {**os.environ, "ZD_STRING_RUNTIME_KEY_B64": base64.b64encode(TEST_KEY).decode()}


def derive_id(key, namespace, text):
    """独立的 HKDF-SHA256 参考实现，用来校验 Rust 与 Zig 两侧的 ID 派生。"""
    prk = hmac.new(b"LMStringProtection/id/v2", key, hashlib.sha256).digest()
    info = len(namespace).to_bytes(2, "little") + namespace + text
    block = hmac.new(prk, info + b"\x01", hashlib.sha256).digest()
    return block[:8]


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
                capture_output=True, text=True, env=SCAN_ENV,
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

    def test_scanner_rewrites_after_apostrophes_in_objc_directives_and_text(self):
        # 预处理行或孤立撇号不能被当成字符常量，否则后续 ZDString 会静默漏改。
        cases = [
            "#pragma mark - User's info\n",
            "  #  warning don't ship\n",
            "int n = 1'000;\n",
            "// it's a comment\n",
            # 预处理行里合法的字符常量（含引号）仍要按字符常量处理，不能把 " 当成字符串起点。
            "#define kQuote '\"'\n",
            "#define kA 'a' // it's\n",
        ]
        for prefix in cases:
            with self.subTest(prefix=prefix):
                source = prefix + 'NSString *a = ZDString(@"secret1");\n' \
                    'NSString *b = ZDString(@"secret2");\n'
                result, rewritten, manifest = self.scan_source(source, "objc")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("secret1", rewritten)
                self.assertNotIn("secret2", rewritten)
                self.assertEqual(
                    [entry["text"] for entry in manifest["strings"]], ["secret1", "secret2"]
                )

    def test_scanner_ids_match_rust_known_answers(self):
        # 与 crates/crypto-core 的固定向量同源（Python hmac 独立计算），防止两侧 ID 实现漂移。
        result, rewritten, manifest = self.scan_source('let value = ZDString("secret")\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = derive_id(TEST_KEY, b"com.example.scanner", b"secret")
        self.assertEqual(expected.hex(), "3d72c0434a6ce826")
        self.assertIn(", ".join(f"0x{byte:02x}" for byte in expected), rewritten)

    def test_scanner_ids_depend_on_key_and_fail_closed_without_one(self):
        # 没有 key 不能退化成可离线验证的无密钥 ID；换 key 必须得到不同 ID。
        _, first, _ = self.scan_source('let value = ZDString("secret")\n')
        other_env = {**SCAN_ENV, "ZD_STRING_RUNTIME_KEY_B64": base64.b64encode(bytes([0x12]) * 32).decode()}
        for label, env, should_succeed in (
            ("other-key", other_env, True),
            ("missing-key", {k: v for k, v in os.environ.items() if k != "ZD_STRING_RUNTIME_KEY_B64"}, False),
            ("short-key", {**SCAN_ENV, "ZD_STRING_RUNTIME_KEY_B64": base64.b64encode(b"short").decode()}, False),
            ("bad-base64", {**SCAN_ENV, "ZD_STRING_RUNTIME_KEY_B64": "!!!"}, False),
        ):
            with self.subTest(label):
                with tempfile.TemporaryDirectory() as directory:
                    temporary = Path(directory)
                    (temporary / "in.swift").write_text('let value = ZDString("secret")\n', encoding="utf-8")
                    result = subprocess.run(
                        [str(GENERATOR), "scan", "--input", str(temporary / "in.swift"),
                         "--output", str(temporary / "out.swift"), "--manifest", str(temporary / "m.json"),
                         "--language", "swift", "--namespace", "com.example.scanner"],
                        capture_output=True, text=True, env=env,
                    )
                    if should_succeed:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertNotEqual((temporary / "out.swift").read_text(encoding="utf-8"), first)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertFalse((temporary / "out.swift").exists())

    def test_scanner_replaces_comments_with_whitespace(self):
        # 注释等价于空白，剥离后不能让相邻 token 粘连。
        source = 'int v = a/**/b; // tail\nNSString *s = ZDString(@"x");\n'
        result, rewritten, _ = self.scan_source(source, "objc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("a b;", rewritten)
        self.assertNotIn("tail", rewritten)

    def test_scanner_errors_report_file_line_and_column(self):
        # 不支持的写法必须指出位置，而不是只给 Zig 栈追踪。
        source = 'let ok = 1\nlet bad = ZDString("a" + b)\n'
        result, _, _ = self.scan_source(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r"source\.txt:2:11: error: UnsupportedLiteral")

    def test_embed_key_writes_a_masked_owner_only_payload(self):
        # 内嵌 key 模式的唯一配置点是 ZD_STRING_RUNTIME_KEY_B64；载荷里不能出现连续的明文 key。
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "zdkey.bin"
            old_umask = os.umask(0o022)
            try:
                subprocess.run([str(GENERATOR), "embed-key", "--output", str(output)],
                               check=True, env=SCAN_ENV)
            finally:
                os.umask(old_umask)
            payload = output.read_bytes()
            self.assertEqual(len(payload), 72)
            self.assertEqual(payload[:4], b"ZDKY")
            self.assertEqual(payload[4:8], bytes([1, 0, 0, 0]))
            mask, masked = payload[8:40], payload[40:72]
            self.assertEqual(bytes(a ^ b for a, b in zip(mask, masked)), TEST_KEY)
            self.assertNotIn(TEST_KEY[:8], payload)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            # 缺少 key 时失败，且不留下文件。
            missing = Path(directory) / "missing.bin"
            result = subprocess.run(
                [str(GENERATOR), "embed-key", "--output", str(missing)],
                capture_output=True, text=True,
                env={k: v for k, v in os.environ.items() if k != "ZD_STRING_RUNTIME_KEY_B64"},
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(missing.exists())

    def test_scanner_rejects_oversized_namespace(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            (temporary / "in.swift").write_text('let a = ZDString("x")', encoding="utf-8")
            result = subprocess.run(
                [str(GENERATOR), "scan", "--input", str(temporary / "in.swift"),
                 "--output", str(temporary / "o"), "--manifest", str(temporary / "m"),
                 "--language", "swift", "--namespace", "n" * 257],
                capture_output=True, text=True, env=SCAN_ENV,
            )
            self.assertNotEqual(result.returncode, 0)

    def test_scanner_writes_plaintext_manifest_owner_only(self):
        # Manifest 含全部明文，不能按默认 umask 变成组/其他用户可读。
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            input_path = temporary / "source.swift"
            input_path.write_text('let value = ZDString("secret")\n', encoding="utf-8")
            manifest_path = temporary / "manifest.json"
            merged_path = temporary / "merged.json"
            old_umask = os.umask(0o022)
            try:
                subprocess.run(
                    [str(GENERATOR), "scan", "--input", str(input_path),
                     "--output", str(temporary / "out.swift"), "--manifest", str(manifest_path),
                     "--language", "swift", "--namespace", "com.example.scanner"],
                    check=True, env=SCAN_ENV,
                )
                subprocess.run(
                    [str(GENERATOR), "merge-manifests", "--input", str(manifest_path),
                     "--output", str(merged_path)],
                    check=True,
                )
            finally:
                os.umask(old_umask)
            for path in (manifest_path, merged_path):
                self.assertEqual(path.stat().st_mode & 0o777, 0o600, path)

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

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


@unittest.skipUnless(shutil.which("xcrun"), "Apple integration requires Xcode")
class AppleIntegrationTests(unittest.TestCase):
    def run_command(self, arguments, **options):
        # 保留完整编译诊断，确保失败来自真实消费端而不是字符串匹配。
        result = subprocess.run(arguments, capture_output=True, text=True, **options)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_public_header_is_independent_of_source_tree(self):
        # 同时模拟静态 Pod 的符号链接和 framework 的复制头文件布局。
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            source = temporary / "client.m"
            source.write_text('#import <ZDObf/ZDObf.h>\n', encoding="utf-8")
            public = temporary / "Public" / "ZDObf"
            public.mkdir(parents=True)
            (public / "ZDObf.h").symlink_to(ROOT / "Apple/ObjectiveC/ZDObf.h")
            self.run_command(["xcrun", "clang", "-fsyntax-only", "-I", str(public.parent), str(source)])
            framework = temporary / "ZDObf.framework" / "Headers"
            framework.mkdir(parents=True)
            shutil.copyfile(ROOT / "Apple/ObjectiveC/ZDObf.h", framework / "ZDObf.h")
            self.run_command(["xcrun", "clang", "-fsyntax-only", "-F", str(temporary), str(source)])

    def test_embedded_section_links_into_each_apple_platform(self):
        # 必须真正链接 device/simulator 可执行文件，不能只检查 .o 是否包含 section。
        cases = [
            ("iphoneos", "arm64", "arm64-apple-ios13.0", "IOS"),
            ("iphonesimulator", "arm64", "arm64-apple-ios14.0-simulator", "IOSSIMULATOR"),
            ("iphonesimulator", "x86_64", "x86_64-apple-ios13.0-simulator", "IOSSIMULATOR"),
        ]
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            blob = temporary / "blob"
            blob.write_bytes(b"LMST-test-section")
            source = temporary / "main.c"
            source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
            for sdk, arch, target, platform in cases:
                with self.subTest(sdk=sdk, arch=arch):
                    section = temporary / f"{sdk}-{arch}.o"
                    binary = temporary / f"{sdk}-{arch}"
                    self.run_command(
                        [str(ROOT / "scripts/embed_macho_section.sh"), str(blob), str(section), arch],
                        env={**os.environ, "ZD_STRING_SDK": sdk},
                    )
                    sdk_path = self.run_command(["xcrun", "--sdk", sdk, "--show-sdk-path"]).strip()
                    self.run_command(["xcrun", "clang", "-target", target, "-isysroot", sdk_path,
                                      str(source), str(section), "-Wl,-dead_strip", "-o", str(binary)])
                    self.assertIn(platform, self.run_command(["xcrun", "vtool", "-show-build", str(binary)]))
                    self.assertIn("__zdstring", self.run_command(["xcrun", "otool", "-l", str(binary)]))

    def test_embedded_section_preserves_all_simulator_architectures(self):
        # Xcode 的共享构建阶段可能一次收到多个架构，section 输入必须包含每个 slice。
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            blob = temporary / "blob"
            blob.write_bytes(b"LMST-test-section")
            section = temporary / "universal.o"
            self.run_command(
                [str(ROOT / "scripts/embed_macho_section.sh"), str(blob), str(section), "arm64 x86_64"],
                env={**os.environ, "ZD_STRING_SDK": "iphonesimulator", "IPHONEOS_DEPLOYMENT_TARGET": "13.0"},
            )
            self.assertEqual(set(self.run_command(["xcrun", "lipo", "-archs", str(section)]).split()),
                             {"arm64", "x86_64"})


if __name__ == "__main__":
    unittest.main()

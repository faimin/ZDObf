import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "xcode_build_phase.sh"
GENERATOR = ROOT / "Generator" / "zig-out" / "bin" / "zdstring-gen"
# 测试使用显式配置或 PATH 工具链，不依赖开发者机器的绝对路径。
ZIG = os.environ.get("ZD_STRING_ZIG") or shutil.which("zig")


class XcodeBuildPhaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # 使用当前锁定的 Zig 构建真实 Generator，测试构建阶段的命令行边界。
        subprocess.run([str(ZIG), "build"], cwd=ROOT / "Generator", check=True)

    def test_catalog_mapping_can_run_without_source_map(self):
        # 目录兼容模式不要求业务源码预处理，但仍必须产出最终链接输入。
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            mapping = temporary_path / "catalog.json"
            mapping.write_text(json.dumps({"token": "/v1/token"}), encoding="utf-8")
            crypto = temporary_path / "fake-crypto.py"
            crypto.write_text(
                "#!/usr/bin/env python3\n"
                "import pathlib, sys\n"
                "output = sys.argv[sys.argv.index('--output') + 1]\n"
                "if output == '-':\n"
                "    sys.stdout.buffer.write(b'blob')\n"
                "else:\n"
                "    pathlib.Path(output).write_bytes(b'blob')\n",
                encoding="utf-8",
            )
            embed = temporary_path / "fake-embed.py"
            embed.write_text(
                "#!/usr/bin/env python3\n"
                "import pathlib, sys\n"
                "pathlib.Path(sys.argv[2]).write_bytes(b'object')\n"
                "pathlib.Path(sys.argv[2] + '.arch').write_text(sys.argv[3])\n",
                encoding="utf-8",
            )
            for executable in (crypto, embed):
                executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
            derived = temporary_path / "derived"
            section = temporary_path / "section.o"
            environment = {
                **os.environ,
                "ZD_STRING_CATALOG_MAPPING": str(mapping),
                "ZD_STRING_NAMESPACE": "com.example.catalog",
                # 故意传入无关 App 根目录，确保脚本从自身目录寻找默认扫描器。
                "SRCROOT": str(temporary_path / "consumer-app"),
                "ZD_STRING_CRYPTO_CLI": str(crypto),
                "ZD_STRING_EMBED_SCRIPT": str(embed),
                "ZD_STRING_DERIVED_DIR": str(derived),
                "ZD_STRING_SECTION_OBJECT": str(section),
                "ZD_STRING_PROFILE": "debug",
                "ZD_STRING_NONCE_MODE": "deterministic",
                # 模拟共享构建阶段的占位架构，必须回退到完整 ARCHS 列表。
                "CURRENT_ARCH": "undefined_arch",
                "ARCHS": "arm64 x86_64",
            }
            result = subprocess.run(
                [str(SCRIPT)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((derived / "strings.manifest.json").is_file())
            self.assertEqual((derived / "strings.zdstr").read_bytes(), b"blob")
            self.assertEqual(section.read_bytes(), b"object")
            self.assertEqual(Path(str(section) + ".arch").read_text(), "arm64 x86_64")

            source_map = temporary_path / "source-map.txt"
            generated_source = temporary_path / "generated.swift"
            source_map.write_text(
                f"{ROOT / 'Tests' / 'fixtures' / 'source.swift'}|{generated_source}|swift\n",
                encoding="utf-8",
            )
            source_environment = dict(environment)
            source_environment.pop("ZD_STRING_CATALOG_MAPPING")
            source_result = subprocess.run(
                [str(SCRIPT), str(source_map)],
                cwd=ROOT,
                env=source_environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(source_result.returncode, 0, source_result.stderr)
            self.assertIn("ZDStringID(0x", generated_source.read_text(encoding="utf-8"))

            # source-map 最后一行没有换行时也必须生成对应源码和 Blob。
            source_map.write_text(
                f"{ROOT / 'Tests' / 'fixtures' / 'source.swift'}|{generated_source}|swift",
                encoding="utf-8",
            )
            no_newline_result = subprocess.run(
                [str(SCRIPT), str(source_map)],
                cwd=ROOT,
                env=source_environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(no_newline_result.returncode, 0, no_newline_result.stderr)
            self.assertIn("ZDStringID(0x", generated_source.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()

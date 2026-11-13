import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


@unittest.skipUnless(
    shutil.which("swift") and shutil.which("ditto") and shutil.which("shasum"),
    "Release pinning requires macOS tooling",
)
class RuntimeReleaseTests(unittest.TestCase):
    def make_sandbox(self, temporary):
        # 在临时目录复制 Package.swift 与脚本，绝不改动真实仓库。
        sandbox = temporary / "repo"
        (sandbox / "scripts").mkdir(parents=True)
        (sandbox / "Apple/Swift").mkdir(parents=True)
        (sandbox / "Apple/ObjectiveC").mkdir(parents=True)
        shutil.copy(ROOT / "Package.swift", sandbox / "Package.swift")
        for name in ("pin_runtime_release.sh", "fetch_runtime.sh"):
            shutil.copy(ROOT / "scripts" / name, sandbox / "scripts" / name)
        return sandbox

    def make_archive(self, temporary):
        source = temporary / "archive-src" / "ZDObfRuntime.xcframework"
        source.mkdir(parents=True)
        (source / "Info.plist").write_text("fake", encoding="utf-8")
        archive = temporary / "ZDObfRuntime.xcframework.zip"
        subprocess.run(
            ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(source), str(archive)],
            check=True,
        )
        return archive

    def dump_binary_target(self, sandbox, environment=None):
        result = subprocess.run(
            ["swift", "package", "--disable-package-manifest-caching", "dump-package"], cwd=sandbox, capture_output=True, text=True,
            env={**os.environ, **(environment or {})},
        )
        return result

    def test_pin_fetch_and_remote_binary_target(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            sandbox = self.make_sandbox(temporary)
            archive = self.make_archive(temporary)

            # 未固定且本地没有 dist：清晰失败，而不是生成无效的 binaryTarget。
            unpinned = self.dump_binary_target(sandbox)
            self.assertNotEqual(unpinned.returncode, 0)
            fetch = subprocess.run(
                ["sh", str(sandbox / "scripts/fetch_runtime.sh")], capture_output=True, text=True
            )
            self.assertEqual(fetch.returncode, 65, fetch.stderr)

            subprocess.run(
                ["sh", str(sandbox / "scripts/pin_runtime_release.sh"), "1.2.3", str(archive)],
                check=True, capture_output=True,
            )
            checksum = subprocess.run(
                ["shasum", "-a", "256", str(archive)], check=True, capture_output=True, text=True
            ).stdout.split()[0]
            # 固定后无本地 dist 时必须落到 URL + checksum。
            package = json.loads(self.dump_binary_target(sandbox).stdout)
            runtime = next(t for t in package["targets"] if t["name"] == "ZDObfRuntime")
            self.assertEqual(runtime["type"], "binary")
            self.assertEqual(runtime["checksum"], checksum)
            self.assertEqual(
                runtime["url"],
                "https://github.com/faimin/ZDObf/releases/download/v1.2.3/ZDObfRuntime.xcframework.zip",
            )
            # swift 官方工具算出的 checksum 必须与脚本一致。
            official = subprocess.run(
                ["swift", "package", "compute-checksum", str(archive)],
                cwd=sandbox, check=True, capture_output=True, text=True,
            ).stdout.strip()
            self.assertEqual(official, checksum)

            # 下载、校验并安装；之后本地 dist 优先。
            environment = {**os.environ, "ZDOBF_RUNTIME_URL": archive.as_uri()}
            subprocess.run(
                ["sh", str(sandbox / "scripts/fetch_runtime.sh")],
                check=True, capture_output=True, env=environment,
            )
            self.assertTrue((sandbox / "dist/ZDObfRuntime.xcframework/Info.plist").is_file())
            local = json.loads(self.dump_binary_target(sandbox).stdout)
            runtime = next(t for t in local["targets"] if t["name"] == "ZDObfRuntime")
            self.assertEqual(runtime["path"], "dist/ZDObfRuntime.xcframework")
            forced = json.loads(
                self.dump_binary_target(sandbox, {"ZDOBF_USE_RELEASE_RUNTIME": "1"}).stdout
            )
            runtime = next(t for t in forced["targets"] if t["name"] == "ZDObfRuntime")
            self.assertEqual(runtime["checksum"], checksum)

    def test_fetch_rejects_checksum_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            sandbox = self.make_sandbox(temporary)
            archive = self.make_archive(temporary)
            subprocess.run(
                ["sh", str(sandbox / "scripts/pin_runtime_release.sh"), "1.2.3", str(archive)],
                check=True, capture_output=True,
            )
            tampered = temporary / "tampered.zip"
            tampered.write_bytes(archive.read_bytes() + b"x")
            result = subprocess.run(
                ["sh", str(sandbox / "scripts/fetch_runtime.sh")],
                capture_output=True, text=True,
                env={**os.environ, "ZDOBF_RUNTIME_URL": tampered.as_uri()},
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("Checksum mismatch", result.stderr)
            self.assertFalse((sandbox / "dist").exists())


if __name__ == "__main__":
    unittest.main()

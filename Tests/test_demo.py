import os
import platform
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
DEMO = ROOT / "Examples" / "ZDObfDemo"
VERIFY = ROOT / "scripts" / "verify_macho_artifact.sh"
SECRETS = [
    "https://api.example.com/v1/user",
    "analytics.example.com",
    "protected at build time",
]


@unittest.skipUnless(
    platform.system() == "Darwin" and shutil.which("xcodebuild")
    and shutil.which("zig") and shutil.which("cargo"),
    "demo build requires macOS, Xcode, Zig and Cargo",
)
class DemoProjectTests(unittest.TestCase):
    def test_demo_builds_runs_and_hides_its_strings(self):
        # 用 Demo 的 Xcode 工程走完整接入流程：Build Phase 扫描加密 → 链接 section → 运行时解密。
        subprocess.run(["sh", str(DEMO / "Scripts" / "bootstrap.sh")], check=True, capture_output=True)
        generated = DEMO / "Generated"
        shutil.rmtree(generated, ignore_errors=True)
        with tempfile.TemporaryDirectory() as derived:
            build = subprocess.run(
                ["xcodebuild", "-project", str(DEMO / "ZDObfDemo.xcodeproj"), "-scheme", "ZDObfDemo",
                 "-configuration", "Debug", "-derivedDataPath", derived, "build"],
                capture_output=True, text=True,
            )
            self.assertEqual(build.returncode, 0, build.stdout[-3000:] + build.stderr[-2000:])
            binary = Path(derived) / "Build" / "Products" / "Debug" / "ZDObfDemo"

            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn("user url : https://api.example.com/v1/user", run.stdout)
            self.assertIn("你好，ZDObf!", run.stdout)
            self.assertIn("objc host: analytics.example.com", run.stdout)
            self.assertIn("unknown id is reported as invalidID", run.stdout)

            # 生成源码和最终二进制都不含明文，且存在密文 section。
            for generated_file in generated.iterdir():
                text = generated_file.read_text(encoding="utf-8")
                for secret in SECRETS:
                    self.assertNotIn(secret, text, generated_file.name)
            arguments = ["sh", str(VERIFY), "--binary", str(binary)]
            for secret in SECRETS:
                arguments += ["--forbid", secret]
            subprocess.run(arguments, check=True, capture_output=True)
        shutil.rmtree(generated, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()

import base64
import os
import platform
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
BUILD_PHASE = ROOT / "scripts" / "xcode_build_phase.sh"
GENERATOR = ROOT / "Generator" / "zig-out" / "bin" / "zdstring-gen"
XCFRAMEWORK_MACOS = ROOT / "dist" / "ZDObfRuntime.xcframework" / "macos-arm64_x86_64"
ZIG = os.environ.get("ZD_STRING_ZIG") or shutil.which("zig")
CARGO = shutil.which("cargo")
KEY = bytes(range(32))
SECRET = "https://e2e-secret.example.com/v1/token"
NAMESPACE = "com.example.e2e"

# ObjC 源码里故意放一个预处理撇号，回归扫描器漏改（明文残留）问题。
SOURCE = f"""#import <Foundation/Foundation.h>
#import "ZDObf.h"
#pragma mark - User's info
NSString *E2ESecret(void) {{ return ZDString(@"{SECRET}"); }}
"""

MAIN = """#import <Foundation/Foundation.h>
#import "ZDObf.h"
NSString *E2ESecret(void);
int main(int argc, char **argv) {
    @autoreleasepool {
        unsigned char key[32];
        for (int index = 0; index < 32; index++) key[index] = (unsigned char)index;
        if (argc > 1) key[0] ^= 0xff;  // 错误 key 必须初始化失败
        NSError *error = nil;
        BOOL ok = ZDObfInitializeEmbedded([NSData dataWithBytes:key length:32], &error);
        if (!ok) { printf("init-failed\\n"); return 3; }
        printf("%s\\n", E2ESecret().UTF8String);
    }
    return 0;
}
"""


@unittest.skipUnless(
    platform.system() == "Darwin" and shutil.which("xcrun") and ZIG and CARGO,
    "end-to-end test requires macOS, Xcode, Zig and Cargo",
)
class EndToEndTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # dist/ 不入库：缺失时按 Package.swift 固定的 Release 资产下载并校验。
        if not XCFRAMEWORK_MACOS.is_dir():
            subprocess.run(["sh", str(ROOT / "scripts" / "fetch_runtime.sh")], check=True)
        subprocess.run([str(ZIG), "build"], cwd=ROOT / "Generator", check=True)
        subprocess.run(
            [CARGO, "build", "--locked", "-q", "-p", "zd_string_crypto_cli"],
            cwd=ROOT, check=True,
        )
        cls.crypto_cli = ROOT / "target" / "debug" / "zdstring-crypto"

    def run_checked(self, arguments, **options):
        result = subprocess.run(arguments, capture_output=True, text=True, **options)
        self.assertEqual(result.returncode, 0, f"{arguments}\n{result.stderr}")
        return result

    def test_scan_encrypt_embed_link_and_decrypt(self):
        arch = {"arm64": "arm64", "aarch64": "arm64"}.get(platform.machine(), "x86_64")
        runtime = next(XCFRAMEWORK_MACOS.glob("*.a"))
        sdk = self.run_checked(["xcrun", "--show-sdk-path"]).stdout.strip()
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            source = temporary / "source.mm"
            generated = temporary / "generated.mm"
            source.write_text(SOURCE, encoding="utf-8")
            source_map = temporary / "source-map.txt"
            source_map.write_text(f"{source}|{generated}|objc\n", encoding="utf-8")
            derived = temporary / "derived"
            environment = {
                **os.environ,
                "ZD_STRING_NAMESPACE": NAMESPACE,
                "ZD_STRING_DERIVED_DIR": str(derived),
                "ZD_STRING_GENERATOR": str(GENERATOR),
                "ZD_STRING_CRYPTO_CLI": str(self.crypto_cli),
                "ZD_STRING_RUNTIME_KEY_B64": base64.b64encode(KEY).decode(),
                "PLATFORM_NAME": "macosx",
                "ZD_STRING_ARCH": arch,
                "MACOSX_DEPLOYMENT_TARGET": "15.0",
            }
            self.run_checked([str(BUILD_PHASE), str(source_map)], cwd=ROOT, env=environment)

            # 生成源码里不能残留任何明文，且构建目录不留下明文 Manifest。
            self.assertNotIn(SECRET, generated.read_text(encoding="utf-8"))
            self.assertIn("ZDStringDecodeBytes", generated.read_text(encoding="utf-8"))
            self.assertFalse((derived / "strings.manifest.json").exists())

            main = temporary / "main.mm"
            main.write_text(MAIN, encoding="utf-8")
            common = ["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-arch", arch,
                      "-isysroot", sdk, "-mmacosx-version-min=15.0"]
            # wrapper 放在动态库里，覆盖 CocoaPods 动态 framework 场景（不能依赖 _mh_execute_header）。
            dylib = temporary / "libzdobf.dylib"
            self.run_checked(common + [
                "-dynamiclib", "-framework", "Foundation",
                str(ROOT / "Apple/ObjectiveC/ZDObf.mm"), str(runtime),
                "-install_name", "@rpath/libzdobf.dylib", "-o", str(dylib),
            ])
            app = temporary / "app"
            self.run_checked(common + [
                "-I", str(ROOT / "Apple/ObjectiveC"), "-framework", "Foundation",
                str(main), str(generated), str(derived / "zdstring-section.o"),
                "-L", str(temporary), "-lzdobf", "-Wl,-rpath,@loader_path",
                "-o", str(app),
            ])

            # 明文既不在源码、也不在最终二进制里。
            self.assertNotIn(SECRET.encode(), app.read_bytes())
            self.assertNotIn(SECRET.encode(), dylib.read_bytes())

            result = self.run_checked([str(app)])
            self.assertEqual(result.stdout.strip(), SECRET)

            wrong = subprocess.run([str(app), "wrong-key"], capture_output=True, text=True)
            self.assertEqual(wrong.returncode, 3)
            self.assertIn("init-failed", wrong.stdout)


if __name__ == "__main__":
    unittest.main()

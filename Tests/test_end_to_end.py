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

# 内嵌 key 模式：App 不持有也不传入任何 key。
MAIN_BUILTIN_KEY = """#import <Foundation/Foundation.h>
#import "ZDObf.h"
NSString *E2ESecret(void);
int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        if (!ZDObfInitializeEmbeddedWithBuiltInKey(&error)) { printf("init-failed %ld\\n", (long)error.code); return 3; }
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

    def prepare(self, temporary, embed_key=False):
        """运行 Build Phase，返回 (arch, sdk, runtime, generated, derived)。"""
        arch = {"arm64": "arm64", "aarch64": "arm64"}.get(platform.machine(), "x86_64")
        runtime = next(XCFRAMEWORK_MACOS.glob("*.a"))
        sdk = self.run_checked(["xcrun", "--show-sdk-path"]).stdout.strip()
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
        if embed_key:
            environment["ZD_STRING_EMBED_KEY"] = "1"
        self.run_checked([str(BUILD_PHASE), str(source_map)], cwd=ROOT, env=environment)

        # 生成源码里不能残留任何明文，且构建目录不留下明文 Manifest（内嵌 key 模式也不留 key 载荷）。
        self.assertNotIn(SECRET, generated.read_text(encoding="utf-8"))
        self.assertIn("ZDStringDecodeBytes", generated.read_text(encoding="utf-8"))
        self.assertFalse((derived / "strings.manifest.json").exists())
        self.assertFalse((derived / "zdkey.bin").exists())
        return arch, sdk, runtime, generated, derived

    def test_embedded_builtin_key_mode(self):
        # 只在构建环境配置一次 key：运行时无需传 key，key 也不会以明文字节出现在二进制里。
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            arch, sdk, runtime, generated, derived = self.prepare(temporary, embed_key=True)
            common = ["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-arch", arch,
                      "-isysroot", sdk, "-mmacosx-version-min=15.0"]
            main = temporary / "main.mm"
            main.write_text(MAIN_BUILTIN_KEY, encoding="utf-8")
            app = temporary / "app"
            self.run_checked(common + [
                "-I", str(ROOT / "Apple/ObjectiveC"), "-framework", "Foundation",
                str(main), str(generated), str(derived / "zdstring-section.o"),
                str(ROOT / "Apple/ObjectiveC/ZDObf.mm"), str(runtime), "-o", str(app),
            ])
            binary = app.read_bytes()
            self.assertNotIn(KEY, binary, "key 不能以明文字节出现")
            self.assertNotIn(SECRET.encode(), binary)
            self.assertIn(b"ZDKY", binary)
            self.assertEqual(self.run_checked([str(app)]).stdout.strip(), SECRET)

            # 没有开启内嵌 key 模式构建的二进制调用无参初始化，必须失败而不是崩溃。
            plain_dir = temporary / "plain"
            plain_dir.mkdir()
            arch, sdk, runtime, generated, derived = self.prepare(plain_dir, embed_key=False)
            plain = plain_dir / "app"
            self.run_checked(common + [
                "-I", str(ROOT / "Apple/ObjectiveC"), "-framework", "Foundation",
                str(main), str(generated), str(derived / "zdstring-section.o"),
                str(ROOT / "Apple/ObjectiveC/ZDObf.mm"), str(runtime), "-o", str(plain),
            ])
            result = subprocess.run([str(plain)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 3)
            self.assertIn("init-failed", result.stdout)

    def test_scan_encrypt_embed_link_and_decrypt(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            arch, sdk, runtime, generated, derived = self.prepare(temporary)
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
            section_object = str(derived / "zdstring-section.o")
            rpath = ["-L", str(temporary), "-lzdobf", "-Wl,-rpath,@loader_path"]
            apps = {}
            # 布局一：section 随业务代码链接进主可执行文件。
            executable = temporary / "app-executable"
            self.run_checked(common + [
                "-I", str(ROOT / "Apple/ObjectiveC"), "-framework", "Foundation",
                str(main), str(generated), section_object, *rpath, "-o", str(executable),
            ])
            apps["executable"] = executable
            # 布局二：模拟 Xcode 的 ENABLE_DEBUG_DYLIB，主可执行文件只是壳，section 在 debug dylib 里。
            debug_dylib = temporary / "libapp.debug.dylib"
            self.run_checked(common + [
                "-dynamiclib", "-I", str(ROOT / "Apple/ObjectiveC"), "-framework", "Foundation",
                str(generated), section_object, *rpath,
                "-install_name", "@rpath/libapp.debug.dylib", "-o", str(debug_dylib),
            ])
            stub = temporary / "app-stub"
            self.run_checked(common + [
                "-I", str(ROOT / "Apple/ObjectiveC"), "-framework", "Foundation",
                str(main), "-lapp.debug", *rpath, "-o", str(stub),
            ])
            apps["debug-dylib"] = stub

            # 明文既不在源码、也不在最终二进制里。
            for binary in (*apps.values(), dylib, debug_dylib):
                self.assertNotIn(SECRET.encode(), binary.read_bytes())

            for layout, app in apps.items():
                with self.subTest(layout=layout):
                    result = self.run_checked([str(app)])
                    self.assertEqual(result.stdout.strip(), SECRET)

                    wrong = subprocess.run([str(app), "wrong-key"], capture_output=True, text=True)
                    self.assertEqual(wrong.returncode, 3)
                    self.assertIn("init-failed", wrong.stdout)


if __name__ == "__main__":
    unittest.main()

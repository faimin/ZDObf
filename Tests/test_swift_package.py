import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


@unittest.skipUnless(shutil.which("swift"), "Swift Package Manager requires Swift")
class SwiftPackageTests(unittest.TestCase):
    def test_manifest_exposes_swift_and_objective_c_products(self):
        result = subprocess.run(
            ["swift", "package", "dump-package"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        package = json.loads(result.stdout)
        products = {product["name"] for product in package["products"]}
        targets = {target["name"] for target in package["targets"]}
        self.assertEqual(products, {"ZDObfKit", "ZDObfKitObjC"})
        self.assertTrue({"ZDObfRuntime", "ZDObfKit", "ZDObfKitObjC"}.issubset(targets))

    @unittest.skipUnless(shutil.which("xcrun"), "Runtime linking requires an Apple SDK")
    def test_swift_consumer_links_embedded_bootstrap_and_runtime(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            (temporary / "Package.swift").write_text(
                '// swift-tools-version: 6.0\n'
                'import PackageDescription\n'
                'let package = Package(name: "Consumer", platforms: [.macOS(.v15)], '
                f'dependencies: [.package(name: "ZDObf", path: {json.dumps(str(ROOT))})], '
                'targets: [.executableTarget(name: "Consumer", dependencies: '
                '[.product(name: "ZDObfKit", package: "ZDObf")], path: "Sources")])\n',
                encoding="utf-8",
            )
            (temporary / "Sources").mkdir()
            (temporary / "Sources/main.swift").write_text(
                'import Foundation\n'
                'import ZDObfKit\n'
                'do {\n'
                '    try ZDObf.initializeEmbedded(key: Data(repeating: 0, count: 32))\n'
                '    fatalError("Unexpected initialization without a Blob section")\n'
                '} catch ZDObfError.malformedBlob {\n'
                '    print("embedded bootstrap linked")\n'
                '}\n',
                encoding="utf-8",
            )
            result = subprocess.run(
                ["swift", "run", "Consumer"],
                cwd=temporary,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("embedded bootstrap linked", result.stdout)


if __name__ == "__main__":
    unittest.main()

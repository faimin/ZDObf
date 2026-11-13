import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
MODULE_PATH = ROOT / "Tools" / "zdstring_catalog_codegen.py"
FIXTURE = ROOT / "Tests" / "fixtures" / "catalog_paths.json"


def load_codegen_module():
    specification = importlib.util.spec_from_file_location("zdstring_catalog_codegen", MODULE_PATH)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class CatalogCodegenTests(unittest.TestCase):
    def test_generated_accessors_only_contain_stable_ids(self):
        # 生成源码可以参与 Pod 编译，但不能把目录明文重新交给编译器。
        module = load_codegen_module()
        mapping = json.loads(FIXTURE.read_text(encoding="utf-8"))
        generated = module.render_catalog(mapping)

        self.assertEqual(len(mapping), 10)
        self.assertIn("ZDStringDecodeBytes", generated["objc"])
        self.assertIn("ZDStringDecodeBytes", generated["swift"])
        self.assertNotIn("ZDStringID", generated["objc"])
        self.assertNotIn("ZDStringID", generated["swift"])
        for value in mapping.values():
            self.assertNotIn(value, generated["objc"])
            self.assertNotIn(value, generated["swift"])

    def test_reserved_identifiers_are_rejected(self):
        # 关键字或会覆盖 NSObject 类方法的名字生成出来无法编译/行为异常，必须提前拒绝。
        module = load_codegen_module()
        for identifier in ("class", "init", "description", "new", "let"):
            with self.subTest(identifier=identifier):
                with self.assertRaises(ValueError):
                    module.render_catalog({identifier: "/v1/path"})
        module.render_catalog({"classPath": "/v1/path"})


if __name__ == "__main__":
    unittest.main()

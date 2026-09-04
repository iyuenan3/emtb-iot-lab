import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "emtb_ble_control.swift"
SHARED = ROOT / "Shared"


class MacToolTests(unittest.TestCase):
    def test_tool_compiles_with_shared_engine(self):
        with tempfile.TemporaryDirectory(prefix="emtb-mac-tool-test-") as output:
            result = subprocess.run(
                [
                    "/usr/bin/xcrun",
                    "swiftc",
                    "-module-cache-path",
                    str(pathlib.Path(output) / "module-cache"),
                    str(SHARED / "BikeWireProtocol.swift"),
                    str(SHARED / "BikeControlEngine.swift"),
                    str(TOOL),
                    "-o",
                    str(pathlib.Path(output) / "emtb-ble-control"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_tool_is_one_shot_and_does_not_print_secrets(self):
        source = TOOL.read_text()
        self.assertIn("<unlock|lock> --physical-ready", source)
        self.assertEqual(source.count("peripheral.writeValue("), 1)
        self.assertNotRegex(source.lower(), r"\bretry\b")
        self.assertNotIn("print(key", source.lower())
        self.assertNotIn("print(mac", source.lower())
        self.assertNotIn("source .env.local", source)


if __name__ == "__main__":
    unittest.main()

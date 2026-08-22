import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "IoTBluetooth"
HARNESS = ROOT / "tests" / "BLEControlSessionHarness.swift"


class ControlSessionTests(unittest.TestCase):
    def test_callback_order_and_single_action_contract(self):
        with tempfile.TemporaryDirectory(prefix="emtb-ble-session-") as temporary:
            temporary_path = Path(temporary)
            executable = temporary_path / "ble-control-session-tests"
            module_cache = temporary_path / "module-cache"
            environment = os.environ.copy()
            environment["CLANG_MODULE_CACHE_PATH"] = str(module_cache)
            environment["SWIFT_MODULECACHE_PATH"] = str(module_cache)
            compile_result = subprocess.run(
                [
                    "/usr/bin/xcrun",
                    "swiftc",
                    "-module-cache-path",
                    str(module_cache),
                    str(SOURCE / "OmniProtocol.swift"),
                    str(SOURCE / "Models.swift"),
                    str(HARNESS),
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                compile_result.stdout + compile_result.stderr,
            )
            run_result = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(
                run_result.returncode,
                0,
                run_result.stdout + run_result.stderr,
            )


if __name__ == "__main__":
    unittest.main()

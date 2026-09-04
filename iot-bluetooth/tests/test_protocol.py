import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SHARED = ROOT / "Shared"
HARNESS = pathlib.Path(__file__).with_name("BikeProtocolHarness.swift")


class BikeProtocolTests(unittest.TestCase):
    def test_protocol_and_control_engine(self):
        with tempfile.TemporaryDirectory(prefix="emtb-protocol-test-") as output:
            executable = pathlib.Path(output) / "bike-protocol-tests"
            result = subprocess.run(
                [
                    "/usr/bin/xcrun",
                    "swiftc",
                    "-module-cache-path",
                    str(pathlib.Path(output) / "module-cache"),
                    str(SHARED / "BikeWireProtocol.swift"),
                    str(SHARED / "BikeControlEngine.swift"),
                    str(HARNESS),
                    "-o",
                    str(executable),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            run = subprocess.run(
                [str(executable)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("BikeProtocolHarness: PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()

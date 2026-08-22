import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "IoTBluetooth"
MANAGER = (SOURCE / "BLEDeviceManager.swift").read_text()
CONTENT = (SOURCE / "ContentView.swift").read_text()
PROTOCOL = (SOURCE / "OmniProtocol.swift").read_text()
APP = (SOURCE / "IoTBluetoothApp.swift").read_text()
PROJECT = (ROOT / "IoTBluetooth.xcodeproj" / "project.pbxproj").read_text()


class SourceGuardTests(unittest.TestCase):
    def test_app_target_is_ble_only(self):
        excluded = (
            "RemoteControlManager.swift",
            "RemoteControlView.swift",
            "PendingBLEEventStore.swift",
        )
        for name in excluded:
            self.assertNotIn(name, PROJECT)
        self.assertNotIn("RemoteControlManager", APP)
        self.assertNotIn("URLSession", MANAGER + CONTENT + APP)

    def test_protocol_command_allowlist_is_exact(self):
        cases = set(re.findall(r"case (\w+) = 0x[0-9A-Fa-f]{2}", PROTOCOL))
        self.assertEqual(cases, {"authenticate", "unlock", "commandError", "lock"})
        for forbidden in ("0x31", "0x60", "0xFA", "0xFB", "0xFC", "0xFF"):
            self.assertNotIn(forbidden, PROTOCOL + MANAGER)

    def test_manager_has_no_automatic_reads_or_reconnect(self):
        forbidden = (
            "refreshAll",
            "shouldReconnect",
            "lockDetails",
            "rideInfo",
            "transferStart",
            "syncBLE",
            "retrievePeripherals",
        )
        for token in forbidden:
            self.assertNotIn(token, MANAGER)
        self.assertIn("未自动读取任何车辆状态", MANAGER)
        self.assertIn("不会自动重连或重试", MANAGER)

    def test_one_action_per_connection_then_disconnects_after_receipt(self):
        self.assertIn("actionAttemptedThisConnection", MANAGER)
        self.assertIn("guard canStartAction else", MANAGER)
        self.assertIn("payload: [0x02]", MANAGER)
        self.assertIn("guard pendingResultAccepted == nil else", MANAGER)
        self.assertIn("case .actionReceipt:\n            finishActionAfterReceipt()", MANAGER)
        self.assertRegex(
            MANAGER,
            r"(?s)private func finishActionAfterReceipt\(\).*?requestDisconnect\(\)",
        )

    def test_sensitive_controls_require_owner_authentication(self):
        self.assertRegex(MANAGER, r"func unlockWithOwnerAuthentication\(\) async")
        self.assertRegex(MANAGER, r"func lockWithOwnerAuthentication\(\) async")
        self.assertRegex(MANAGER, r"private func startAction\(")
        self.assertIn(".deviceOwnerAuthentication", MANAGER)
        self.assertNotRegex(CONTENT, r"device\.startAction\(")

    def test_ui_never_claims_physical_success(self):
        self.assertNotIn("开锁成功", CONTENT + MANAGER)
        self.assertNotIn("关锁成功", CONTENT + MANAGER)
        self.assertIn("设备已接收", CONTENT)
        self.assertIn("物理结果优先", CONTENT)
        self.assertIn("每次蓝牙连接只允许一个动作", CONTENT)

    def test_build_number_is_21(self):
        self.assertEqual(PROJECT.count("CURRENT_PROJECT_VERSION = 21;"), 2)


if __name__ == "__main__":
    unittest.main()

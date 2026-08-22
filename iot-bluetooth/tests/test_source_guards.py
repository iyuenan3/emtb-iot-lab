import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "IoTBluetooth"
MANAGER = (SOURCE / "BLEDeviceManager.swift").read_text()
CONTENT = (SOURCE / "ContentView.swift").read_text()
PROTOCOL = (SOURCE / "OmniProtocol.swift").read_text()
APP = (SOURCE / "IoTBluetoothApp.swift").read_text()
INFO = (SOURCE / "Info.plist").read_text()
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
        self.assertEqual(
            cases,
            {"authenticate", "unlock", "commandError", "lock", "lockDetails"},
        )
        for forbidden in ("0x60", "0xFA", "0xFB", "0xFC", "0xFF"):
            self.assertNotIn(forbidden, PROTOCOL + MANAGER)

    def test_manager_only_restores_lock_read_and_never_reconnects(self):
        forbidden = (
            "refreshAll",
            "shouldReconnect",
            "rideInfo",
            "transferStart",
            "syncBLE",
            "retrievePeripherals",
        )
        for token in forbidden:
            self.assertNotIn(token, MANAGER)
        self.assertIn("refreshLockState", MANAGER)
        self.assertIn("case OmniCommand.lockDetails.rawValue", MANAGER)
        self.assertIn("认证后首次读取", MANAGER)
        self.assertIn("控制后确认", MANAGER)
        self.assertIn("不会自动重连或重试", MANAGER)

    def test_one_action_per_connection_then_disconnects_after_readback(self):
        self.assertIn("BLEControlSession", MANAGER)
        self.assertIn("guard controlSession.begin(action) else", MANAGER)
        self.assertIn("payload: [0x02]", MANAGER)
        self.assertIn("schedulePostActionReadback()", MANAGER)
        self.assertIn("finishActionAfterReadback()", MANAGER)
        self.assertRegex(
            MANAGER,
            r"(?s)private func finishActionAfterReadback\(\).*?requestDisconnect\(\)",
        )

    def test_control_does_not_wait_for_write_callback(self):
        self.assertNotIn("pendingWrite", MANAGER)
        self.assertNotIn("WritePurpose", MANAGER)
        self.assertIn("controlSession.noteWriteCompleted()", MANAGER)
        callback = MANAGER.split("didWriteValueFor characteristic", 1)[1]
        self.assertNotIn("send(", callback)
        self.assertNotIn("finishAction", callback)

    def test_controls_do_not_require_biometric_authentication(self):
        self.assertRegex(MANAGER, r"func unlock\(\)")
        self.assertRegex(MANAGER, r"func lock\(\)")
        self.assertRegex(MANAGER, r"private func startAction\(")
        for forbidden in (
            "LocalAuthentication",
            "deviceOwnerAuthentication",
            "WithOwnerAuthentication",
            "NSFaceIDUsageDescription",
        ):
            self.assertNotIn(forbidden, MANAGER + CONTENT + APP + INFO)
        self.assertIn("device.unlock()", CONTENT)
        self.assertIn("device.lock()", CONTENT)
        self.assertNotRegex(CONTENT, r"device\.startAction\(")

    def test_ui_never_claims_physical_success(self):
        self.assertNotIn("开锁成功", CONTENT + MANAGER)
        self.assertNotIn("关锁成功", CONTENT + MANAGER)
        self.assertIn("设备回包与锁态回读一致", CONTENT)
        self.assertIn("物理结果优先", CONTENT)
        self.assertIn("每次蓝牙连接只允许一个动作", CONTENT)

    def test_diagnostics_are_shareable(self):
        self.assertIn("var diagnosticReport: String", MANAGER)
        self.assertIn("ShareLink(item: device.diagnosticReport)", CONTENT)
        self.assertIn("分享脱敏诊断", CONTENT)

    def test_build_number_is_23(self):
        self.assertEqual(PROJECT.count("CURRENT_PROJECT_VERSION = 23;"), 2)


if __name__ == "__main__":
    unittest.main()

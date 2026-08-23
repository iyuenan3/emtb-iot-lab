import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "IoTBluetooth"
MANAGER = (SOURCE / "BLEDeviceManager.swift").read_text()
CONTENT = (SOURCE / "ContentView.swift").read_text()
VEHICLE = (SOURCE / "VehicleToolsView.swift").read_text()
TOOLS = (SOURCE / "BLEDataToolsView.swift").read_text()
ALL_UI = CONTENT + VEHICLE + TOOLS
PROTOCOL = (SOURCE / "OmniProtocol.swift").read_text()
MODELS = (SOURCE / "Models.swift").read_text()
APP = (SOURCE / "IoTBluetoothApp.swift").read_text()
INFO = (SOURCE / "Info.plist").read_text()
PROJECT = (ROOT / "IoTBluetooth.xcodeproj" / "project.pbxproj").read_text()


class SourceGuardTests(unittest.TestCase):
    def test_app_target_is_offline_ble_only(self):
        excluded = (
            "RemoteControlManager.swift",
            "RemoteControlView.swift",
            "PendingBLEEventStore.swift",
        )
        for name in excluded:
            self.assertNotIn(name, PROJECT)
        self.assertNotIn("RemoteControlManager", APP)
        self.assertNotIn("URLSession", MANAGER + ALL_UI + APP)

    def test_protocol_command_allowlist_matches_v125_document(self):
        cases = set(re.findall(r"case (\w+) = 0x[0-9A-Fa-f]{2}", PROTOCOL))
        self.assertEqual(
            cases,
            {
                "authenticate",
                "unlock",
                "commandError",
                "lock",
                "lockDetails",
                "oldRideData",
                "clearRideData",
                "rideInfo",
                "settings",
                "settings2",
                "externalEquipment",
            },
        )
        for undocumented in ("0x85", "0x91", "0xFA", "0xFB", "0xFC", "0xFF"):
            self.assertNotIn(undocumented, PROTOCOL + MANAGER)

    def test_only_accepted_feature_families_have_outbound_entry_points(self):
        expected_routes = (
            "case OmniCommand.authenticate.rawValue",
            "case OmniCommand.commandError.rawValue",
            "case OmniCommand.unlock.rawValue, OmniCommand.lock.rawValue",
            "case OmniCommand.lockDetails.rawValue",
            "case OmniCommand.oldRideData.rawValue",
            "case OmniCommand.clearRideData.rawValue",
            "case OmniCommand.rideInfo.rawValue",
        )
        for route in expected_routes:
            self.assertIn(route, MANAGER)
        for entry_point in (
            "func refreshDeviceState()",
            "func requestOldRideData()",
            "func clearOldRideData()",
        ):
            self.assertIn(entry_point, MANAGER)
        for forbidden in (
            "func applyBasicSettings(",
            "func applyAdvancedSettings(",
            "func operateExternalDevice(",
            "send(.settings",
            "send(.settings2",
            "send(.externalEquipment",
        ):
            self.assertNotIn(forbidden, MANAGER + ALL_UI)

    def test_connection_is_reused_but_never_automatically_reconnected(self):
        self.assertIn("BLEControlSession", MANAGER)
        self.assertIn("guard controlSession.begin(action) else", MANAGER)
        self.assertIn("payload: [0x02]", MANAGER)
        self.assertIn("finishControlAfterReadback()", MANAGER)
        self.assertIn("controlSession.finishAction()", MANAGER)
        self.assertIn("设备回包与状态回读一致，蓝牙保持连接", MANAGER)
        self.assertIn("可以继续执行下一项操作", CONTENT)
        for forbidden in ("shouldReconnect", "retrievePeripherals", "connectAfter"):
            self.assertNotIn(forbidden, MANAGER)
        self.assertIn("不会自动重连或重试", MANAGER)

    def test_unknown_mutation_disconnects_and_is_not_retried(self):
        self.assertIn("if isMutation {", MANAGER)
        self.assertIn("requestDisconnect()", MANAGER)
        self.assertIn("结果未知，蓝牙已停止并断开", MANAGER)
        self.assertNotIn("retry", MANAGER.lower())

    def test_control_does_not_wait_for_write_callback(self):
        self.assertIn("pendingWriteTickets", MANAGER)
        self.assertIn("controlSession.noteWriteCompleted()", MANAGER)
        callback = MANAGER.split("didWriteValueFor characteristic", 1)[1]
        self.assertNotIn("send(", callback)
        self.assertNotIn("finishAction", callback)

    def test_controls_do_not_require_biometric_authentication(self):
        self.assertRegex(MANAGER, r"func unlock\(\)")
        self.assertRegex(MANAGER, r"func lock\(\)")
        self.assertRegex(MANAGER, r"private func startControl\(")
        for forbidden in (
            "LocalAuthentication",
            "deviceOwnerAuthentication",
            "WithOwnerAuthentication",
            "NSFaceIDUsageDescription",
        ):
            self.assertNotIn(forbidden, MANAGER + ALL_UI + APP + INFO)
        self.assertIn("device.unlock()", CONTENT)
        self.assertIn("device.lock()", CONTENT)

    def test_only_accepted_mutating_tool_requires_confirmation(self):
        self.assertIn("清除旧骑行数据？", TOOLS)
        self.assertIn("role: .destructive", TOOLS)
        self.assertNotIn("确认修改基础设置", VEHICLE)
        self.assertNotIn("确认修改高级设置", VEHICLE)
        self.assertNotIn("确认外部锁操作", TOOLS)

    def test_ui_never_claims_physical_success(self):
        self.assertNotIn("开锁成功", ALL_UI + MANAGER)
        self.assertNotIn("关锁成功", ALL_UI + MANAGER)
        self.assertIn("设备回包与锁态回读一致", CONTENT)
        self.assertIn("物理结果优先", CONTENT)
        self.assertIn("仪表、动力和轮毂锁", CONTENT)
        self.assertIn("外部锁功能已停用", TOOLS)

    def test_diagnostics_are_shareable_and_exclude_old_user_id(self):
        self.assertIn("var diagnosticReport: String", MANAGER)
        self.assertIn("ShareLink(item: device.diagnosticReport)", TOOLS)
        self.assertIn("分享脱敏诊断", TOOLS)
        diagnostic = MANAGER.split("var diagnosticReport: String", 1)[1].split(
            "var oldRideDataReport", 1
        )[0]
        self.assertNotIn("userID", diagnostic)

    def test_current_views_are_in_target_and_build_number_is_25(self):
        for name in ("VehicleToolsView.swift", "BLEDataToolsView.swift"):
            self.assertEqual(PROJECT.count(f"path = {name};"), 1)
            self.assertEqual(PROJECT.count(f"/* {name} in Sources */"), 2)
        self.assertEqual(PROJECT.count("CURRENT_PROJECT_VERSION = 25;"), 2)

    def test_external_devices_remain_protocol_reference_only(self):
        cases = set(re.findall(r"case (\w+) = \"[^\"]+锁\"", MODELS))
        self.assertTrue({"battery", "wheel", "cable"}.issubset(cases))
        self.assertNotIn("hub", MODELS.lower())
        self.assertIn("外部锁功能已停用", TOOLS)
        self.assertNotIn("operateExternalDevice", MANAGER + ALL_UI)


if __name__ == "__main__":
    unittest.main()

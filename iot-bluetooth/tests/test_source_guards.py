import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "IoTBluetooth" / "BLEDeviceManager.swift").read_text()
CONTENT = (ROOT / "IoTBluetooth" / "ContentView.swift").read_text()
PROJECT = (ROOT / "IoTBluetooth.xcodeproj" / "project.pbxproj").read_text()


class SourceGuardTests(unittest.TestCase):
    def test_sensitive_ble_writes_have_only_authenticated_public_entrypoints(self):
        raw_methods = (
            "unlock", "lock", "apply", "applySettings2", "startRFIDRegistration",
            "setScooterPower", "clearOldRideData", "modifyServer", "modifyAPN",
            "startOTA", "saveDeviceKey", "deleteDeviceKey", "saveMaintenanceKey",
            "deleteMaintenanceKey",
        )
        for name in raw_methods:
            self.assertRegex(MANAGER, rf"private func {name}\(")
        wrappers = (
            "unlockWithOwnerAuthentication", "lockWithOwnerAuthentication",
            "applyWithOwnerAuthentication", "applySettings2WithOwnerAuthentication",
            "startRFIDRegistrationWithOwnerAuthentication",
            "setScooterPowerWithOwnerAuthentication",
            "clearOldRideDataWithOwnerAuthentication",
            "modifyServerWithOwnerAuthentication", "modifyAPNWithOwnerAuthentication",
            "startOTAWithOwnerAuthentication", "saveDeviceKeyWithOwnerAuthentication",
            "deleteDeviceKeyWithOwnerAuthentication",
            "saveMaintenanceKeyWithOwnerAuthentication",
            "deleteMaintenanceKeyWithOwnerAuthentication",
        )
        for name in wrappers:
            self.assertRegex(MANAGER, rf"func {name}\(")
        self.assertIn(".deviceOwnerAuthentication", MANAGER)

    def test_views_do_not_call_raw_sensitive_ble_writes(self):
        forbidden = (
            "unlock", "lock", "apply", "applySettings2", "startRFIDRegistration",
            "setScooterPower", "clearOldRideData", "modifyServer", "modifyAPN",
            "startOTA", "saveDeviceKey", "deleteDeviceKey", "saveMaintenanceKey",
            "deleteMaintenanceKey",
        )
        for name in forbidden:
            self.assertIsNone(re.search(rf"device\.{name}\(", CONTENT))

    def test_external_lock_has_no_sender(self):
        self.assertNotIn("operateExternalLock", MANAGER + CONTENT)
        self.assertNotIn("send(.externalEquipment", MANAGER)
        self.assertIn("因果未确认，危险诊断禁用", CONTENT)

    def test_build_number_is_19(self):
        self.assertEqual(PROJECT.count("CURRENT_PROJECT_VERSION = 19;"), 2)


if __name__ == "__main__":
    unittest.main()

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "IoTBluetooth"
PROJECT = (ROOT / "IoTBluetooth.xcodeproj" / "project.pbxproj").read_text()


class CleanAppTests(unittest.TestCase):
    def test_target_contains_only_clean_room_sources(self):
        source_names = re.findall(r"/\* ([^*]+\.swift) in Sources \*/", PROJECT)
        self.assertEqual(
            sorted(set(source_names)),
            sorted(
                [
                    "BikeKeyApp.swift",
                    "BikeKeyView.swift",
                    "BluetoothKeyController.swift",
                    "SecureKeyStore.swift",
                    "BikeControlEngine.swift",
                    "BikeWireProtocol.swift",
                ]
            ),
        )
        self.assertIn("CURRENT_PROJECT_VERSION = 33;", PROJECT)

    def test_old_app_sources_are_deleted(self):
        old_names = {
            "AppDesignSystem.swift",
            "BLEDataToolsView.swift",
            "BLEDeviceManager.swift",
            "ContentView.swift",
            "IoTBluetoothApp.swift",
            "KeychainStore.swift",
            "Models.swift",
            "OmniProtocol.swift",
            "PendingBLEEventStore.swift",
            "RemoteControlManager.swift",
            "RemoteControlView.swift",
            "VehicleToolsView.swift",
        }
        self.assertTrue(old_names.isdisjoint({path.name for path in APP.glob("*.swift")}))
        for name in old_names:
            self.assertNotIn(name, PROJECT)

    def test_only_two_vehicle_actions_are_exposed(self):
        view = (APP / "BikeKeyView.swift").read_text()
        controller = (APP / "BluetoothKeyController.swift").read_text()
        self.assertEqual(view.count("action: controller.unlock"), 1)
        self.assertEqual(view.count("action: controller.lock"), 1)
        self.assertNotIn("URLSession", controller)
        self.assertNotIn("LocalAuthentication", "\n".join(
            path.read_text() for path in APP.glob("*.swift")
        ))

    def test_new_keychain_has_no_old_service_migration(self):
        key_store = (APP / "SecureKeyStore.swift").read_text()
        self.assertIn("com.maxwell.emtb.clean-bike-key", key_store)
        self.assertNotIn("migration", key_store.lower())

    def test_configuration_only_contains_ble_identity(self):
        info = (APP / "Info.plist").read_text()
        config = (ROOT / "Config.xcconfig").read_text()
        self.assertNotIn("IMEI", info + config)
        self.assertNotIn("BIKE_NUMBER", info + config)
        self.assertIn("DEVICE_BLE_MAC", config)

    def test_controller_uses_shared_single_send_engine(self):
        controller = (APP / "BluetoothKeyController.swift").read_text()
        self.assertIn("BikeControlEngine(action: action)", controller)
        self.assertEqual(controller.count("peripheral.writeValue("), 1)
        self.assertNotRegex(controller.lower(), r"\bretry\b")


if __name__ == "__main__":
    unittest.main()

import os
import sqlite3
import tempfile
import unittest

from iot_remote.crypto import GX, GY
from iot_remote.database import Database


class DatabaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.temp.name, "state", "iot.sqlite3")
        self.database = Database(self.path)
        self.vehicle_id = self.database.ensure_vehicle("123", "测试车")

    def tearDown(self):
        self.database.close()
        self.temp.cleanup()

    def test_pairing_code_is_single_use(self):
        code = self.database.create_pairing_code()
        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        first = self.database.complete_pairing(code, "iPhone", "token", public)
        second = self.database.complete_pairing(code, "other", "token2", public)
        self.assertIsNotNone(first)
        self.assertIsNone(second)
        self.assertIsNotNone(self.database.authenticate(first["client_id"], "token"))
        self.assertIsNone(self.database.authenticate(first["client_id"], "wrong"))

    def test_command_idempotency_and_timeline(self):
        command, created = self.database.create_command(
            self.vehicle_id, "client", "vehicle.find_sound", {}, "same-key"
        )
        repeated, repeated_created = self.database.create_command(
            self.vehicle_id, "client", "vehicle.find_sound", {}, "same-key"
        )
        self.assertTrue(created)
        self.assertFalse(repeated_created)
        self.assertEqual(command["id"], repeated["id"])
        self.assertEqual(
            self.database.command_by_idempotency("client", "same-key")["id"], command["id"]
        )
        self.assertIsNotNone(
            self.database.latest_command_time(self.vehicle_id, "vehicle.find_sound")
        )
        result = self.database.transition_command(command["id"], "succeeded", {"ok": True})
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(len(result["events"]), 2)

    def test_nonce_cannot_be_replayed(self):
        code = self.database.create_pairing_code()
        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        client = self.database.complete_pairing(code, "iPhone", "token", public)
        self.assertTrue(self.database.consume_nonce(client["client_id"], "1234567890abcdef", 1000))
        self.assertFalse(self.database.consume_nonce(client["client_id"], "1234567890abcdef", 1001))

    def test_existing_vehicle_state_is_migrated(self):
        legacy_path = os.path.join(self.temp.name, "legacy.sqlite3")
        connection = sqlite3.connect(legacy_path)
        connection.execute(
            "CREATE TABLE vehicle_state (vehicle_id TEXT PRIMARY KEY, online INTEGER NOT NULL "
            "DEFAULT 0, last_seen_at INTEGER, lock_state TEXT NOT NULL DEFAULT 'unknown', "
            "power_mv INTEGER, battery_percent INTEGER, security_state TEXT NOT NULL DEFAULT "
            "'unknown', active_unlock_user TEXT, active_unlock_timestamp TEXT, "
            "updated_at INTEGER NOT NULL)"
        )
        connection.execute(
            "CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, vehicle_id TEXT "
            "NOT NULL, source TEXT NOT NULL, device_timestamp INTEGER, received_at INTEGER NOT "
            "NULL, valid INTEGER NOT NULL, latitude REAL, longitude REAL, satellites INTEGER, "
            "hdop REAL, altitude_m REAL, mode TEXT, raw_fields_json TEXT NOT NULL, fingerprint "
            "TEXT NOT NULL, UNIQUE(vehicle_id,fingerprint))"
        )
        connection.execute(
            "INSERT INTO locations(vehicle_id,source,device_timestamp,received_at,valid,latitude,"
            "longitude,satellites,hdop,altitude_m,mode,raw_fields_json,fingerprint) "
            "VALUES('vehicle-1','once',1700000000,1700000001,1,30.0,120.0,6,0.8,10.0,'A',"
            "'[]','legacy')"
        )
        connection.commit()
        connection.close()
        migrated = Database(legacy_path)
        columns = {
            row[1] for row in migrated.connection.execute("PRAGMA table_info(vehicle_state)")
        }
        location_columns = {
            row[1] for row in migrated.connection.execute("PRAGMA table_info(locations)")
        }
        legacy_location = migrated.connection.execute(
            "SELECT display_eligible FROM locations WHERE fingerprint='legacy'"
        ).fetchone()
        migrated.close()
        self.assertIn("telemetry_fields_json", columns)
        self.assertIn("telemetry_updated_at", columns)
        self.assertIn("lock_state_source", columns)
        self.assertIn("lock_state_updated_at", columns)
        self.assertIn("desired_tracking_interval", columns)
        self.assertIn("confirmed_tracking_interval", columns)
        self.assertIn("tracking_confirmed_at", columns)
        self.assertIn("grace_until", columns)
        self.assertIn("active_alarm_id", columns)
        self.assertIn("rejection_reason", location_columns)
        self.assertIn("distance_from_previous_m", location_columns)
        self.assertIn("speed_mps", location_columns)
        self.assertIn("alarm_id", location_columns)
        self.assertEqual(legacy_location[0], 1)

    def test_grace_suppresses_movement_then_arms_and_merges_alarm(self):
        self.database.apply_confirmed_lock_state(
            self.vehicle_id, "locked", "test", 100
        )
        grace = self.database.start_lock_grace(
            self.vehicle_id, grace_seconds=300, now=100
        )
        self.assertEqual(grace["security_state"], "grace_period")
        self.assertEqual(grace["grace_until"], 400)

        suppressed = self.database.record_movement_event(self.vehicle_id, now=200)
        self.assertTrue(suppressed["suppressed"])
        self.assertEqual(self.database.alarms(self.vehicle_id), [])

        first = self.database.record_movement_event(self.vehicle_id, now=400)
        repeated = self.database.record_movement_event(self.vehicle_id, now=450)
        notified_again = self.database.record_movement_event(self.vehicle_id, now=511)
        self.assertFalse(first["suppressed"])
        self.assertTrue(first["should_notify"])
        self.assertFalse(repeated["should_notify"])
        self.assertTrue(notified_again["should_notify"])
        self.assertEqual(first["alarm"]["id"], repeated["alarm"]["id"])
        self.assertEqual(notified_again["alarm"]["trigger_count"], 3)
        self.assertEqual(
            self.database.vehicle(self.vehicle_id)["security_state"], "alarm_active"
        )

    def test_alarm_acknowledge_and_unlock_clear_are_distinct(self):
        self.database.apply_confirmed_lock_state(
            self.vehicle_id, "locked", "test", 100
        )
        self.database.arm_security(self.vehicle_id, now=101)
        active = self.database.record_movement_event(self.vehicle_id, now=102)["alarm"]
        acknowledged = self.database.acknowledge_alarm(
            self.vehicle_id, "client", now=103
        )
        self.assertEqual(acknowledged["state"], "acknowledged")
        self.assertEqual(self.database.vehicle(self.vehicle_id)["security_state"], "armed")

        second = self.database.record_movement_event(self.vehicle_id, now=200)["alarm"]
        self.database.apply_confirmed_lock_state(
            self.vehicle_id, "unlocked", "test", 201, "1", "201"
        )
        self.assertEqual(self.database.alarm(second["id"])["state"], "cleared")
        self.assertEqual(self.database.alarm(active["id"])["state"], "acknowledged")
        event_types = [
            event["event_type"] for event in self.database.alarm_events(self.vehicle_id)
        ]
        self.assertIn("cleared_by_unlock", event_types)

    def test_confirmed_lock_does_not_disarm_an_active_alarm(self):
        self.database.apply_confirmed_lock_state(
            self.vehicle_id, "locked", "test", 100
        )
        self.database.arm_security(self.vehicle_id, now=101)
        alarm = self.database.record_movement_event(self.vehicle_id, now=102)["alarm"]

        self.database.apply_confirmed_lock_state(
            self.vehicle_id, "locked", "remote_command", 103
        )

        vehicle = self.database.vehicle(self.vehicle_id)
        self.assertEqual(vehicle["security_state"], "alarm_active")
        self.assertEqual(vehicle["active_alarm_id"], alarm["id"])
        self.assertEqual(self.database.alarm(alarm["id"])["state"], "active")

    def test_location_history_deduplicates_and_keeps_last_valid_point(self):
        values = {
            "source": "once", "device_timestamp": 1700000000, "valid": True,
            "latitude": 1.0, "longitude": 1.0, "satellites": 6,
            "hdop": 0.21, "altitude_m": 10.0, "mode": "A",
            "raw_fields": ("0", "124458.00", "A"),
        }
        first = self.database.save_location(self.vehicle_id, **values)
        repeated = self.database.save_location(self.vehicle_id, **values)
        self.assertEqual(first["id"], repeated["id"])

        invalid = dict(values)
        invalid.update({
            "device_timestamp": 1700000060, "valid": False, "latitude": None,
            "longitude": None, "raw_fields": ("0", "124558.00", "V"),
        })
        self.database.save_location(self.vehicle_id, **invalid)
        latest_valid = self.database.latest_location(self.vehicle_id)
        last_report = self.database.latest_location(self.vehicle_id, valid_only=False)
        self.assertEqual(latest_valid["id"], first["id"])
        self.assertFalse(last_report["valid"])
        self.assertEqual(len(self.database.locations(self.vehicle_id)), 1)

    def test_location_quality_rejects_poor_order_and_excessive_speed(self):
        base = {
            "source": "tracking", "valid": True, "satellites": 6,
            "hdop": 0.8, "altitude_m": 10.0, "mode": "A",
        }
        first = self.database.save_location(
            self.vehicle_id, device_timestamp=1700000000,
            latitude=30.0, longitude=120.0,
            raw_fields=("1", "first"), **base,
        )
        self.assertTrue(first["display_eligible"])

        poor = self.database.save_location(
            self.vehicle_id, device_timestamp=1700000060,
            latitude=30.0001, longitude=120.0001, hdop=12.0,
            raw_fields=("1", "poor"), **{key: value for key, value in base.items() if key != "hdop"},
        )
        self.assertFalse(poor["display_eligible"])
        self.assertEqual(poor["rejection_reason"], "poor_hdop")

        out_of_order = self.database.save_location(
            self.vehicle_id, device_timestamp=1699999999,
            latitude=30.0001, longitude=120.0001,
            raw_fields=("1", "old"), **base,
        )
        self.assertEqual(out_of_order["rejection_reason"], "out_of_order")

        jump = self.database.save_location(
            self.vehicle_id, device_timestamp=1700000060,
            latitude=31.0, longitude=121.0,
            raw_fields=("1", "jump"), **base,
        )
        self.assertEqual(jump["rejection_reason"], "excessive_speed")
        self.assertGreater(jump["speed_mps"], 25.0)

        accepted = self.database.save_location(
            self.vehicle_id, device_timestamp=1700000120,
            latitude=30.0002, longitude=120.0002,
            raw_fields=("1", "accepted"), **base,
        )
        self.assertTrue(accepted["display_eligible"])
        self.assertEqual(
            [point["id"] for point in self.database.locations(self.vehicle_id)],
            [first["id"], accepted["id"]],
        )

    def test_ble_lock_observation_is_idempotent_and_newer_state_wins(self):
        code = self.database.create_pairing_code()
        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        client = self.database.complete_pairing(code, "iPhone", "token", public)
        first, created = self.database.save_ble_lock_observation(
            "11111111-1111-4111-8111-111111111111", self.vehicle_id,
            client["client_id"], "locked", 2000,
        )
        repeated, repeated_created = self.database.save_ble_lock_observation(
            first["id"], self.vehicle_id, client["client_id"], "locked", 2000,
        )
        older, older_created = self.database.save_ble_lock_observation(
            "22222222-2222-4222-8222-222222222222", self.vehicle_id,
            client["client_id"], "unlocked", 1999,
        )
        vehicle = self.database.vehicle(self.vehicle_id)
        self.assertTrue(created)
        self.assertFalse(repeated_created)
        self.assertEqual(first["id"], repeated["id"])
        self.assertTrue(older_created)
        self.assertFalse(older["applied"])
        self.assertEqual(vehicle["lock_state"], "locked")
        self.assertEqual(vehicle["lock_state_source"], "ble")


if __name__ == "__main__":
    unittest.main()

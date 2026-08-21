import asyncio
import base64
import hashlib
import json
import os
import tempfile
import time
import unittest
from unittest.mock import AsyncMock, patch

from iot_remote.crypto import GX, GY, N, _scalar_multiply, canonical_request, sha256_hex
from iot_remote.database import Database
from iot_remote.protocol import Frame
from iot_remote.service import APIError, DeviceSession, HTTPSpec, RemoteService, run_servers


class FakeWriter:
    def __init__(self):
        self.data = bytearray()
        self.closed = False

    def write(self, data):
        self.data.extend(data)

    async def drain(self):
        pass

    def is_closing(self):
        return self.closed

    def close(self):
        self.closed = True

    async def wait_closed(self):
        pass


class FakeServer:
    def __init__(self, writer=None):
        self.writer = writer
        self.closed = False

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, traceback):
        return False

    async def serve_forever(self):
        await asyncio.Future()

    def close(self):
        self.closed = True

    async def wait_closed(self):
        while self.writer is not None and not self.writer.closed:
            await asyncio.sleep(0.001)


class ServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.database = Database(os.path.join(self.temp.name, "iot.sqlite3"))
        self.service = RemoteService(self.database, "000000000000001", "测试车", command_timeout=1)
        self.writer = FakeWriter()
        self.service.session = DeviceSession(self.writer, "ZZ", asyncio.get_running_loop().time())
        self.database.update_vehicle_state(self.service.vehicle_id, online=1)

    async def asyncTearDown(self):
        for task in self.service._timeout_tasks.values():
            task.cancel()
        self.database.close()
        self.temp.cleanup()

    def create(self, command_type, key=None, parameters=None):
        return self.database.create_command(
            self.service.vehicle_id, "client-id", command_type, parameters or {}, key
        )[0]

    async def test_unlock_requires_r0_then_l0(self):
        command = self.create("vehicle.unlock")
        await self.service.dispatch_command(command["id"])
        self.assertIn(b",R0,0,30,", self.writer.data)
        stored = self.database.command(command["id"])
        params = stored["parameters"]
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "R0",
            ("0", "251", params["user_id"], params["timestamp"]),
        ))
        self.assertIn(b",L0,251,", self.writer.data)
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "L0",
            ("0", params["user_id"], params["timestamp"]),
        ))
        result = self.database.command(command["id"])
        vehicle = self.database.vehicle(self.service.vehicle_id)
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(vehicle["lock_state"], "unlocked")
        self.assertEqual(vehicle["desired_tracking_interval"], 60)
        self.assertIn(b",D1,60#", self.writer.data)

    async def test_lock_requires_signed_stationary_confirmation(self):
        command = self.create("vehicle.lock")
        await self.service.dispatch_command(command["id"])
        result = self.database.command(command["id"])
        self.assertEqual(result["status"], "rejected")
        self.assertEqual(result["error_code"], "stationary_confirmation_required")
        self.assertEqual(self.writer.data, b"")

    async def test_lock_capability_requires_confirmation_and_tracks_online_state(self):
        capability = self.service.capabilities()["vehicle.lock"]
        self.assertTrue(capability["enabled"])
        self.assertTrue(capability["requires_stationary_confirmation"])
        self.assertTrue(capability["physical_confirmation_required"])
        self.writer.closed = True
        self.assertFalse(self.service.capabilities()["vehicle.lock"]["enabled"])

    async def test_lock_requires_r0_then_l1_and_physical_confirmation(self):
        self.database.update_vehicle_state(self.service.vehicle_id, lock_state="unlocked")
        command = self.create("vehicle.lock", parameters={"stationary_confirmed": True})
        await self.service.dispatch_command(command["id"])
        self.assertIn(b",R0,1,30,", self.writer.data)
        stored = self.database.command(command["id"])
        params = stored["parameters"]
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "R0",
            ("1", "251", params["user_id"], params["timestamp"]),
        ))
        self.assertIn(b",L1,251#", self.writer.data)
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "L1", ("0", "1", "1700000000", "5")
        ))
        result = self.database.command(command["id"])
        vehicle = self.database.vehicle(self.service.vehicle_id)
        self.assertEqual(result["status"], "succeeded")
        self.assertTrue(result["result"]["physical_confirmation_required"])
        self.assertEqual(vehicle["lock_state"], "locked")
        self.assertEqual(vehicle["security_state"], "disarmed")
        self.assertEqual(vehicle["desired_tracking_interval"], 3600)
        self.assertIn(b",D1,3600#", self.writer.data)

    async def test_already_locked_is_noop_without_sending(self):
        self.database.update_vehicle_state(self.service.vehicle_id, lock_state="locked")
        command = self.create("vehicle.lock", parameters={"stationary_confirmed": True})
        await self.service.dispatch_command(command["id"])
        self.assertEqual(self.database.command(command["id"])["status"], "noop")
        self.assertEqual(self.writer.data, b"")

    async def test_already_unlocked_is_noop(self):
        self.database.update_vehicle_state(self.service.vehicle_id, lock_state="unlocked")
        command = self.create("vehicle.unlock")
        await self.service.dispatch_command(command["id"])
        self.assertEqual(self.database.command(command["id"])["status"], "noop")
        self.assertEqual(self.writer.data, b"")

    async def test_timeout_is_unknown_and_not_retried(self):
        command = self.create("vehicle.find_sound")
        await self.service.dispatch_command(command["id"])
        sent = bytes(self.writer.data)
        await asyncio.sleep(1.1)
        self.assertEqual(self.database.command(command["id"])["status"], "unknown")
        self.assertEqual(bytes(self.writer.data), sent)

    async def test_shutdown_closes_session_and_marks_command_unknown(self):
        command = self.create("vehicle.find_sound")
        await self.service.dispatch_command(command["id"])
        self.assertEqual(self.database.command(command["id"])["status"], "awaiting_result")

        await self.service.shutdown()

        self.assertTrue(self.writer.closed)
        self.assertIsNone(self.service.session)
        self.assertEqual(
            self.database.command(command["id"])["error_code"], "service_stopped"
        )
        self.assertFalse(self.database.vehicle(self.service.vehicle_id)["online"])

    async def test_run_servers_closes_active_device_before_waiting_for_listener(self):
        tcp_server = FakeServer(self.writer)
        http_server = FakeServer()
        stop_event = asyncio.Event()
        stop_event.set()
        with patch(
            "iot_remote.service.asyncio.start_server",
            new=AsyncMock(side_effect=[tcp_server, http_server]),
        ):
            await asyncio.wait_for(
                run_servers(self.service, "127.0.0.1", 0, "127.0.0.1", 0, stop_event),
                timeout=0.2,
            )
        self.assertTrue(self.writer.closed)
        self.assertTrue(tcp_server.closed)
        self.assertTrue(http_server.closed)

    async def test_h0_updates_verified_vehicle_fields(self):
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "H0", ("1", "412", "31", "99", "0")
        ))
        vehicle = self.database.vehicle(self.service.vehicle_id)
        self.assertEqual(vehicle["lock_state"], "locked")
        self.assertEqual(vehicle["lock_state_source"], "iot_h0")
        self.assertEqual(vehicle["power_mv"], 412)
        self.assertEqual(vehicle["battery_percent"], 99)
        self.assertEqual(vehicle["desired_tracking_interval"], 3600)
        self.assertIn(b",D1,3600#", self.writer.data)

    async def test_d1_keeps_desired_and_confirmed_values_separate(self):
        command = self.create(
            "tracking.set_policy", parameters={"interval_seconds": 60, "reason": "test"}
        )
        await self.service.dispatch_command(command["id"])
        requested = self.database.vehicle(self.service.vehicle_id)
        self.assertEqual(requested["desired_tracking_interval"], 60)
        self.assertIsNone(requested["confirmed_tracking_interval"])
        self.assertIn(b",D1,60#", self.writer.data)

        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "S6",
            ("99", "11264", "12", "24066", "0", "65535", "53780", "0"),
        ))
        self.assertEqual(
            self.database.command(command["id"])["status"], "awaiting_result"
        )

        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "D1", ("60",)
        ))
        confirmed = self.database.vehicle(self.service.vehicle_id)
        result = self.database.command(command["id"])
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["result"]["confirmed_tracking_interval"], 60)
        self.assertEqual(confirmed["confirmed_tracking_interval"], 60)
        self.assertIsNotNone(confirmed["tracking_confirmed_at"])

    async def test_d1_timeout_is_not_retried_on_same_session(self):
        self.database.update_vehicle_state(self.service.vehicle_id, lock_state="locked")
        self.service.session.policy_reconciled = True
        first = await self.service.reconcile_tracking_policy("test_timeout")
        self.assertIsNotNone(first)
        self.service._finish(first["id"], "unknown", "device_timeout")
        sent = bytes(self.writer.data)

        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "H0", ("1", "412", "31", "99", "0")
        ))
        self.assertEqual(bytes(self.writer.data), sent)
        self.assertEqual(
            self.database.vehicle(self.service.vehicle_id)["desired_tracking_interval"], 3600
        )
        self.assertIsNone(
            self.database.vehicle(self.service.vehicle_id)["confirmed_tracking_interval"]
        )

    async def test_new_session_h0_creates_new_policy_command_after_timeout(self):
        self.database.update_vehicle_state(self.service.vehicle_id, lock_state="locked")
        first = await self.service.reconcile_tracking_policy("first_session")
        self.service._finish(first["id"], "unknown", "device_timeout")
        first_id = first["id"]

        self.service.session = DeviceSession(
            FakeWriter(), "ZZ", asyncio.get_running_loop().time()
        )
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "H0", ("1", "412", "31", "99", "0")
        ))
        active = self.database.active_command(self.service.vehicle_id)
        self.assertIsNotNone(active)
        self.assertEqual(active["command_type"], "tracking.set_policy")
        self.assertNotEqual(active["id"], first_id)

    async def test_new_session_policy_waits_for_active_command(self):
        find_sound = self.create("vehicle.find_sound")
        await self.service.dispatch_command(find_sound["id"])
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "H0", ("1", "412", "31", "99", "0")
        ))
        self.assertEqual(
            self.database.active_command(self.service.vehicle_id)["id"], find_sound["id"]
        )

        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "V0", ("2",)
        ))
        active = self.database.active_command(self.service.vehicle_id)
        self.assertEqual(active["command_type"], "tracking.set_policy")
        self.assertIn(b",D1,3600#", self.writer.data)

    async def test_connectivity_transitions_disable_commands(self):
        clock = asyncio.get_running_loop().time()
        self.service.session.last_frame_at = clock - 419
        self.assertEqual(self.service.connectivity_state(), "online")
        self.assertTrue(self.service.capabilities()["vehicle.unlock"]["enabled"])

        self.service.session.last_frame_at = clock - 421
        self.assertEqual(self.service.connectivity_state(), "silent")
        capability = self.service.capabilities()["vehicle.unlock"]
        self.assertFalse(capability["enabled"])
        self.assertEqual(capability["reason"], "device_silent")

        self.service.session.last_frame_at = clock - 721
        self.assertEqual(self.service.connectivity_state(), "offline")
        self.assertFalse(self.service.is_online())

    async def test_health_exposes_revision_and_connectivity(self):
        self.service.revision = "test-revision"
        self.service.session.last_frame_at = asyncio.get_running_loop().time() - 421
        payload, status = await self.service.route(HTTPSpec(
            "GET", "/healthz", "", {}, b"",
        ))
        self.assertEqual(status, 200)
        self.assertEqual(payload["revision"], "test-revision")
        self.assertEqual(payload["device_connectivity"], "silent")
        self.assertFalse(payload["device_online"])
        self.assertGreaterEqual(payload["last_frame_age_seconds"], 420)

    async def test_s6_preserves_verified_battery_and_raw_fields(self):
        fields = ("99", "11264", "12", "24066", "0", "65535", "53780", "0")
        await self.service.process_frame(Frame("ZZ", self.service.target_imei, "S6", fields))
        vehicle = self.database.vehicle(self.service.vehicle_id)
        self.assertEqual(vehicle["battery_percent"], 99)
        self.assertEqual(vehicle["telemetry_fields"], list(fields))
        self.assertIsNotNone(vehicle["telemetry_updated_at"])

    async def test_d0_persists_valid_and_invalid_reports(self):
        valid_fields = (
            "1", "000000.00", "A", "0100.0000", "N", "00100.0000", "E",
            "6", "0.21", "010100", "10", "M", "A",
        )
        await self.service.process_frame(Frame("ZZ", self.service.target_imei, "D0", valid_fields))
        latest = self.database.latest_location(self.service.vehicle_id)
        self.assertAlmostEqual(latest["latitude"], 1.0, places=5)
        self.assertEqual(latest["source"], "tracking")

        invalid_fields = (
            "0", "000100.00", "V", "", "", "", "", "0", "99.99",
            "010100", "", "", "N",
        )
        await self.service.process_frame(Frame("ZZ", self.service.target_imei, "D0", invalid_fields))
        self.assertFalse(self.database.latest_location(
            self.service.vehicle_id, valid_only=False
        )["valid"])
        self.assertEqual(self.database.latest_location(self.service.vehicle_id)["id"], latest["id"])

    async def test_d0_quality_rejection_is_reported_without_moving_map(self):
        first_fields = (
            "1", "000000.00", "A", "3000.0000", "N", "12000.0000", "E",
            "6", "0.80", "141123", "10", "M", "A",
        )
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "D0", first_fields
        ))
        first = self.database.latest_location(self.service.vehicle_id)

        command = self.create("location.once")
        await self.service.dispatch_command(command["id"])
        poor_fields = (
            "0", "000100.00", "A", "3000.0060", "N", "12000.0060", "E",
            "6", "12.0", "141123", "10", "M", "A",
        )
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "D0", poor_fields
        ))
        result = self.database.command(command["id"])["result"]
        self.assertTrue(result["location_valid"])
        self.assertFalse(result["location_display_eligible"])
        self.assertEqual(result["location_rejection_reason"], "poor_hdop")
        self.assertEqual(
            self.database.latest_location(self.service.vehicle_id)["id"], first["id"]
        )

    async def test_location_command_and_authenticated_location_api(self):
        command = self.create("location.once")
        await self.service.dispatch_command(command["id"])
        self.assertIn(b",D0#", self.writer.data)
        fields = (
            "0", "124458.00", "A", "2237.7514", "N", "11408.6214", "E",
            "6", "0.21", "151216", "10", "M", "A",
        )
        await self.service.process_frame(Frame("ZZ", self.service.target_imei, "D0", fields))
        command = self.database.command(command["id"])
        self.assertEqual(command["status"], "succeeded")
        self.assertTrue(command["result"]["location_valid"])

        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        code = self.database.create_pairing_code()
        paired = self.database.complete_pairing(code, "iPhone", "token", public)
        payload, status = await self.service.route(HTTPSpec(
            "GET", "/api/v1/locations", "limit=10",
            {"x-client-id": paired["client_id"], "authorization": "Bearer token"}, b"",
        ))
        self.assertEqual(status, 200)
        self.assertEqual(len(payload["points"]), 1)
        self.assertEqual(payload["latest"]["id"], payload["points"][0]["id"])

    async def test_signed_ble_observation_updates_remote_lock_state(self):
        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        code = self.database.create_pairing_code()
        paired = self.database.complete_pairing(code, "iPhone", "token", public)
        self.service._verify_control_signature = lambda request, client: None
        body = json.dumps({
            "observation_id": "33333333-3333-4333-8333-333333333333",
            "lock_state": "locked",
            "observed_at": int(time.time()),
        }).encode()
        payload, status = await self.service.route(HTTPSpec(
            "POST", "/api/v1/ble-observations", "",
            {"x-client-id": paired["client_id"], "authorization": "Bearer token"}, body,
        ))
        self.assertEqual(status, 201)
        self.assertTrue(payload["observation"]["applied"])
        vehicle = self.database.vehicle(self.service.vehicle_id)
        self.assertEqual(vehicle["lock_state"], "locked")
        self.assertEqual(vehicle["lock_state_source"], "ble")

    async def test_control_signature_and_nonce_replay(self):
        private_key = 7
        public = _scalar_multiply(private_key, (GX, GY))
        self.assertIsNotNone(public)
        public_bytes = b"\x04" + public[0].to_bytes(32, "big") + public[1].to_bytes(32, "big")
        code = self.database.create_pairing_code()
        paired = self.database.complete_pairing(code, "iPhone", "token", public_bytes)
        client = self.database.authenticate(paired["client_id"], "token")
        body = json.dumps({"type": "vehicle.unlock"}, separators=(",", ":")).encode()
        timestamp = str(int(time.time()))
        nonce = "1234567890abcdef"
        digest = sha256_hex(body)
        message = canonical_request("POST", "/api/v1/commands", "", timestamp, nonce, digest)
        signing_nonce = 11
        point = _scalar_multiply(signing_nonce, (GX, GY))
        r = point[0] % N
        value = int.from_bytes(hashlib.sha256(message).digest(), "big")
        s = pow(signing_nonce, -1, N) * (value + r * private_key) % N
        signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        request = HTTPSpec("POST", "/api/v1/commands", "", {
            "x-timestamp": timestamp,
            "x-nonce": nonce,
            "x-body-sha256": digest,
            "x-signature": base64.b64encode(signature).decode(),
        }, body)
        self.service._verify_control_signature(request, client)
        with self.assertRaises(APIError) as context:
            self.service._verify_control_signature(request, client)
        self.assertEqual(context.exception.code, "replayed_request")


if __name__ == "__main__":
    unittest.main()

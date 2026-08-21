import asyncio
import base64
import hashlib
import json
import os
import socket
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
        if self.service._grace_task:
            self.service._grace_task.cancel()
            await asyncio.gather(self.service._grace_task, return_exceptions=True)
        if self.service._cleanup_task:
            self.service._cleanup_task.cancel()
            await asyncio.gather(self.service._cleanup_task, return_exceptions=True)
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
        trip = self.database.trip(vehicle["active_trip_id"])
        self.assertEqual(trip["start_command_id"], command["id"])
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
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "unlocked", "test", int(time.time()) - 10
        )
        trip_id = self.database.vehicle(self.service.vehicle_id)["active_trip_id"]
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
        self.assertIsNone(vehicle["active_trip_id"])
        self.assertEqual(self.database.trip(trip_id)["end_command_id"], command["id"])
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

    async def test_run_servers_stops_with_real_active_tcp_client(self):
        self.service.session = None
        self.database.update_vehicle_state(self.service.vehicle_id, online=0)
        tcp_port = self._unused_port()
        http_port = self._unused_port()
        while http_port == tcp_port:
            http_port = self._unused_port()
        stop_event = asyncio.Event()
        task = asyncio.create_task(run_servers(
            self.service, "127.0.0.1", tcp_port, "127.0.0.1", http_port, stop_event
        ))
        reader = None
        writer = None
        try:
            for _ in range(100):
                try:
                    reader, writer = await asyncio.open_connection("127.0.0.1", tcp_port)
                    break
                except ConnectionRefusedError:
                    await asyncio.sleep(0.01)
            self.assertIsNotNone(reader)
            self.assertIsNotNone(writer)
            writer.write(
                b"*SCOR,ZZ,000000000000001,H0,1,412,31,99,0#\r\n"
            )
            await writer.drain()
            for _ in range(100):
                if self.service.session is not None:
                    break
                await asyncio.sleep(0.01)
            self.assertIsNotNone(self.service.session)
            stop_event.set()
            await asyncio.wait_for(task, timeout=3)
            self.assertIsNone(self.service.session)
            await asyncio.wait_for(reader.read(), timeout=1)
            self.assertTrue(reader.at_eof())
        finally:
            if writer is not None:
                writer.close()
                await writer.wait_closed()
            if not task.done():
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

    @staticmethod
    def _unused_port():
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            return listener.getsockname()[1]

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

    async def test_h0_reconciles_recovered_trip_lifecycle(self):
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "H0", ("0", "412", "31", "99", "0")
        ))
        vehicle = self.database.vehicle(self.service.vehicle_id)
        trip_id = vehicle["active_trip_id"]
        self.assertIsNotNone(trip_id)
        self.assertTrue(self.database.trip(trip_id)["recovered_after_restart"])

        active = self.database.active_command(self.service.vehicle_id)
        if active:
            self.service._finish(active["id"], "unknown", "test_cleanup")
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "H0", ("1", "412", "31", "99", "0")
        ))
        self.assertIsNone(
            self.database.vehicle(self.service.vehicle_id)["active_trip_id"]
        )
        self.assertEqual(self.database.trip(trip_id)["status"], "completed")

    async def test_reconnect_h0_requests_two_locations_and_infers_movement(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", 1
        )
        baseline = self.database.save_location(
            self.service.vehicle_id, source="tracking", device_timestamp=1,
            valid=True, latitude=22.6200, longitude=114.14369, satellites=6,
            hdop=0.8, altitude_m=10.0, mode="A", raw_fields=("baseline",),
        )
        self.database.mark_device_disconnected(self.service.vehicle_id, now=2)
        reconnect_writer = FakeWriter()
        self.service.session = DeviceSession(
            reconnect_writer, "ZZ", asyncio.get_running_loop().time()
        )

        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "H0", ("1", "412", "31", "99", "0")
        ))

        first_command = self.database.active_command(self.service.vehicle_id)
        self.assertEqual(first_command["command_type"], "location.once")
        self.assertEqual(first_command["parameters"]["location_source"], "reconnect_check")
        self.assertEqual(first_command["parameters"]["sample_index"], 1)
        self.assertEqual(reconnect_writer.data.count(b",D0#"), 1)
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "D0",
            ("0", "124458.00", "A", "2237.7514", "N", "11408.6214", "E",
             "6", "0.21", "151216", "10", "M", "A"),
        ))

        second_command = self.database.active_command(self.service.vehicle_id)
        self.assertEqual(second_command["parameters"]["sample_index"], 2)
        self.assertEqual(reconnect_writer.data.count(b",D0#"), 2)
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "D0",
            ("0", "124559.00", "A", "2237.7520", "N", "11408.6216", "E",
             "6", "0.22", "151216", "10", "M", "A"),
        ))

        alarm = self.database.alarms(self.service.vehicle_id, active_only=True)[0]
        self.assertEqual(alarm["alarm_type"], "suspected_offline_movement")
        self.assertTrue(alarm["inferred"])
        self.assertEqual(alarm["baseline_location_id"], baseline["id"])
        self.assertIsNotNone(alarm["baseline_captured_at"])
        self.assertIsNotNone(alarm["reconnect_captured_at"])
        self.assertIsNone(self.service._reconnect_workflow)
        active = self.database.active_command(self.service.vehicle_id)
        self.assertEqual(active["command_type"], "tracking.set_policy")
        self.assertEqual(active["parameters"]["interval_seconds"], 300)

    async def test_reconnect_location_timeout_does_not_retry_same_session(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", 1
        )
        self.database.save_location(
            self.service.vehicle_id, source="tracking", device_timestamp=1,
            valid=True, latitude=22.6200, longitude=114.14369, satellites=6,
            hdop=0.8, altitude_m=10.0, mode="A", raw_fields=("baseline",),
        )
        self.database.mark_device_disconnected(self.service.vehicle_id, now=2)
        reconnect_writer = FakeWriter()
        self.service.session = DeviceSession(
            reconnect_writer, "ZZ", asyncio.get_running_loop().time()
        )
        self.service.command_timeout = 0.01

        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "H0", ("1", "412", "31", "99", "0")
        ))
        await asyncio.sleep(0.05)

        self.assertEqual(reconnect_writer.data.count(b",D0#"), 1)
        self.assertIsNone(self.service._reconnect_workflow)
        self.assertIsNone(
            self.database.vehicle(self.service.vehicle_id)["offline_since"]
        )

    async def test_reconnect_duplicate_location_does_not_count_twice(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", 1
        )
        self.database.save_location(
            self.service.vehicle_id, source="tracking", device_timestamp=1,
            valid=True, latitude=22.6200, longitude=114.14369, satellites=6,
            hdop=0.8, altitude_m=10.0, mode="A", raw_fields=("baseline",),
        )
        self.database.mark_device_disconnected(self.service.vehicle_id, now=2)
        reconnect_writer = FakeWriter()
        self.service.session = DeviceSession(
            reconnect_writer, "ZZ", asyncio.get_running_loop().time()
        )
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "H0", ("1", "412", "31", "99", "0")
        ))
        location_frame = Frame(
            "ZZ", self.service.target_imei, "D0",
            ("0", "124458.00", "A", "2237.7514", "N", "11408.6214", "E",
             "6", "0.21", "151216", "10", "M", "A"),
        )

        await self.service.process_frame(location_frame)
        await self.service.process_frame(location_frame)

        self.assertEqual(reconnect_writer.data.count(b",D0#"), 2)
        self.assertEqual(self.database.alarms(self.service.vehicle_id), [])
        self.assertIsNone(self.service._reconnect_workflow)
        event_types = [
            event["event_type"]
            for event in self.database.alarm_events(self.service.vehicle_id)
        ]
        self.assertIn("offline_check_duplicate_location", event_types)

    async def test_reconnect_check_waits_for_active_tracking_command(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", 1
        )
        self.database.save_location(
            self.service.vehicle_id, source="tracking", device_timestamp=1,
            valid=True, latitude=22.6200, longitude=114.14369, satellites=6,
            hdop=0.8, altitude_m=10.0, mode="A", raw_fields=("baseline",),
        )
        self.database.mark_device_disconnected(self.service.vehicle_id, now=2)
        tracking = self.create(
            "tracking.set_policy",
            parameters={"interval_seconds": 3600, "reason": "existing"},
        )
        reconnect_writer = FakeWriter()
        self.service.session = DeviceSession(
            reconnect_writer, "ZZ", asyncio.get_running_loop().time()
        )
        await self.service.dispatch_command(tracking["id"])

        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "H0", ("1", "412", "31", "99", "0")
        ))
        self.assertEqual(
            self.database.active_command(self.service.vehicle_id)["id"], tracking["id"]
        )
        self.assertEqual(reconnect_writer.data.count(b",D0#"), 0)

        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "D1", ("3600",)
        ))
        active = self.database.active_command(self.service.vehicle_id)
        self.assertEqual(active["command_type"], "location.once")
        self.assertEqual(active["parameters"]["location_source"], "reconnect_check")
        self.assertEqual(reconnect_writer.data.count(b",D0#"), 1)

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

    async def test_physical_lock_confirmation_starts_grace_period(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", int(time.time())
        )
        command = self.create(
            "security.confirm_locked",
            parameters={"physical_lock_confirmed": True},
        )
        await self.service.dispatch_command(command["id"])
        result = self.database.command(command["id"])
        vehicle = self.database.vehicle(self.service.vehicle_id)
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(vehicle["security_state"], "grace_period")
        self.assertGreater(vehicle["grace_until"], int(time.time()))
        self.assertIsNotNone(self.service._grace_task)

    async def test_manual_arm_requires_unlocked_warning_confirmation(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "unlocked", "test", int(time.time())
        )
        rejected = self.create("security.arm")
        await self.service.dispatch_command(rejected["id"])
        self.assertEqual(
            self.database.command(rejected["id"])["error_code"],
            "unlocked_arm_warning_required",
        )

        accepted = self.create(
            "security.arm", parameters={"unlocked_warning_confirmed": True}
        )
        await self.service.dispatch_command(accepted["id"])
        result = self.database.command(accepted["id"])
        self.assertEqual(result["status"], "succeeded")
        self.assertTrue(result["result"]["mechanical_lock_warning"])
        self.assertEqual(
            self.database.vehicle(self.service.vehicle_id)["security_state"], "armed"
        )

    async def test_w0_grace_is_suppressed_and_acknowledged(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", int(time.time())
        )
        self.database.start_lock_grace(self.service.vehicle_id, 300)
        self.writer.data.clear()
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "W0", ("1",)
        ))
        self.assertIn(b",W0#", self.writer.data)
        self.assertEqual(self.database.alarms(self.service.vehicle_id), [])
        self.assertIsNone(self.database.active_command(self.service.vehicle_id))
        self.assertEqual(
            self.database.alarm_events(self.service.vehicle_id)[0]["event_type"],
            "movement_suppressed",
        )

    async def test_w0_alarm_runs_d1_then_d0_and_alarm_api(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", int(time.time())
        )
        self.database.arm_security(self.service.vehicle_id)
        self.writer.data.clear()
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "W0", ("1",)
        ))
        alarm = self.database.alarms(self.service.vehicle_id, active_only=True)[0]
        active = self.database.active_command(self.service.vehicle_id)
        self.assertEqual(active["command_type"], "tracking.set_policy")
        self.assertIn(b",W0#", self.writer.data)
        self.assertIn(b",D1,300#", self.writer.data)

        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "D1", ("300",)
        ))
        active = self.database.active_command(self.service.vehicle_id)
        self.assertEqual(active["command_type"], "location.once")
        self.assertIn(b",D0#", self.writer.data)
        fields = (
            "0", "124458.00", "A", "2237.7514", "N", "11408.6214", "E",
            "6", "0.21", "151216", "10", "M", "A",
        )
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "D0", fields
        ))
        location = self.database.latest_location(self.service.vehicle_id)
        self.assertEqual(location["source"], "alarm")
        self.assertEqual(location["alarm_id"], alarm["id"])
        self.assertIsNone(self.service._alarm_workflow)

        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        code = self.database.create_pairing_code()
        paired = self.database.complete_pairing(code, "iPhone", "token", public)
        payload, status = await self.service.route(HTTPSpec(
            "GET", "/api/v1/alarms", "state=active",
            {"x-client-id": paired["client_id"], "authorization": "Bearer token"}, b"",
        ))
        self.assertEqual(status, 200)
        self.assertEqual(payload["alarms"][0]["id"], alarm["id"])

    async def test_alarm_workflow_uses_confirmed_d1_without_resending(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", int(time.time())
        )
        self.database.arm_security(self.service.vehicle_id)
        self.database.update_vehicle_state(
            self.service.vehicle_id,
            desired_tracking_interval=300,
            confirmed_tracking_interval=300,
        )
        self.writer.data.clear()
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "W0", ("1",)
        ))
        active = self.database.active_command(self.service.vehicle_id)
        self.assertEqual(active["command_type"], "location.once")
        self.assertNotIn(b",D1,300#", self.writer.data)
        self.assertIn(b",D0#", self.writer.data)

    async def test_w0_waits_for_existing_command_before_alarm_workflow(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", int(time.time())
        )
        self.database.arm_security(self.service.vehicle_id)
        find_sound = self.create("vehicle.find_sound")
        await self.service.dispatch_command(find_sound["id"])
        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "W0", ("1",)
        ))
        self.assertEqual(
            self.database.active_command(self.service.vehicle_id)["id"], find_sound["id"]
        )

        await self.service.process_frame(Frame(
            "ZZ", self.service.target_imei, "V0", ("2",)
        ))
        active = self.database.active_command(self.service.vehicle_id)
        self.assertEqual(active["command_type"], "tracking.set_policy")
        self.assertEqual(active["parameters"]["interval_seconds"], 300)

    async def test_background_start_completes_expired_grace(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", 100
        )
        self.database.start_lock_grace(self.service.vehicle_id, 300, now=100)
        await self.service.start_background_tasks()
        self.assertEqual(
            self.database.vehicle(self.service.vehicle_id)["security_state"], "armed"
        )
        self.assertIsNone(self.service._grace_task)

    async def test_alarm_acknowledge_succeeds_offline_without_queued_d1(self):
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", int(time.time())
        )
        self.database.arm_security(self.service.vehicle_id)
        alarm = self.database.record_movement_event(self.service.vehicle_id)["alarm"]
        self.writer.closed = True
        command = self.create("alarm.acknowledge")
        await self.service.dispatch_command(command["id"])
        self.assertEqual(self.database.command(command["id"])["status"], "succeeded")
        self.assertEqual(self.database.alarm(alarm["id"])["state"], "acknowledged")
        vehicle = self.database.vehicle(self.service.vehicle_id)
        self.assertEqual(vehicle["security_state"], "armed")
        self.assertEqual(vehicle["desired_tracking_interval"], 3600)
        self.assertIsNone(self.database.active_command(self.service.vehicle_id))

    async def test_trip_history_and_retention_settings_api(self):
        now = int(time.time())
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "unlocked", "test", now - 120
        )
        trip_id = self.database.vehicle(self.service.vehicle_id)["active_trip_id"]
        self.database.save_location(
            self.service.vehicle_id, source="tracking", device_timestamp=now - 60,
            valid=True, latitude=30.0, longitude=120.0, satellites=6,
            hdop=0.8, altitude_m=10.0, mode="A", raw_fields=("trip-api",),
        )
        self.database.apply_confirmed_lock_state(
            self.service.vehicle_id, "locked", "test", now
        )
        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        code = self.database.create_pairing_code()
        paired = self.database.complete_pairing(code, "iPhone", "token", public)
        headers = {
            "x-client-id": paired["client_id"],
            "authorization": "Bearer token",
        }

        trips, status = await self.service.route(HTTPSpec(
            "GET", "/api/v1/trips", "limit=10", headers, b"",
        ))
        self.assertEqual(status, 200)
        self.assertEqual(trips["trips"][0]["id"], trip_id)
        detail, status = await self.service.route(HTTPSpec(
            "GET", f"/api/v1/trips/{trip_id}", "", headers, b"",
        ))
        self.assertEqual(status, 200)
        self.assertEqual(detail["trip"]["point_count"], 1)
        self.assertEqual(len(detail["points"]), 1)
        settings, status = await self.service.route(HTTPSpec(
            "GET", "/api/v1/settings", "", headers, b"",
        ))
        self.assertEqual(status, 200)
        self.assertEqual(settings["settings"]["location_history_days"], 7)

        self.service._verify_control_signature = lambda request, client: None
        expanded, status = await self.service.route(HTTPSpec(
            "PUT", "/api/v1/settings/location-history", "", headers,
            json.dumps({"days": 30}).encode(),
        ))
        self.assertEqual(status, 200)
        self.assertEqual(expanded["settings"]["location_history_days"], 30)
        with self.assertRaises(APIError) as context:
            await self.service.route(HTTPSpec(
                "PUT", "/api/v1/settings/location-history", "", headers,
                json.dumps({"days": 7}).encode(),
            ))
        self.assertEqual(
            context.exception.code, "history_shorten_confirmation_required"
        )
        shortened, status = await self.service.route(HTTPSpec(
            "PUT", "/api/v1/settings/location-history", "", headers,
            json.dumps({"days": 7, "confirm_shorten": True}).encode(),
        ))
        self.assertEqual(status, 200)
        self.assertEqual(
            shortened["settings"]["pending_location_history_days"], 7
        )
        self.assertEqual(settings["settings"]["silence_window_seconds"], 420)
        self.assertEqual(settings["settings"]["offline_window_seconds"], 720)
        self.assertEqual(
            settings["settings"]["mutable_fields"], ["location_history_days"]
        )

    async def test_capability_catalog_is_static_and_maintenance_stays_disabled(self):
        command = self.create("vehicle.find_sound")
        self.database.transition_command(
            command["id"], "succeeded", {"function": "V0"}
        )

        catalog = self.service.capabilities()

        self.assertGreaterEqual(len(catalog), 30)
        self.assertEqual(catalog["vehicle.unlock"]["protocol"], "L0")
        self.assertEqual(
            catalog["vehicle.unlock"]["support_status"], "实车已验证"
        )
        self.assertEqual(
            catalog["vehicle.find_sound"]["latest_result"]["status"], "succeeded"
        )
        self.assertEqual(
            catalog["vehicle.find_sound"]["latest_result"]["raw_response_summary"],
            '{"function":"V0"}',
        )
        self.assertFalse(catalog["wheel_lock"]["enabled"])
        self.assertFalse(catalog["wheel_lock"]["executable"])
        self.assertEqual(catalog["wheel_lock"]["support_status"], "不适用")
        self.assertFalse(catalog["iot.k0"]["enabled"])
        self.assertEqual(catalog["iot.k0"]["support_status"], "危险维护")

    async def test_audit_and_device_session_apis_return_only_digest(self):
        stored = self.database.open_device_session(
            self.service.vehicle_id, "0123456789abcdef"
        )
        self.service.session.session_id = stored["id"]
        self.database.record_device_rx(stored["id"], "H0")
        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        code = self.database.create_pairing_code()
        paired = self.database.complete_pairing(code, "iPhone", "token", public)
        headers = {
            "x-client-id": paired["client_id"],
            "authorization": "Bearer token",
        }

        sessions, status = await self.service.route(HTTPSpec(
            "GET", "/api/v1/device-sessions", "limit=10", headers, b"",
        ))
        self.assertEqual(status, 200)
        current = sessions["device_sessions"][0]
        self.assertTrue(current["current"])
        self.assertEqual(current["peer_fingerprint"], "0123456789abcdef")
        self.assertNotIn("peer_address", current)
        self.assertEqual(current["rx_count"], 1)
        self.assertIsNotNone(current["last_h0_at"])

        audit, status = await self.service.route(HTTPSpec(
            "GET", "/api/v1/audit-logs", "limit=20", headers, b"",
        ))
        self.assertEqual(status, 200)
        self.assertTrue(audit["audit_logs"])
        self.assertNotIn("token", str(audit["audit_logs"]))

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

    async def test_signed_ble_event_applies_without_vehicle_lock_command(self):
        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        code = self.database.create_pairing_code()
        paired = self.database.complete_pairing(code, "iPhone", "token", public)
        self.service._verify_control_signature = lambda request, client: None
        event_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        body = json.dumps({
            "event_id": event_id,
            "action": "unlock",
            "ble_result": "succeeded",
            "readback_lock_state": "unlocked",
            "device_operation_at": int(time.time()),
        }).encode()
        request = HTTPSpec(
            "POST", "/api/v1/ble-events", "",
            {"x-client-id": paired["client_id"], "authorization": "Bearer token",
             "idempotency-key": event_id}, body,
        )
        payload, status = await self.service.route(request)
        self.assertEqual(status, 201)
        self.assertTrue(payload["event"]["state_effect_applied"])
        self.assertEqual(self.database.vehicle(self.service.vehicle_id)["lock_state"], "unlocked")
        self.assertIn(b",D1,60#", self.writer.data)
        self.assertNotIn(b",L0,", self.writer.data)
        self.assertNotIn(b",L1,", self.writer.data)
        self.assertNotIn(b",R0,", self.writer.data)
        self.assertEqual(
            {command["command_type"] for command in self.database.commands()},
            {"tracking.set_policy"},
        )

        repeated, repeated_status = await self.service.route(request)
        self.assertEqual(repeated_status, 200)
        self.assertFalse(repeated["created"])
        self.assertEqual(len(self.database.commands()), 1)

    async def test_signed_ble_event_applies_offline_without_downlink(self):
        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        code = self.database.create_pairing_code()
        paired = self.database.complete_pairing(code, "iPhone", "token", public)
        self.service._verify_control_signature = lambda request, client: None
        self.writer.closed = True
        event_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        body = json.dumps({
            "event_id": event_id,
            "action": "lock",
            "ble_result": "succeeded",
            "readback_lock_state": "locked",
            "device_operation_at": int(time.time()),
        }).encode()
        payload, status = await self.service.route(HTTPSpec(
            "POST", "/api/v1/ble-events", "",
            {"x-client-id": paired["client_id"], "authorization": "Bearer token",
             "idempotency-key": event_id}, body,
        ))
        self.assertEqual(status, 201)
        self.assertTrue(payload["event"]["state_effect_applied"])
        self.assertEqual(self.database.commands(), [])
        self.assertEqual(self.writer.data, b"")

    async def test_stale_ble_event_is_accepted_for_audit_only(self):
        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        code = self.database.create_pairing_code()
        paired = self.database.complete_pairing(code, "iPhone", "token", public)
        self.service._verify_control_signature = lambda request, client: None
        event_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        body = json.dumps({
            "event_id": event_id,
            "action": "unlock",
            "ble_result": "succeeded",
            "readback_lock_state": "unlocked",
            "device_operation_at": int(time.time()) - 90000,
        }).encode()
        payload, status = await self.service.route(HTTPSpec(
            "POST", "/api/v1/ble-events", "",
            {"x-client-id": paired["client_id"], "authorization": "Bearer token",
             "idempotency-key": event_id}, body,
        ))
        self.assertEqual(status, 201)
        self.assertFalse(payload["event"]["state_effect_applied"])
        self.assertEqual(payload["event"]["ignored_reason"], "stale_over_24h")
        self.assertEqual(self.database.vehicle(self.service.vehicle_id)["lock_state"], "unknown")
        self.assertEqual(self.database.commands(), [])

    async def test_ble_event_rejects_mismatched_idempotency_key(self):
        public = b"\x04" + GX.to_bytes(32, "big") + GY.to_bytes(32, "big")
        code = self.database.create_pairing_code()
        paired = self.database.complete_pairing(code, "iPhone", "token", public)
        self.service._verify_control_signature = lambda request, client: None
        event_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        body = json.dumps({
            "event_id": event_id,
            "action": "lock",
            "ble_result": "succeeded",
            "readback_lock_state": "locked",
            "device_operation_at": int(time.time()),
        }).encode()
        with self.assertRaises(APIError) as context:
            await self.service.route(HTTPSpec(
                "POST", "/api/v1/ble-events", "",
                {"x-client-id": paired["client_id"], "authorization": "Bearer token",
                 "idempotency-key": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"}, body,
            ))
        self.assertEqual(context.exception.code, "invalid_ble_event_idempotency")
        count = self.database.connection.execute(
            "SELECT COUNT(*) FROM ble_events"
        ).fetchone()[0]
        self.assertEqual(count, 0)

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

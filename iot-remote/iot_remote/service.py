"""IoT TCP 网关、HTTP API 和单命令状态机。"""

import asyncio
import json
import logging
import signal
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, time as datetime_time, timedelta
from typing import Any, Optional
from urllib.parse import parse_qs, urlsplit
from zoneinfo import ZoneInfo

from .crypto import canonical_request, decode_base64, sha256_hex, verify_p256_raw
from .database import Database
from .protocol import Frame, build_downlink, parse_d0, parse_frame, split_frames


LOGGER = logging.getLogger("iot_remote")
TERMINAL = {"succeeded", "failed", "unknown", "noop", "rejected"}
SIGNED_COMMANDS = {
    "vehicle.unlock", "vehicle.lock", "tracking.set_policy",
    "security.confirm_locked", "security.arm", "alarm.acknowledge",
}
SUPPORTED_COMMANDS = {
    "vehicle.unlock", "vehicle.lock", "vehicle.find_sound",
    "telemetry.refresh", "location.once", "tracking.set_policy",
    "security.confirm_locked", "security.arm", "alarm.acknowledge",
}
SERVER_COMMANDS = {"security.confirm_locked", "security.arm", "alarm.acknowledge"}
TRACKING_POLICIES = {"unlocked": 60, "locked": 3600, "alarm": 300}


class APIError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


@dataclass
class HTTPSpec:
    method: str
    path: str
    query: str
    headers: dict[str, str]
    body: bytes


@dataclass
class DeviceSession:
    writer: asyncio.StreamWriter
    vendor: str
    last_frame_at: float
    policy_reconciled: bool = False


class RemoteService:
    def __init__(self, database: Database, target_imei: str, vehicle_name: str,
                 command_timeout: int = 30, silence_window: int = 420,
                 offline_window: int = 720, revision: str = "dev",
                 location_min_satellites: int = 4,
                 location_max_hdop: float = 8.0,
                 location_max_speed_mps: float = 25.0,
                 lock_grace_seconds: int = 300,
                 offline_movement_threshold_m: float = 200.0,
                 offline_sample_max_separation_m: float = 75.0):
        if silence_window <= 0 or offline_window <= silence_window:
            raise ValueError("通信静默与离线阈值无效")
        if (location_min_satellites < 0 or location_max_hdop <= 0
                or location_max_speed_mps <= 0):
            raise ValueError("定位质量阈值无效")
        if lock_grace_seconds <= 0:
            raise ValueError("布防等待时间无效")
        if (offline_movement_threshold_m <= 0
                or offline_sample_max_separation_m <= 0):
            raise ValueError("离线移动阈值无效")
        self.database = database
        self.target_imei = target_imei
        self.vehicle_id = database.ensure_vehicle(target_imei, vehicle_name)
        self.command_timeout = command_timeout
        self.silence_window = silence_window
        self.offline_window = offline_window
        self.revision = revision
        self.location_min_satellites = location_min_satellites
        self.location_max_hdop = location_max_hdop
        self.location_max_speed_mps = location_max_speed_mps
        self.lock_grace_seconds = lock_grace_seconds
        self.offline_movement_threshold_m = offline_movement_threshold_m
        self.offline_sample_max_separation_m = offline_sample_max_separation_m
        self.session: Optional[DeviceSession] = None
        self._session_lock = asyncio.Lock()
        self._timeout_tasks: dict[str, asyncio.Task[None]] = {}
        self._pairing_failures: list[float] = []
        self._policy_reconcile_pending = False
        self._grace_task: Optional[asyncio.Task[None]] = None
        self._cleanup_task: Optional[asyncio.Task[None]] = None
        self._alarm_workflow: Optional[dict[str, str]] = None
        self._reconnect_workflow: Optional[dict[str, Any]] = None
        self.database.mark_inflight_unknown()

    def is_online(self) -> bool:
        return self.connectivity_state() == "online"

    def connectivity_state(self) -> str:
        if self.session is None or self.session.writer.is_closing():
            return "offline"
        age = time.monotonic() - self.session.last_frame_at
        if age <= self.silence_window:
            return "online"
        if age <= self.offline_window:
            return "silent"
        return "offline"

    def last_frame_age_seconds(self) -> Optional[int]:
        if self.session is None or self.session.writer.is_closing():
            return None
        return max(0, int(time.monotonic() - self.session.last_frame_at))

    async def shutdown(self) -> None:
        if self._cleanup_task:
            self._cleanup_task.cancel()
            await asyncio.gather(self._cleanup_task, return_exceptions=True)
            self._cleanup_task = None
        if self._grace_task:
            self._grace_task.cancel()
            await asyncio.gather(self._grace_task, return_exceptions=True)
            self._grace_task = None
        self._alarm_workflow = None
        if self._reconnect_workflow is not None:
            self.database.clear_offline_check(
                self.vehicle_id, "offline_check_service_stopped"
            )
            self._reconnect_workflow = None
        for task in self._timeout_tasks.values():
            task.cancel()
        if self._timeout_tasks:
            await asyncio.gather(*self._timeout_tasks.values(), return_exceptions=True)
        self._timeout_tasks.clear()

        writer: Optional[asyncio.StreamWriter] = None
        async with self._session_lock:
            if self.session is not None:
                writer = self.session.writer
                self.session = None
            self.database.update_vehicle_state(self.vehicle_id, online=0)
            active = self.database.active_command(self.vehicle_id)
            if active:
                self._finish(active["id"], "unknown", "service_stopped")
        if writer is not None:
            await _close_writer(writer)

    async def handle_device(self, reader: asyncio.StreamReader,
                            writer: asyncio.StreamWriter) -> None:
        buffer = b""
        authenticated = False
        LOGGER.info("device connection opened")
        try:
            while True:
                raw = await asyncio.wait_for(reader.read(1024), timeout=self.offline_window)
                if not raw:
                    break
                buffer += raw
                frames, buffer = split_frames(buffer)
                for raw_frame in frames:
                    frame = parse_frame(raw_frame)
                    if frame is None:
                        continue
                    if frame.imei != self.target_imei:
                        LOGGER.warning("rejected non-target device")
                        return
                    authenticated = True
                    await self._accept_session(writer, frame)
                    await self.process_frame(frame)
        except (asyncio.TimeoutError, ConnectionError):
            LOGGER.info("device connection ended")
        finally:
            async with self._session_lock:
                if self.session and self.session.writer is writer:
                    self.session = None
                    self._policy_reconcile_pending = False
                    self._alarm_workflow = None
                    self._reconnect_workflow = None
                    self.database.mark_device_disconnected(self.vehicle_id)
                    active = self.database.active_command(self.vehicle_id)
                    if active:
                        self._finish(active["id"], "unknown", "connection_lost")
            await _close_writer(writer)
            if not authenticated:
                LOGGER.warning("connection closed before target identity")

    async def _accept_session(self, writer: asyncio.StreamWriter, frame: Frame) -> None:
        async with self._session_lock:
            if self.session and self.session.writer is writer:
                self.session.vendor = frame.vendor
                self.session.last_frame_at = time.monotonic()
                return
            if self.session and self.session.writer is not writer:
                self.session.writer.close()
            self._policy_reconcile_pending = False
            self._reconnect_workflow = None
            self.session = DeviceSession(writer, frame.vendor, time.monotonic())
            self.database.update_vehicle_state(
                self.vehicle_id, online=1, last_seen_at=int(time.time())
            )

    async def process_frame(self, frame: Frame) -> None:
        if self.session:
            self.session.last_frame_at = time.monotonic()
        fields = tuple(field.strip() for field in frame.fields)
        reconcile_new_session = False
        location_report = None
        stored_location = None
        movement_alarm_id = None
        if frame.function == "H0" and len(fields) >= 4:
            state_time = int(time.time())
            updates: dict[str, Any] = {
                "lock_state": "locked" if fields[0] == "1" else "unlocked",
                "lock_state_source": "iot_h0",
                "lock_state_updated_at": state_time,
            }
            if fields[1].isdigit():
                updates["power_mv"] = int(fields[1])
            if fields[3].isdigit():
                updates["battery_percent"] = int(fields[3])
            self.database.update_vehicle_state(self.vehicle_id, **updates)
            self.database.reconcile_trip_for_lock_state(
                self.vehicle_id, updates["lock_state"], state_time
            )
            if self.session and not self.session.policy_reconciled:
                self.session.policy_reconciled = True
                reconcile_new_session = True
                self._policy_reconcile_pending = True
                self._prepare_reconnect_workflow(updates["lock_state"])
        elif frame.function == "S6" and fields and fields[0].isdigit():
            self.database.update_vehicle_state(
                self.vehicle_id,
                battery_percent=int(fields[0]),
                telemetry_fields_json=json.dumps(list(fields), separators=(",", ":")),
                telemetry_updated_at=int(time.time()),
            )
        elif frame.function == "D0":
            location_report = parse_d0(fields)
            if location_report is not None:
                active_location = self.database.active_command(self.vehicle_id)
                source = location_report.source
                alarm_id = None
                if (active_location and active_location["command_type"] == "location.once"
                        and active_location["parameters"].get("location_source")):
                    source = active_location["parameters"]["location_source"]
                    alarm_id = active_location["parameters"].get("alarm_id")
                stored_location = self.database.save_location(
                    self.vehicle_id,
                    source=source,
                    device_timestamp=location_report.device_timestamp,
                    valid=location_report.valid,
                    latitude=location_report.latitude,
                    longitude=location_report.longitude,
                    satellites=location_report.satellites,
                    hdop=location_report.hdop,
                    altitude_m=location_report.altitude_m,
                    mode=location_report.mode,
                    raw_fields=location_report.raw_fields,
                    min_satellites=self.location_min_satellites,
                    max_hdop=self.location_max_hdop,
                    max_speed_mps=self.location_max_speed_mps,
                    alarm_id=alarm_id,
                )
        elif frame.function == "W0":
            await self._send("W0", [])
            if fields == ("1",):
                movement = self.database.record_movement_event(self.vehicle_id)
                if movement["alarm"] is not None and self._alarm_workflow is None:
                    self._abort_reconnect_workflow("offline_check_superseded_by_w0")
                    movement_alarm_id = movement["alarm"]["id"]
                    self._alarm_workflow = {
                        "alarm_id": movement_alarm_id,
                        "stage": "tracking",
                    }

        active = self.database.active_command(self.vehicle_id)
        if active is None:
            if movement_alarm_id or reconcile_new_session:
                await self._advance_deferred_workflows()
            return
        status = active["status"]
        command_type = active["command_type"]
        parameters = active["parameters"]

        if status == "awaiting_r0" and frame.function == "R0":
            expected_operation = "0" if command_type == "vehicle.unlock" else "1"
            verified = (
                len(fields) >= 4 and fields[0] == expected_operation and fields[1].isdigit()
                and 0 <= int(fields[1]) <= 255 and fields[2] == parameters["user_id"]
                and fields[3] == parameters["timestamp"]
            )
            if not verified:
                self._finish(active["id"], "failed", "invalid_r0_response")
                return
            control = "L0" if command_type == "vehicle.unlock" else "L1"
            control_fields = [fields[1]]
            if control == "L0":
                control_fields.extend([parameters["user_id"], parameters["timestamp"]])
            await self._send(control, control_fields)
            self.database.transition_command(active["id"], "awaiting_result")
            return

        if status != "awaiting_result":
            return
        verified = False
        if command_type == "vehicle.unlock" and frame.function == "L0":
            verified = (
                len(fields) >= 3 and fields[0] == "0"
                and fields[1] == parameters["user_id"]
                and fields[2] == parameters["timestamp"]
            )
        elif command_type == "vehicle.find_sound" and frame.function == "V0":
            verified = fields == ("2",)
        elif command_type == "telemetry.refresh" and frame.function == "S6":
            verified = len(fields) >= 8
        elif command_type == "location.once" and frame.function == "D0":
            verified = location_report is not None and location_report.source == "once"
        elif command_type == "vehicle.lock" and frame.function == "L1":
            verified = len(fields) >= 1 and fields[0] == "0"
        elif command_type == "tracking.set_policy" and frame.function == "D1":
            expected = parameters.get("interval_seconds")
            verified = len(fields) == 1 and fields[0].isdigit() and int(fields[0]) == expected

        if not verified:
            expected_function = {
                "vehicle.unlock": "L0",
                "vehicle.lock": "L1",
                "vehicle.find_sound": "V0",
                "telemetry.refresh": "S6",
                "location.once": "D0",
                "tracking.set_policy": "D1",
            }.get(command_type)
            scheduled_location = (
                command_type == "location.once" and location_report is not None
                and location_report.source == "tracking"
            )
            if frame.function == expected_function and not scheduled_location:
                self._finish(active["id"], "failed", "invalid_device_response")
                if command_type == "tracking.set_policy" and self._alarm_workflow:
                    await self._advance_alarm_workflow()
                elif command_type == "location.once" and self._alarm_workflow:
                    if self._alarm_workflow["stage"] == "awaiting_location":
                        self._alarm_workflow = None
                    else:
                        await self._advance_alarm_workflow()
                elif (command_type == "location.once"
                      and parameters.get("location_source") == "reconnect_check"):
                    self._abort_reconnect_workflow(
                        "offline_check_invalid_response",
                        {"sample_index": parameters.get("sample_index")},
                    )
                    await self._advance_deferred_workflows()
                elif command_type != "tracking.set_policy":
                    await self._reconcile_pending_policy()
                else:
                    await self._advance_deferred_workflows()
            return
        if frame.function in {"L0", "L1"}:
            await self._send(frame.function, [])
        if command_type == "vehicle.unlock":
            self.database.apply_confirmed_lock_state(
                self.vehicle_id, "unlocked", "remote_command", int(time.time()),
                parameters["user_id"], parameters["timestamp"], active["id"],
            )
        elif command_type == "vehicle.lock":
            self.database.apply_confirmed_lock_state(
                self.vehicle_id, "locked", "remote_command", int(time.time()),
                command_id=active["id"],
            )
        elif command_type == "tracking.set_policy":
            self.database.update_vehicle_state(
                self.vehicle_id,
                confirmed_tracking_interval=parameters["interval_seconds"],
                tracking_confirmed_at=int(time.time()),
            )
        detail = {"function": frame.function}
        if command_type == "vehicle.lock":
            detail["physical_confirmation_required"] = True
        elif command_type == "location.once" and stored_location is not None:
            detail["location_id"] = stored_location["id"]
            detail["location_valid"] = stored_location["valid"]
            detail["location_display_eligible"] = stored_location["display_eligible"]
            detail["location_rejection_reason"] = stored_location["rejection_reason"]
        elif command_type == "tracking.set_policy":
            detail["confirmed_tracking_interval"] = parameters["interval_seconds"]
        self._finish(active["id"], "succeeded", None, detail)
        if command_type in {"vehicle.unlock", "vehicle.lock"}:
            self._policy_reconcile_pending = False
            await self.reconcile_tracking_policy("lock_state_changed")
        elif command_type == "tracking.set_policy" and self._alarm_workflow:
            await self._advance_alarm_workflow()
        elif (command_type == "location.once"
              and parameters.get("location_source") == "reconnect_check"):
            await self._complete_reconnect_location(
                stored_location, parameters.get("sample_index")
            )
        elif command_type == "location.once" and self._alarm_workflow:
            if self._alarm_workflow["stage"] == "awaiting_location":
                self._alarm_workflow = None
            else:
                await self._advance_alarm_workflow()
            await self._advance_deferred_workflows()
        else:
            await self._advance_deferred_workflows()

    async def start_background_tasks(self) -> None:
        self.database.arm_if_grace_expired(self.vehicle_id)
        self.database.recover_active_trip_if_needed(self.vehicle_id)
        self._schedule_grace_timer()
        if self._cleanup_task is None:
            self._cleanup_task = asyncio.create_task(self._retention_cleanup_loop())

    async def _retention_cleanup_loop(self) -> None:
        timezone = ZoneInfo("Asia/Shanghai")
        try:
            while True:
                now = datetime.now(timezone)
                next_run = datetime.combine(
                    now.date(), datetime_time(hour=3, minute=30), timezone
                )
                if next_run <= now:
                    next_run += timedelta(days=1)
                await asyncio.sleep((next_run - now).total_seconds())
                try:
                    result = self.database.run_retention_cleanup(self.vehicle_id)
                    LOGGER.info(
                        "retention cleanup completed trips=%s locations=%s days=%s",
                        result["deleted_trips"], result["deleted_locations"],
                        result["history_days"],
                    )
                except Exception:
                    LOGGER.exception("retention cleanup failed")
        except asyncio.CancelledError:
            pass

    def _schedule_grace_timer(self) -> None:
        if self._grace_task:
            self._grace_task.cancel()
            self._grace_task = None
        vehicle = self.database.vehicle(self.vehicle_id)
        if vehicle["security_state"] != "grace_period" or vehicle["grace_until"] is None:
            return
        delay = max(0, vehicle["grace_until"] - int(time.time()))
        self._grace_task = asyncio.create_task(self._complete_grace_after(delay))

    async def _complete_grace_after(self, delay: int) -> None:
        try:
            await asyncio.sleep(delay)
            self.database.arm_if_grace_expired(self.vehicle_id)
        except asyncio.CancelledError:
            pass
        finally:
            if self._grace_task is asyncio.current_task():
                self._grace_task = None

    def _prepare_reconnect_workflow(self, confirmed_lock_state: str) -> None:
        pending = self.database.pending_offline_check(self.vehicle_id)
        if pending is None:
            return
        vehicle = self.database.vehicle(self.vehicle_id)
        baseline = pending["baseline_location"]
        if confirmed_lock_state != "locked":
            self.database.clear_offline_check(
                self.vehicle_id, "offline_check_skipped_unlocked"
            )
            return
        if baseline is None:
            self.database.clear_offline_check(
                self.vehicle_id, "offline_check_skipped_no_baseline"
            )
            return
        if vehicle["active_alarm_id"] is not None:
            self.database.clear_offline_check(
                self.vehicle_id, "offline_check_skipped_active_alarm"
            )
            return
        self._reconnect_workflow = {
            "stage": "first",
            "offline_started_at": pending["offline_since"],
            "baseline_location_id": baseline["id"],
        }

    def _abort_reconnect_workflow(
        self, event_type: str, detail: Optional[dict[str, Any]] = None,
    ) -> None:
        if self._reconnect_workflow is None:
            return
        self._reconnect_workflow = None
        self.database.clear_offline_check(self.vehicle_id, event_type, detail)

    async def _advance_reconnect_workflow(self) -> None:
        workflow = self._reconnect_workflow
        if workflow is None or self.database.active_command(self.vehicle_id):
            return
        if not self.is_online():
            self._abort_reconnect_workflow("offline_check_connection_lost")
            return
        if workflow["stage"] not in {"first", "second"}:
            return
        sample_index = 1 if workflow["stage"] == "first" else 2
        workflow["stage"] = "awaiting_first" if sample_index == 1 else "awaiting_second"
        command, _ = self.database.create_command(
            self.vehicle_id, None, "location.once",
            {"location_source": "reconnect_check", "sample_index": sample_index}, None,
        )
        await self.dispatch_command(command["id"])
        if self.database.command(command["id"])["status"] in TERMINAL:
            self._abort_reconnect_workflow(
                "offline_check_request_failed", {"sample_index": sample_index}
            )

    async def _complete_reconnect_location(
        self, location: Optional[dict[str, Any]], sample_index: Any,
    ) -> None:
        workflow = self._reconnect_workflow
        expected_stage = "awaiting_first" if sample_index == 1 else "awaiting_second"
        if workflow is None or workflow.get("stage") != expected_stage:
            return
        if location is None or not location["valid"] or not location["display_eligible"]:
            self._abort_reconnect_workflow(
                "offline_check_untrusted_location",
                {
                    "sample_index": sample_index,
                    "rejection_reason": location.get("rejection_reason") if location else None,
                },
            )
            await self._advance_deferred_workflows()
            return
        if sample_index == 1:
            workflow["reconnect_location_one_id"] = location["id"]
            workflow["stage"] = "second"
            await self._advance_reconnect_workflow()
            return
        if location["id"] == workflow["reconnect_location_one_id"]:
            self._abort_reconnect_workflow(
                "offline_check_duplicate_location", {"sample_index": sample_index}
            )
            await self._advance_deferred_workflows()
            return
        result = self.database.finalize_offline_movement_check(
            self.vehicle_id,
            offline_started_at=workflow["offline_started_at"],
            baseline_location_id=workflow["baseline_location_id"],
            reconnect_location_one_id=workflow["reconnect_location_one_id"],
            reconnect_location_two_id=location["id"],
            movement_threshold_m=self.offline_movement_threshold_m,
            sample_max_separation_m=self.offline_sample_max_separation_m,
        )
        self._reconnect_workflow = None
        if result["inferred"]:
            self.database.update_vehicle_state(
                self.vehicle_id,
                desired_tracking_interval=TRACKING_POLICIES["alarm"],
            )
        await self._advance_deferred_workflows()

    async def _advance_deferred_workflows(self) -> None:
        if self.database.active_command(self.vehicle_id):
            return
        if self._alarm_workflow is not None:
            await self._advance_alarm_workflow()
            if self.database.active_command(self.vehicle_id):
                return
        if self._reconnect_workflow is not None:
            await self._advance_reconnect_workflow()
            if self.database.active_command(self.vehicle_id):
                return
        await self._reconcile_pending_policy()

    async def _advance_alarm_workflow(self) -> None:
        workflow = self._alarm_workflow
        if workflow is None or self.database.active_command(self.vehicle_id):
            return
        if not self.is_online():
            self._alarm_workflow = None
            return
        if workflow["stage"] == "tracking":
            self.database.update_vehicle_state(
                self.vehicle_id, desired_tracking_interval=TRACKING_POLICIES["alarm"]
            )
            workflow["stage"] = "location"
            vehicle = self.database.vehicle(self.vehicle_id)
            if vehicle["confirmed_tracking_interval"] != TRACKING_POLICIES["alarm"]:
                command, _ = self.database.create_command(
                    self.vehicle_id, None, "tracking.set_policy",
                    {"interval_seconds": TRACKING_POLICIES["alarm"],
                     "reason": "alarm_workflow"}, None,
                )
                await self.dispatch_command(command["id"])
                if self.database.command(command["id"])["status"] in TERMINAL:
                    await self._advance_alarm_workflow()
                return
        if workflow["stage"] == "location":
            workflow["stage"] = "awaiting_location"
            command, _ = self.database.create_command(
                self.vehicle_id, None, "location.once",
                {"location_source": "alarm", "alarm_id": workflow["alarm_id"]}, None,
            )
            await self.dispatch_command(command["id"])
            if self.database.command(command["id"])["status"] in TERMINAL:
                self._alarm_workflow = None

    def desired_tracking_interval(self) -> Optional[int]:
        vehicle = self.database.vehicle(self.vehicle_id)
        if vehicle["security_state"] == "alarm_active":
            return TRACKING_POLICIES["alarm"]
        if vehicle["lock_state"] == "unlocked":
            return TRACKING_POLICIES["unlocked"]
        if vehicle["lock_state"] == "locked":
            return TRACKING_POLICIES["locked"]
        return None

    async def reconcile_tracking_policy(self, reason: str) -> Optional[dict[str, Any]]:
        interval = self.desired_tracking_interval()
        if interval is None:
            return None
        self.database.update_vehicle_state(
            self.vehicle_id, desired_tracking_interval=interval
        )
        vehicle = self.database.vehicle(self.vehicle_id)
        if vehicle["confirmed_tracking_interval"] == interval:
            return None
        if not self.is_online() or self.database.active_command(self.vehicle_id):
            return None
        command, _ = self.database.create_command(
            self.vehicle_id, None, "tracking.set_policy",
            {"interval_seconds": interval, "reason": reason}, None,
        )
        await self.dispatch_command(command["id"])
        return self.database.command(command["id"])

    async def _reconcile_pending_policy(self) -> None:
        if not self._policy_reconcile_pending:
            return
        self._policy_reconcile_pending = False
        await self.reconcile_tracking_policy("session_h0")

    async def _send(self, function: str, fields: list[str]) -> None:
        if not self.is_online() or self.session is None:
            raise ConnectionError("device offline")
        self.session.writer.write(
            build_downlink(self.session.vendor, self.target_imei, function, fields)
        )
        await self.session.writer.drain()
        LOGGER.info("downlink sent function=%s", function)

    async def dispatch_command(self, command_id: str) -> None:
        command = self.database.command(command_id)
        if command["status"] in TERMINAL:
            return
        command_type = command["command_type"]
        vehicle = self.database.vehicle(self.vehicle_id)
        if command_type in SERVER_COMMANDS:
            await self._dispatch_server_command(command, vehicle)
            return
        if not self.is_online():
            self._finish(command_id, "rejected", "device_offline")
            return
        desired = {
            "vehicle.unlock": "unlocked",
            "vehicle.lock": "locked",
        }.get(command_type)
        if desired and vehicle["lock_state"] == desired:
            self._finish(command_id, "noop", None, {"reason": "already_in_state"})
            return
        if command_type == "vehicle.lock" and command["parameters"].get("stationary_confirmed") is not True:
            self._finish(command_id, "rejected", "stationary_confirmation_required")
            return
        if command_type == "tracking.set_policy":
            interval = command["parameters"].get("interval_seconds")
            if interval not in TRACKING_POLICIES.values():
                self._finish(command_id, "rejected", "invalid_tracking_policy")
                return
            self.database.update_vehicle_state(
                self.vehicle_id, desired_tracking_interval=interval
            )
            if vehicle["confirmed_tracking_interval"] == interval:
                self._finish(command_id, "noop", None, {"reason": "already_confirmed"})
                return
        try:
            if command_type in {"vehicle.unlock", "vehicle.lock"}:
                timestamp = str(int(time.time()))
                user_id = "1"
                command["parameters"].update({"timestamp": timestamp, "user_id": user_id})
                self.database.connection.execute(
                    "UPDATE commands SET parameters_json=? WHERE id=?",
                    (json.dumps(command["parameters"], separators=(",", ":")), command_id),
                )
                self.database.connection.commit()
                operation = "0" if command_type == "vehicle.unlock" else "1"
                await self._send("R0", [operation, "30", user_id, timestamp])
                self.database.transition_command(command_id, "awaiting_r0")
            else:
                if command_type == "tracking.set_policy":
                    function = "D1"
                    fields = [str(command["parameters"]["interval_seconds"])]
                else:
                    function, fields = {
                        "vehicle.find_sound": ("V0", ["2"]),
                        "telemetry.refresh": ("S6", []),
                        "location.once": ("D0", []),
                    }[command_type]
                await self._send(function, fields)
                self.database.transition_command(command_id, "awaiting_result")
        except (ConnectionError, KeyError):
            self._finish(command_id, "unknown", "send_failed")
            return
        self._timeout_tasks[command_id] = asyncio.create_task(self._expire(command_id))

    async def _dispatch_server_command(self, command: dict[str, Any],
                                       vehicle: dict[str, Any]) -> None:
        command_id = command["id"]
        command_type = command["command_type"]
        if command_type == "security.confirm_locked":
            if command["parameters"].get("physical_lock_confirmed") is not True:
                self._finish(command_id, "rejected", "physical_confirmation_required")
                return
            if vehicle["lock_state"] != "locked":
                self._finish(command_id, "rejected", "physical_lock_not_confirmed")
                return
            if vehicle["active_alarm_id"] is not None:
                self._finish(command_id, "rejected", "active_alarm_exists")
                return
            updated = self.database.start_lock_grace(
                self.vehicle_id, self.lock_grace_seconds
            )
            self._schedule_grace_timer()
            self._finish(
                command_id, "succeeded", None,
                {"security_state": updated["security_state"],
                 "grace_until": updated["grace_until"]},
            )
            await self.reconcile_tracking_policy("physical_lock_confirmed")
            return
        if command_type == "security.arm":
            if (vehicle["lock_state"] != "locked"
                    and command["parameters"].get("unlocked_warning_confirmed") is not True):
                self._finish(command_id, "rejected", "unlocked_arm_warning_required")
                return
            if vehicle["active_alarm_id"] is not None:
                self._finish(command_id, "rejected", "active_alarm_exists")
                return
            updated = self.database.arm_security(self.vehicle_id)
            self._schedule_grace_timer()
            self._finish(
                command_id, "succeeded", None,
                {"security_state": updated["security_state"],
                 "mechanical_lock_warning": updated["lock_state"] != "locked"},
            )
            await self.reconcile_tracking_policy("manual_armed")
            return
        alarm = self.database.acknowledge_alarm(
            self.vehicle_id, command["client_id"] or "internal"
        )
        if alarm is None:
            self._finish(command_id, "noop", None, {"reason": "no_active_alarm"})
            return
        self._alarm_workflow = None
        self._finish(
            command_id, "succeeded", None,
            {"alarm_id": alarm["id"], "alarm_state": alarm["state"]},
        )
        await self.reconcile_tracking_policy("alarm_acknowledged")

    async def _expire(self, command_id: str) -> None:
        try:
            await asyncio.sleep(self.command_timeout)
            command = self.database.command(command_id)
            if command["status"] not in TERMINAL:
                self._finish(command_id, "unknown", "device_timeout")
                if (command["command_type"] == "tracking.set_policy"
                        and self._alarm_workflow):
                    await self._advance_alarm_workflow()
                elif command["command_type"] == "location.once" and self._alarm_workflow:
                    if self._alarm_workflow["stage"] == "awaiting_location":
                        self._alarm_workflow = None
                    else:
                        await self._advance_alarm_workflow()
                elif (command["command_type"] == "location.once"
                      and command["parameters"].get("location_source") == "reconnect_check"):
                    self._abort_reconnect_workflow(
                        "offline_check_timeout",
                        {"sample_index": command["parameters"].get("sample_index")},
                    )
                    await self._advance_deferred_workflows()
                else:
                    await self._advance_deferred_workflows()
        except asyncio.CancelledError:
            pass

    def _finish(self, command_id: str, status: str, error_code: Optional[str],
                detail: Optional[dict[str, Any]] = None) -> None:
        task = self._timeout_tasks.pop(command_id, None)
        if task and task is not asyncio.current_task():
            task.cancel()
        self.database.transition_command(command_id, status, detail, error_code)

    def capabilities(self) -> dict[str, Any]:
        online = self.is_online()
        disabled_reason = None if online else f"device_{self.connectivity_state()}"
        vehicle = self.database.vehicle(self.vehicle_id)
        confirm_lock_enabled = vehicle["lock_state"] == "locked"
        acknowledge_enabled = vehicle["active_alarm_id"] is not None
        return {
            "vehicle.unlock": {"enabled": online, "reason": disabled_reason},
            "vehicle.lock": {
                "enabled": online,
                "reason": disabled_reason,
                "requires_stationary_confirmation": True,
                "physical_confirmation_required": True,
            },
            "vehicle.find_sound": {
                "enabled": online, "reason": disabled_reason, "cooldown_seconds": 10,
            },
            "telemetry.refresh": {"enabled": online, "reason": disabled_reason},
            "location.once": {"enabled": online, "reason": disabled_reason},
            "tracking.set_policy": {
                "enabled": online,
                "reason": disabled_reason,
                "allowed_policies": TRACKING_POLICIES,
            },
            "security.confirm_locked": {
                "enabled": confirm_lock_enabled,
                "reason": None if confirm_lock_enabled else "physical_lock_not_confirmed",
                "grace_seconds": self.lock_grace_seconds,
            },
            "security.arm": {"enabled": True, "reason": None},
            "alarm.acknowledge": {
                "enabled": acknowledge_enabled,
                "reason": None if acknowledge_enabled else "no_active_alarm",
            },
            "wheel_lock": {"enabled": False, "reason": "unsupported_hardware"},
        }

    async def handle_http(self, reader: asyncio.StreamReader,
                          writer: asyncio.StreamWriter) -> None:
        try:
            request = await self._read_http(reader)
            payload, status = await self.route(request)
        except APIError as exc:
            payload, status = {"error": {"code": exc.code, "message": exc.message}}, exc.status
        except (asyncio.IncompleteReadError, ConnectionError, ValueError):
            payload, status = {"error": {"code": "bad_request", "message": "请求格式错误"}}, 400
        except Exception:
            LOGGER.exception("unhandled HTTP error")
            payload, status = {"error": {"code": "internal_error", "message": "服务内部错误"}}, 500
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        reason = {200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized",
                  404: "Not Found", 409: "Conflict", 413: "Payload Too Large",
                  422: "Unprocessable Entity", 429: "Too Many Requests",
                  500: "Internal Server Error"}.get(status, "Error")
        writer.write(
            f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json; charset=utf-8\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode("ascii") + body
        )
        await writer.drain()
        await _close_writer(writer)

    async def _read_http(self, reader: asyncio.StreamReader) -> HTTPSpec:
        header = await reader.readuntil(b"\r\n\r\n")
        if len(header) > 16384:
            raise APIError(413, "headers_too_large", "请求头过大")
        lines = header[:-4].decode("iso-8859-1").split("\r\n")
        method, target, version = lines[0].split(" ", 2)
        if version != "HTTP/1.1":
            raise ValueError("unsupported HTTP version")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            name, value = line.split(":", 1)
            headers[name.lower().strip()] = value.strip()
        length = int(headers.get("content-length", "0"))
        if length < 0 or length > 65536:
            raise APIError(413, "body_too_large", "请求体过大")
        body = await reader.readexactly(length) if length else b""
        parsed = urlsplit(target)
        return HTTPSpec(method.upper(), parsed.path, parsed.query, headers, body)

    async def route(self, request: HTTPSpec) -> tuple[dict[str, Any], int]:
        if request.method == "GET" and request.path == "/healthz":
            return {
                "ok": True,
                "revision": self.revision,
                "device_online": self.is_online(),
                "device_connectivity": self.connectivity_state(),
                "last_frame_age_seconds": self.last_frame_age_seconds(),
            }, 200
        if request.method == "POST" and request.path == "/api/v1/pairings/complete":
            return self._complete_pairing(request), 201
        client = self._authenticate_read(request)
        if request.method == "GET" and request.path == "/api/v1/vehicle":
            vehicle = self.database.vehicle(self.vehicle_id)
            vehicle["online"] = self.is_online()
            vehicle["connection_state"] = self.connectivity_state()
            return {"vehicle": vehicle}, 200
        if request.method == "GET" and request.path == "/api/v1/capabilities":
            return {"capabilities": self.capabilities()}, 200
        if request.method == "GET" and request.path == "/api/v1/locations":
            query = parse_qs(request.query, keep_blank_values=True)
            try:
                limit = int(query.get("limit", ["500"])[0])
                since_raw = query.get("since", [None])[0]
                since = int(since_raw) if since_raw not in {None, ""} else None
            except ValueError:
                raise APIError(400, "invalid_location_query", "定位查询参数无效")
            if not 1 <= limit <= 2000 or since is not None and since < 0:
                raise APIError(400, "invalid_location_query", "定位查询参数超出范围")
            return {
                "latest": self.database.latest_location(self.vehicle_id, valid_only=True),
                "last_report": self.database.latest_location(self.vehicle_id, valid_only=False),
                "points": self.database.locations(self.vehicle_id, limit=limit, since=since),
            }, 200
        if request.method == "GET" and request.path == "/api/v1/trips":
            query = parse_qs(request.query, keep_blank_values=True)
            try:
                limit = int(query.get("limit", ["100"])[0])
            except ValueError:
                raise APIError(400, "invalid_trip_query", "骑行查询参数无效")
            if not 1 <= limit <= 500:
                raise APIError(400, "invalid_trip_query", "骑行查询参数超出范围")
            return {"trips": self.database.trips(self.vehicle_id, limit)}, 200
        trip_prefix = "/api/v1/trips/"
        if request.method == "GET" and request.path.startswith(trip_prefix):
            trip_id = request.path[len(trip_prefix):]
            try:
                trip = self.database.trip(trip_id)
            except KeyError:
                raise APIError(404, "trip_not_found", "骑行记录不存在")
            if trip["vehicle_id"] != self.vehicle_id:
                raise APIError(404, "trip_not_found", "骑行记录不存在")
            return {
                "trip": trip,
                "points": self.database.trip_locations(self.vehicle_id, trip_id),
            }, 200
        if request.method == "GET" and request.path == "/api/v1/alarms":
            query = parse_qs(request.query, keep_blank_values=True)
            active_only = query.get("state", [""])[0] == "active"
            return {
                "alarms": self.database.alarms(
                    self.vehicle_id, active_only=active_only
                )
            }, 200
        if request.method == "GET" and request.path == "/api/v1/settings":
            return {"settings": self.database.settings(self.vehicle_id)}, 200
        if (request.method == "PUT"
                and request.path == "/api/v1/settings/location-history"):
            self._verify_control_signature(request, client)
            body = self._json(request)
            days = body.get("days")
            if not isinstance(days, int) or days not in {7, 30}:
                raise APIError(422, "invalid_history_days", "轨迹保留期只支持 7 天或 30 天")
            try:
                settings = self.database.set_location_history_days(
                    self.vehicle_id, days,
                    confirm_shorten=body.get("confirm_shorten") is True,
                )
            except PermissionError:
                raise APIError(422, "history_shorten_confirmation_required",
                               "缩短轨迹保留期需要二次确认")
            return {"settings": settings}, 200
        if request.method == "POST" and request.path == "/api/v1/ble-observations":
            self._verify_control_signature(request, client)
            body = self._json(request)
            observation_id = body.get("observation_id")
            lock_state = body.get("lock_state")
            observed_at = body.get("observed_at")
            try:
                parsed_id = str(uuid.UUID(observation_id))
            except (ValueError, TypeError, AttributeError):
                raise APIError(400, "invalid_ble_observation", "BLE 状态记录编号无效")
            now = int(time.time())
            if lock_state not in {"locked", "unlocked"} or not isinstance(observed_at, int):
                raise APIError(400, "invalid_ble_observation", "BLE 锁状态记录不完整")
            if observed_at < now - 86400 or observed_at > now + 300:
                raise APIError(400, "invalid_ble_observation_time", "BLE 锁状态时间无效")
            observation, created = self.database.save_ble_lock_observation(
                parsed_id, self.vehicle_id, client["id"], lock_state, observed_at
            )
            return {"observation": observation, "created": created}, 201 if created else 200
        if request.method == "GET" and request.path == "/api/v1/commands":
            return {"commands": self.database.commands()}, 200
        prefix = "/api/v1/commands/"
        if request.method == "GET" and request.path.startswith(prefix):
            try:
                return {"command": self.database.command(request.path[len(prefix):])}, 200
            except KeyError:
                raise APIError(404, "command_not_found", "指令不存在")
        if request.method == "POST" and request.path == "/api/v1/commands":
            body = self._json(request)
            command_type = body.get("type")
            if command_type not in SUPPORTED_COMMANDS:
                raise APIError(422, "unsupported_command", "不支持该指令")
            if command_type in SIGNED_COMMANDS:
                self._verify_control_signature(request, client)
            parameters = body.get("parameters") if isinstance(body.get("parameters"), dict) else {}
            if command_type == "tracking.set_policy":
                policy = parameters.get("policy")
                if policy not in TRACKING_POLICIES:
                    raise APIError(422, "invalid_tracking_policy", "定位策略无效")
                parameters = {
                    "policy": policy,
                    "interval_seconds": TRACKING_POLICIES[policy],
                    "reason": "manual_policy",
                }
            active = self.database.active_command(self.vehicle_id)
            idem = request.headers.get("idempotency-key")
            if idem:
                existing = self.database.command_by_idempotency(client["id"], idem)
                if existing:
                    return {"command": existing, "created": False}, 200
            if active:
                raise APIError(409, "command_in_progress", "已有指令正在执行")
            if command_type == "vehicle.find_sound":
                latest = self.database.latest_command_time(self.vehicle_id, command_type)
                if latest is not None and int(time.time()) - latest < 10:
                    raise APIError(409, "sound_cooldown", "找车声音冷却中")
            command, created = self.database.create_command(
                self.vehicle_id, client["id"], command_type,
                parameters,
                idem,
            )
            if created:
                await self.dispatch_command(command["id"])
                command = self.database.command(command["id"])
            return {"command": command, "created": created}, 201 if created else 200
        raise APIError(404, "not_found", "接口不存在")

    def _complete_pairing(self, request: HTTPSpec) -> dict[str, Any]:
        now = time.monotonic()
        self._pairing_failures = [value for value in self._pairing_failures if now - value < 60]
        if len(self._pairing_failures) >= 10:
            raise APIError(429, "pairing_rate_limited", "配对尝试过于频繁，请稍后再试")
        body = self._json(request)
        code = body.get("pairing_code")
        name = body.get("device_name")
        token = body.get("read_token")
        public_key = decode_base64(body.get("control_public_key", ""), 65)
        if not all(isinstance(value, str) and value for value in (code, name, token)) or public_key is None:
            raise APIError(400, "invalid_pairing_payload", "配对信息不完整")
        if decode_base64(token, 32) is None:
            raise APIError(400, "invalid_read_token", "读取令牌格式错误")
        result = self.database.complete_pairing(code, name, token, public_key)
        if result is None:
            self._pairing_failures.append(now)
            raise APIError(401, "invalid_pairing_code", "配对码无效或已过期")
        self._pairing_failures.clear()
        return result

    def _authenticate_read(self, request: HTTPSpec):
        client_id = request.headers.get("x-client-id", "")
        auth = request.headers.get("authorization", "")
        if not auth.startswith("Bearer "):
            raise APIError(401, "authentication_required", "需要客户端认证")
        client = self.database.authenticate(client_id, auth[7:])
        if client is None:
            raise APIError(401, "invalid_credentials", "客户端认证失败")
        return client

    def _verify_control_signature(self, request: HTTPSpec, client) -> None:
        timestamp = request.headers.get("x-timestamp", "")
        nonce = request.headers.get("x-nonce", "")
        body_digest = request.headers.get("x-body-sha256", "")
        signature = decode_base64(request.headers.get("x-signature", ""), 64)
        try:
            timestamp_value = int(timestamp)
        except ValueError:
            raise APIError(401, "invalid_signature", "签名时间无效")
        now = int(time.time())
        if abs(now - timestamp_value) > 300 or body_digest != sha256_hex(request.body) or signature is None:
            raise APIError(401, "invalid_signature", "控制指令签名无效")
        message = canonical_request(
            request.method, request.path, request.query, timestamp, nonce, body_digest
        )
        if not verify_p256_raw(client["control_public_key"], message, signature):
            raise APIError(401, "invalid_signature", "控制指令签名无效")
        if not self.database.consume_nonce(client["id"], nonce, now):
            raise APIError(401, "replayed_request", "控制指令已使用或随机数无效")

    @staticmethod
    def _json(request: HTTPSpec) -> dict[str, Any]:
        try:
            value = json.loads(request.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise APIError(400, "invalid_json", "JSON 请求体无效")
        if not isinstance(value, dict):
            raise APIError(400, "invalid_json", "JSON 请求体必须是对象")
        return value


async def run_servers(service: RemoteService, tcp_host: str, tcp_port: int,
                      http_host: str, http_port: int,
                      stop_event: Optional[asyncio.Event] = None) -> None:
    loop = asyncio.get_running_loop()
    event = stop_event or asyncio.Event()
    installed_signals: list[signal.Signals] = []
    if stop_event is None:
        for signum in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(signum, event.set)
                installed_signals.append(signum)
            except (NotImplementedError, RuntimeError):
                pass

    tcp_server = await asyncio.start_server(service.handle_device, tcp_host, tcp_port)
    try:
        http_server = await asyncio.start_server(service.handle_http, http_host, http_port)
    except Exception:
        tcp_server.close()
        await tcp_server.wait_closed()
        raise
    LOGGER.info("IoT TCP listening on %s:%s", tcp_host, tcp_port)
    LOGGER.info("HTTP API listening on %s:%s", http_host, http_port)
    await service.start_background_tasks()
    tasks = [
        asyncio.create_task(tcp_server.serve_forever()),
        asyncio.create_task(http_server.serve_forever()),
    ]
    try:
        await event.wait()
    finally:
        tcp_server.close()
        http_server.close()
        for task in tasks:
            task.cancel()
        await service.shutdown()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        await asyncio.gather(
            tcp_server.wait_closed(), http_server.wait_closed(), return_exceptions=True
        )
        for signum in installed_signals:
            loop.remove_signal_handler(signum)
        LOGGER.info("IoT remote service stopped cleanly")


async def _close_writer(writer: asyncio.StreamWriter, timeout: float = 2.0) -> None:
    writer.close()
    wait_closed = getattr(writer, "wait_closed", None)
    if wait_closed is None:
        return
    try:
        await asyncio.wait_for(wait_closed(), timeout=timeout)
    except (asyncio.TimeoutError, ConnectionError):
        LOGGER.warning("stream close did not finish cleanly")

"""IoT TCP 网关、HTTP API 和单命令状态机。"""

import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass
from typing import Any, Optional
from urllib.parse import parse_qs, urlsplit

from .crypto import canonical_request, decode_base64, sha256_hex, verify_p256_raw
from .database import Database
from .protocol import Frame, build_downlink, parse_d0, parse_frame, split_frames


LOGGER = logging.getLogger("iot_remote")
TERMINAL = {"succeeded", "failed", "unknown", "noop", "rejected"}
SIGNED_COMMANDS = {"vehicle.unlock", "vehicle.lock"}
SUPPORTED_COMMANDS = {
    "vehicle.unlock", "vehicle.lock", "vehicle.find_sound",
    "telemetry.refresh", "location.once",
}


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


class RemoteService:
    def __init__(self, database: Database, target_imei: str, vehicle_name: str,
                 command_timeout: int = 30, online_window: int = 4200):
        self.database = database
        self.target_imei = target_imei
        self.vehicle_id = database.ensure_vehicle(target_imei, vehicle_name)
        self.command_timeout = command_timeout
        self.online_window = online_window
        self.session: Optional[DeviceSession] = None
        self._session_lock = asyncio.Lock()
        self._timeout_tasks: dict[str, asyncio.Task[None]] = {}
        self._pairing_failures: list[float] = []
        self.database.mark_inflight_unknown()

    def is_online(self) -> bool:
        return (
            self.session is not None
            and not self.session.writer.is_closing()
            and time.monotonic() - self.session.last_frame_at <= self.online_window
        )

    async def handle_device(self, reader: asyncio.StreamReader,
                            writer: asyncio.StreamWriter) -> None:
        buffer = b""
        authenticated = False
        LOGGER.info("device connection opened")
        try:
            while True:
                raw = await asyncio.wait_for(reader.read(1024), timeout=self.online_window)
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
                    self.database.update_vehicle_state(self.vehicle_id, online=0)
                    active = self.database.active_command(self.vehicle_id)
                    if active:
                        self._finish(active["id"], "unknown", "connection_lost")
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass
            if not authenticated:
                LOGGER.warning("connection closed before target identity")

    async def _accept_session(self, writer: asyncio.StreamWriter, frame: Frame) -> None:
        async with self._session_lock:
            if self.session and self.session.writer is not writer:
                self.session.writer.close()
            self.session = DeviceSession(writer, frame.vendor, time.monotonic())
            self.database.update_vehicle_state(
                self.vehicle_id, online=1, last_seen_at=int(time.time())
            )

    async def process_frame(self, frame: Frame) -> None:
        if self.session:
            self.session.last_frame_at = time.monotonic()
        fields = tuple(field.strip() for field in frame.fields)
        location_report = None
        stored_location = None
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
                stored_location = self.database.save_location(
                    self.vehicle_id,
                    source=location_report.source,
                    device_timestamp=location_report.device_timestamp,
                    valid=location_report.valid,
                    latitude=location_report.latitude,
                    longitude=location_report.longitude,
                    satellites=location_report.satellites,
                    hdop=location_report.hdop,
                    altitude_m=location_report.altitude_m,
                    mode=location_report.mode,
                    raw_fields=location_report.raw_fields,
                )

        active = self.database.active_command(self.vehicle_id)
        if active is None:
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

        if not verified:
            if frame.function in {"L0", "L1", "V0", "S6", "D0"}:
                self._finish(active["id"], "failed", "invalid_device_response")
            return
        if frame.function in {"L0", "L1"}:
            await self._send(frame.function, [])
        if command_type == "vehicle.unlock":
            self.database.update_vehicle_state(
                self.vehicle_id, lock_state="unlocked", security_state="disarmed",
                active_unlock_user=parameters["user_id"],
                active_unlock_timestamp=parameters["timestamp"],
                lock_state_source="remote_command", lock_state_updated_at=int(time.time()),
            )
        elif command_type == "vehicle.lock":
            self.database.update_vehicle_state(
                self.vehicle_id, lock_state="locked", security_state="disarmed",
                lock_state_source="remote_command", lock_state_updated_at=int(time.time()),
            )
        detail = {"function": frame.function}
        if command_type == "vehicle.lock":
            detail["physical_confirmation_required"] = True
        elif command_type == "location.once" and stored_location is not None:
            detail["location_id"] = stored_location["id"]
            detail["location_valid"] = stored_location["valid"]
        self._finish(active["id"], "succeeded", None, detail)

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

    async def _expire(self, command_id: str) -> None:
        try:
            await asyncio.sleep(self.command_timeout)
            command = self.database.command(command_id)
            if command["status"] not in TERMINAL:
                self._finish(command_id, "unknown", "device_timeout")
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
        return {
            "vehicle.unlock": {"enabled": online},
            "vehicle.lock": {
                "enabled": online,
                "requires_stationary_confirmation": True,
                "physical_confirmation_required": True,
            },
            "vehicle.find_sound": {"enabled": online, "cooldown_seconds": 10},
            "telemetry.refresh": {"enabled": online},
            "location.once": {"enabled": online},
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
        writer.close()
        try:
            await writer.wait_closed()
        except ConnectionError:
            pass

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
            return {"ok": True, "device_online": self.is_online()}, 200
        if request.method == "POST" and request.path == "/api/v1/pairings/complete":
            return self._complete_pairing(request), 201
        client = self._authenticate_read(request)
        if request.method == "GET" and request.path == "/api/v1/vehicle":
            vehicle = self.database.vehicle(self.vehicle_id)
            vehicle["online"] = self.is_online()
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
                body.get("parameters") if isinstance(body.get("parameters"), dict) else {},
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
                      http_host: str, http_port: int) -> None:
    tcp_server = await asyncio.start_server(service.handle_device, tcp_host, tcp_port)
    http_server = await asyncio.start_server(service.handle_http, http_host, http_port)
    LOGGER.info("IoT TCP listening on %s:%s", tcp_host, tcp_port)
    LOGGER.info("HTTP API listening on %s:%s", http_host, http_port)
    async with tcp_server, http_server:
        await asyncio.gather(tcp_server.serve_forever(), http_server.serve_forever())

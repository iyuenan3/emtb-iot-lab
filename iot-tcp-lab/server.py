#!/usr/bin/env python3
"""目标 IoT 设备的 TCP 报文采集与受控一次性配置服务。"""

import argparse
import asyncio
import hashlib
import hmac
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import re
import signal
import stat
import time
from typing import Any, Dict, List, Optional, Tuple


ALLOWED_HEADERS = {"*SCOR", "*CMDR"}
SENSITIVE_FUNCTIONS = {"K0"}
LOG_REDACTED_FUNCTIONS = {"D0", "K0", "L0", "L1", "R0"}
ONE_SHOT_TESTS: Dict[str, Tuple[str, List[str]]] = {
    "d0": ("D0", []),
    "s5-query": ("S5", ["0", "0", "0", "0"]),
    "s6": ("S6", []),
    "v0-find": ("V0", ["2"]),
    "l5-wheel-query": ("L5", ["34"]),
}
CONTROL_TESTS = {"l0-unlock": "0", "l1-lock": "1"}


class FrameError(ValueError):
    """报文格式不符合预期。"""


def parse_frame(raw: bytes) -> Dict[str, Any]:
    try:
        text = raw.decode("ascii").strip()
    except UnicodeDecodeError as exc:
        raise FrameError("non_ascii") from exc

    if not text.endswith("#"):
        raise FrameError("missing_terminator")

    parts = text[:-1].split(",")
    if len(parts) < 4:
        raise FrameError("too_few_fields")

    header, vendor, imei, function = parts[:4]
    if header not in ALLOWED_HEADERS:
        raise FrameError("unsupported_header")
    if not imei.isdigit() or not 14 <= len(imei) <= 17:
        raise FrameError("invalid_imei")
    if len(function) != 2 or not function.isalnum():
        raise FrameError("invalid_function")

    fields = parts[4:]
    sensitive_digest = None
    if function in SENSITIVE_FUNCTIONS:
        sensitive_digest = hashlib.sha256(",".join(fields).encode("ascii")).hexdigest()
        safe_fields = ["<REDACTED>"] if fields else []
    else:
        safe_fields = fields
    log_fields = ["<REDACTED>"] if function in LOG_REDACTED_FUNCTIONS and fields else fields
    safe_raw = ",".join([header, vendor, "<DEVICE>", function] + log_fields) + "#"

    return {
        "header": header,
        "vendor": vendor,
        "imei": imei,
        "function": function,
        "fields": safe_fields,
        "raw": safe_raw,
        "sensitive_digest": sensitive_digest,
    }


def build_downlink(vendor: str, imei: str, function: str, fields: List[str]) -> bytes:
    if not vendor or "," in vendor:
        raise ValueError("invalid_vendor")
    if not imei.isdigit() or not 14 <= len(imei) <= 17:
        raise ValueError("invalid_imei")
    if len(function) != 2 or not function.isalnum():
        raise ValueError("invalid_function")
    if any("," in field or "#" in field for field in fields):
        raise ValueError("invalid_field")
    payload = ",".join(["*SCOS", vendor, imei, function] + fields) + "#\r\n"
    return b"\xff\xff" + payload.encode("ascii")


def consume_rotation_key(path: Path) -> str:
    try:
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("rotate-key-file 必须是普通文件")
        if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o077:
            raise ValueError("rotate-key-file 的所有者或权限不安全")
        key = path.read_text(encoding="ascii").strip()
        if len(key.encode("ascii")) != 8 or any(char in key for char in ",#\r\n"):
            raise ValueError("轮换密钥必须为 8 个安全 ASCII 字节")
        return key
    finally:
        path.unlink(missing_ok=True)


class EventLogger:
    def __init__(self, log_dir: Path) -> None:
        log_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(log_dir, 0o700)
        log_path = log_dir / "events.jsonl"

        self._logger = logging.getLogger("iot_tcp_lab")
        self._logger.setLevel(logging.INFO)
        self._logger.propagate = False
        for existing_handler in self._logger.handlers:
            existing_handler.close()
        self._logger.handlers.clear()

        handler = RotatingFileHandler(
            log_path,
            maxBytes=5 * 1024 * 1024,
            backupCount=5,
            encoding="utf-8",
        )
        handler.setFormatter(logging.Formatter("%(message)s"))
        self._logger.addHandler(handler)
        os.chmod(log_path, 0o600)
        self._redaction_key = os.urandom(32)

    def fingerprint(self, value: str) -> str:
        return hmac.new(
            self._redaction_key,
            value.encode("utf-8", errors="ignore"),
            hashlib.sha256,
        ).hexdigest()[:12]

    def _sanitize(self, value: Any, key: str = "") -> Any:
        if key in {"imei", "target_imei", "peer_ip"}:
            return self.fingerprint(str(value))
        if key in {"peer_port", "addresses"}:
            return "<REDACTED>"
        if isinstance(value, dict):
            return {item_key: self._sanitize(item_value, item_key) for item_key, item_value in value.items()}
        if isinstance(value, list):
            return [self._sanitize(item) for item in value]
        if isinstance(value, tuple):
            return [self._sanitize(item) for item in value]
        if isinstance(value, str):
            value = re.sub(r"(?<!\d)\d{14,17}(?!\d)", "<DEVICE>", value)
            value = re.sub(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)", "<ADDRESS>", value)
        return value

    def write(self, event: str, **data: Any) -> None:
        record = {
            "ts": __import__("datetime").datetime.now(
                __import__("datetime").timezone.utc
            ).isoformat(),
            "event": event,
            **self._sanitize(data),
        }
        self._logger.info(json.dumps(record, ensure_ascii=False, separators=(",", ":")))


class CaptureServer:
    def __init__(
        self,
        host: str,
        port: int,
        target_imei: str,
        log_dir: Path,
        idle_timeout: int,
        max_connections: int,
        max_frame_bytes: int,
        reporting_interval_seconds: Optional[int] = None,
        disable_location_tracking: bool = False,
        disable_unlocked_telemetry: bool = False,
        rotation_key: Optional[str] = None,
        one_shot_test: Optional[str] = None,
    ) -> None:
        self.host = host
        self.port = port
        self.target_imei = target_imei
        self.idle_timeout = idle_timeout
        self.max_connections = max_connections
        self.max_frame_bytes = max_frame_bytes
        self.reporting_interval_seconds = reporting_interval_seconds
        self.disable_location_tracking = disable_location_tracking
        self.disable_unlocked_telemetry = disable_unlocked_telemetry
        self._s5_baseline: Optional[List[str]] = None
        self._rotation_key = rotation_key
        self.one_shot_test = one_shot_test
        self._rotation_key_digest = (
            hashlib.sha256(rotation_key.encode("ascii")).hexdigest()
            if rotation_key is not None
            else None
        )
        self.events = EventLogger(log_dir)
        self._active_connections = 0
        self._server: Optional[asyncio.AbstractServer] = None
        self._control_uid = "1"
        self._control_timestamp: Optional[str] = None
        self._control_function: Optional[str] = None
        if rotation_key is not None:
            self._plan_state = "pending_k0"
        elif one_shot_test is not None:
            self._plan_state = "pending_test"
        elif (
            reporting_interval_seconds is not None
            or disable_location_tracking
            or disable_unlocked_telemetry
        ):
            self._plan_state = "pending"
        else:
            self._plan_state = "disabled"

    @staticmethod
    def _peer(writer: asyncio.StreamWriter) -> Tuple[str, int]:
        peer = writer.get_extra_info("peername")
        if isinstance(peer, tuple) and len(peer) >= 2:
            return str(peer[0]), int(peer[1])
        return "unknown", 0

    async def _send_downlink(
        self,
        writer: asyncio.StreamWriter,
        peer_ip: str,
        vendor: str,
        function: str,
        fields: List[str],
    ) -> None:
        writer.write(build_downlink(vendor, self.target_imei, function, fields))
        await writer.drain()
        safe_fields = ["<REDACTED>"] if function in LOG_REDACTED_FUNCTIONS and fields else fields
        self.events.write(
            "downlink_sent",
            peer_ip=peer_ip,
            imei=self.target_imei,
            function=function,
            fields=safe_fields,
            plan_state=self._plan_state,
        )

    async def _send_s5(
        self, writer: asyncio.StreamWriter, peer_ip: str, vendor: str
    ) -> None:
        assert self._s5_baseline is not None
        interval = (
            str(self.reporting_interval_seconds)
            if self.reporting_interval_seconds is not None
            else "0"
        )
        telemetry_mode = "1" if self.disable_unlocked_telemetry else "2"
        telemetry_interval = "0" if self.disable_unlocked_telemetry else interval
        self._plan_state = "awaiting_s5"
        await self._send_downlink(
            writer,
            peer_ip,
            vendor,
            "S5",
            ["0", telemetry_mode, interval, telemetry_interval],
        )

    async def _continue_reporting_plan(
        self, writer: asyncio.StreamWriter, peer_ip: str, vendor: str
    ) -> None:
        if self.disable_location_tracking:
            self._plan_state = "awaiting_d1"
            await self._send_downlink(writer, peer_ip, vendor, "D1", ["0"])
        else:
            await self._send_s5(writer, peer_ip, vendor)

    async def process_command_plan(
        self,
        frame: Dict[str, Any],
        writer: asyncio.StreamWriter,
        peer_ip: str,
    ) -> None:
        function = frame["function"]
        fields = [str(field).strip() for field in frame["fields"]]
        vendor = frame["vendor"]

        if (
            self._plan_state == "pending_test"
            and function == "Q0"
            and self.one_shot_test in CONTROL_TESTS
        ):
            operation = CONTROL_TESTS[self.one_shot_test]
            self._control_timestamp = str(int(time.time()))
            self._control_function = "L0" if operation == "0" else "L1"
            self._plan_state = "awaiting_control_key"
            await self._send_downlink(
                writer,
                peer_ip,
                vendor,
                "R0",
                [operation, "30", self._control_uid, self._control_timestamp],
            )
            return

        if self._plan_state == "awaiting_control_key" and function == "R0":
            assert self.one_shot_test in CONTROL_TESTS
            assert self._control_timestamp is not None
            assert self._control_function is not None
            expected_operation = CONTROL_TESTS[self.one_shot_test]
            verified = (
                len(fields) >= 4
                and fields[0] == expected_operation
                and fields[1].isdigit()
                and 0 <= int(fields[1]) <= 255
                and fields[2] == self._control_uid
                and fields[3] == self._control_timestamp
            )
            self.events.write(
                "control_key_ack",
                peer_ip=peer_ip,
                imei=self.target_imei,
                operation=expected_operation,
                verified=verified,
            )
            if not verified:
                self._plan_state = "failed"
                return
            self._plan_state = "awaiting_control_result"
            control_fields = [fields[1]]
            if self._control_function == "L0":
                control_fields.extend([self._control_uid, self._control_timestamp])
            await self._send_downlink(
                writer,
                peer_ip,
                vendor,
                self._control_function,
                control_fields,
            )
            return

        if (
            self._plan_state == "awaiting_control_result"
            and function == self._control_function
        ):
            assert self.one_shot_test in CONTROL_TESTS
            assert self._control_timestamp is not None
            if function == "L0":
                verified = (
                    len(fields) >= 3
                    and fields[0] == "0"
                    and fields[1] == self._control_uid
                    and fields[2] == self._control_timestamp
                )
            else:
                verified = len(fields) >= 1 and fields[0] == "0"
            self.events.write(
                "downlink_ack",
                peer_ip=peer_ip,
                imei=self.target_imei,
                function=function,
                fields=fields,
                verified=verified,
                one_shot_test=self.one_shot_test,
            )
            if not verified:
                self._plan_state = "failed"
                return
            await self._send_downlink(writer, peer_ip, vendor, function, [])
            self._plan_state = "complete"
            self.events.write(
                "command_plan_complete",
                imei=self.target_imei,
                one_shot_test=self.one_shot_test,
            )
            return

        if self._plan_state == "pending_test" and function == "Q0":
            assert self.one_shot_test is not None
            test_function, test_fields = ONE_SHOT_TESTS[self.one_shot_test]
            self._plan_state = "awaiting_test"
            await self._send_downlink(
                writer,
                peer_ip,
                vendor,
                test_function,
                test_fields,
            )
            return

        if self._plan_state == "awaiting_test":
            assert self.one_shot_test is not None
            test_function, test_fields = ONE_SHOT_TESTS[self.one_shot_test]
            if function != test_function:
                return
            verified = self._verify_one_shot_reply(function, fields, test_fields)
            self._plan_state = "complete" if verified else "failed"
            self.events.write(
                "downlink_ack",
                peer_ip=peer_ip,
                imei=self.target_imei,
                function=function,
                fields=fields,
                verified=verified,
                one_shot_test=self.one_shot_test,
            )
            if verified:
                self.events.write(
                    "command_plan_complete",
                    imei=self.target_imei,
                    one_shot_test=self.one_shot_test,
                )
            return

        if self._plan_state == "pending_k0":
            assert self._rotation_key is not None
            self._plan_state = "awaiting_k0"
            await self._send_downlink(
                writer,
                peer_ip,
                vendor,
                "K0",
                ["1", self._rotation_key],
            )
            return

        if self._plan_state == "awaiting_k0" and function == "K0":
            verified = (
                self._rotation_key_digest is not None
                and frame["sensitive_digest"] is not None
                and hmac.compare_digest(
                    self._rotation_key_digest,
                    frame["sensitive_digest"],
                )
            )
            self._plan_state = "complete" if verified else "failed"
            self.events.write(
                "downlink_ack",
                peer_ip=peer_ip,
                imei=self.target_imei,
                function="K0",
                fields=["<REDACTED>"],
                verified=verified,
            )
            if verified:
                self._rotation_key = None
                self._rotation_key_digest = None
                self.events.write(
                    "command_plan_complete",
                    imei=self.target_imei,
                    key_rotation_verified=True,
                )
            return

        if self._plan_state == "pending" and function == "Q0":
            if (
                self.reporting_interval_seconds is not None
                or self.disable_unlocked_telemetry
            ):
                self._plan_state = "awaiting_s5_query"
                await self._send_downlink(
                    writer, peer_ip, vendor, "S5", ["0", "0", "0", "0"]
                )
            elif self.disable_location_tracking:
                await self._continue_reporting_plan(writer, peer_ip, vendor)
            return

        if self._plan_state == "awaiting_s5_query" and function == "S5":
            verified = len(fields) >= 4 and all(item.isdigit() for item in fields[:4])
            self.events.write(
                "downlink_ack",
                peer_ip=peer_ip,
                imei=self.target_imei,
                function="S5",
                fields=fields,
                verified=verified,
                query=True,
            )
            if not verified:
                self._plan_state = "failed"
                return
            self._s5_baseline = fields[:4]
            await self._continue_reporting_plan(writer, peer_ip, vendor)
            return

        if self._plan_state == "awaiting_d1" and function == "D1":
            verified = fields == ["0"]
            self.events.write(
                "downlink_ack",
                peer_ip=peer_ip,
                imei=self.target_imei,
                function="D1",
                fields=fields,
                verified=verified,
            )
            if not verified:
                self._plan_state = "failed"
                return
            if self._s5_baseline is not None:
                await self._send_s5(writer, peer_ip, vendor)
            else:
                self._plan_state = "complete"
                self.events.write(
                    "command_plan_complete",
                    imei=self.target_imei,
                    location_tracking_disabled=self.disable_location_tracking,
                )
            return

        if self._plan_state == "awaiting_s5" and function == "S5":
            assert self._s5_baseline is not None
            expected_heartbeat = (
                str(self.reporting_interval_seconds)
                if self.reporting_interval_seconds is not None
                else self._s5_baseline[2]
            )
            expected_telemetry_mode = (
                "1" if self.disable_unlocked_telemetry else "2"
            )
            expected_telemetry_interval = (
                self._s5_baseline[3]
                if self.disable_unlocked_telemetry
                else expected_heartbeat
            )
            verified = (
                len(fields) >= 4
                and fields[:4]
                == [
                    self._s5_baseline[0],
                    expected_telemetry_mode,
                    expected_heartbeat,
                    expected_telemetry_interval,
                ]
            )
            self.events.write(
                "downlink_ack",
                peer_ip=peer_ip,
                imei=self.target_imei,
                function="S5",
                fields=fields,
                verified=verified,
                query=False,
            )
            self._plan_state = "complete" if verified else "failed"
            if verified:
                self.events.write(
                    "command_plan_complete",
                    imei=self.target_imei,
                    reporting_interval_seconds=self.reporting_interval_seconds,
                    location_tracking_disabled=self.disable_location_tracking,
                    unlocked_telemetry_disabled=self.disable_unlocked_telemetry,
                )

    @staticmethod
    def _verify_one_shot_reply(
        function: str, fields: List[str], request_fields: List[str]
    ) -> bool:
        if function == "D0":
            return len(fields) >= 3 and fields[0] == "0" and fields[2] in {"A", "V"}
        if function == "S5":
            return len(fields) >= 4
        if function == "S6":
            return len(fields) >= 8
        if function == "V0":
            return fields == request_fields
        if function == "L5":
            return len(fields) >= 2 and fields[0] == "34" and fields[1] in {
                "0", "1", "2", "16", "17"
            }
        return False

    async def handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        peer_ip, peer_port = self._peer(writer)
        if self._active_connections >= self.max_connections:
            self.events.write("connection_rejected", peer_ip=peer_ip, reason="capacity")
            writer.close()
            await writer.wait_closed()
            return

        self._active_connections += 1
        authenticated = False
        self.events.write("connection_open", peer_ip=peer_ip, peer_port=peer_port)
        try:
            while True:
                try:
                    raw = await asyncio.wait_for(
                        reader.readline(), timeout=self.idle_timeout
                    )
                except asyncio.TimeoutError:
                    self.events.write("connection_close", peer_ip=peer_ip, reason="idle_timeout")
                    break
                except ValueError:
                    self.events.write("connection_close", peer_ip=peer_ip, reason="frame_too_large")
                    break

                if not raw:
                    self.events.write("connection_close", peer_ip=peer_ip, reason="eof")
                    break

                try:
                    frame = parse_frame(raw)
                except FrameError as exc:
                    self.events.write("invalid_frame", peer_ip=peer_ip, reason=str(exc))
                    if not authenticated:
                        break
                    continue

                if frame["imei"] != self.target_imei:
                    self.events.write(
                        "connection_rejected",
                        peer_ip=peer_ip,
                        reason="wrong_device",
                        imei=frame["imei"],
                    )
                    break

                authenticated = True
                self.events.write(
                    "frame",
                    peer_ip=peer_ip,
                    header=frame["header"],
                    vendor=frame["vendor"],
                    imei=frame["imei"],
                    function=frame["function"],
                    fields=(
                        ["<REDACTED>"]
                        if frame["function"] in LOG_REDACTED_FUNCTIONS and frame["fields"]
                        else frame["fields"]
                    ),
                    raw=frame["raw"],
                )
                await self.process_command_plan(frame, writer, peer_ip)
        except (ConnectionError, asyncio.CancelledError):
            self.events.write("connection_close", peer_ip=peer_ip, reason="connection_error")
        finally:
            self._active_connections -= 1
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass

    async def run(self) -> None:
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for signum in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(signum, stop.set)
            except NotImplementedError:
                pass

        self._server = await asyncio.start_server(
            self.handle_client,
            self.host,
            self.port,
            limit=self.max_frame_bytes,
        )
        sockets: List[Any] = list(self._server.sockets or [])
        addresses = [str(sock.getsockname()) for sock in sockets]
        self.events.write(
            "server_start",
            addresses=addresses,
            target_imei=self.target_imei,
            mode="controlled_downlink" if self._plan_state != "disabled" else "capture_only",
            reporting_interval_seconds=self.reporting_interval_seconds,
            disable_location_tracking=self.disable_location_tracking,
            key_rotation_requested=self._rotation_key is not None,
            one_shot_test=self.one_shot_test,
        )
        print("IoT TCP 调试服务已启动：" + ", ".join(addresses), flush=True)

        async with self._server:
            await stop.wait()

        self.events.write("server_stop")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="目标 IoT 设备 TCP 调试服务")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=19680)
    parser.add_argument("--target-imei", required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--idle-timeout", type=int, default=4200)
    parser.add_argument("--max-connections", type=int, default=4)
    parser.add_argument("--max-frame-bytes", type=int, default=4096)
    parser.add_argument("--reporting-interval-seconds", type=int)
    parser.add_argument("--disable-location-tracking", action="store_true")
    parser.add_argument("--disable-unlocked-telemetry", action="store_true")
    parser.add_argument("--rotate-key-file", type=Path)
    parser.add_argument(
        "--one-shot-test", choices=sorted(set(ONE_SHOT_TESTS) | set(CONTROL_TESTS))
    )
    return parser


def main() -> None:
    os.umask(0o077)
    args = build_parser().parse_args()
    if not args.target_imei.isdigit() or not 14 <= len(args.target_imei) <= 17:
        raise SystemExit("target-imei 格式不正确")
    if not 1 <= args.port <= 65535:
        raise SystemExit("port 必须在 1 到 65535 之间")
    if args.idle_timeout < 60:
        raise SystemExit("idle-timeout 不能小于 60 秒")
    if args.reporting_interval_seconds is not None and not 60 <= args.reporting_interval_seconds <= 86400:
        raise SystemExit("reporting-interval-seconds 必须在 60 到 86400 之间")

    rotation_key = consume_rotation_key(args.rotate_key_file) if args.rotate_key_file else None
    selected_plans = sum(
        [
            rotation_key is not None,
            args.one_shot_test is not None,
            args.reporting_interval_seconds is not None
            or args.disable_location_tracking
            or args.disable_unlocked_telemetry,
        ]
    )
    if selected_plans > 1:
        raise SystemExit("密钥轮换、一次性测试和报告配置计划不能同时启用")
    server = CaptureServer(
        host=args.host,
        port=args.port,
        target_imei=args.target_imei,
        log_dir=args.log_dir,
        idle_timeout=args.idle_timeout,
        max_connections=args.max_connections,
        max_frame_bytes=args.max_frame_bytes,
        reporting_interval_seconds=args.reporting_interval_seconds,
        disable_location_tracking=args.disable_location_tracking,
        disable_unlocked_telemetry=args.disable_unlocked_telemetry,
        rotation_key=rotation_key,
        one_shot_test=args.one_shot_test,
    )
    try:
        asyncio.run(server.run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

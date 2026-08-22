import asyncio
import hashlib
import json
import os
import tempfile
from unittest.mock import patch
import unittest
from pathlib import Path

from server import CaptureServer, EventLogger, FrameError, build_downlink, consume_rotation_key, parse_frame


class FrameParserTest(unittest.TestCase):
    def test_parses_q0_frame(self) -> None:
        frame = parse_frame(
            b"*SCOR,ZZ,000000000000001,Q0,412,90,20#\r\n"
        )
        self.assertEqual("000000000000001", frame["imei"])
        self.assertEqual("Q0", frame["function"])
        self.assertEqual(["412", "90", "20"], frame["fields"])
        self.assertNotIn("000000000000001", frame["raw"])
        self.assertIn("<DEVICE>", frame["raw"])

    def test_redacts_k0_payload(self) -> None:
        frame = parse_frame(
            b"*SCOR,ZZ,000000000000001,K0,1,EXAMPLE1#\n"
        )
        self.assertEqual(["<REDACTED>"], frame["fields"])
        self.assertNotIn("EXAMPLE1", frame["raw"])
        self.assertEqual(
            hashlib.sha256(b"1,EXAMPLE1").hexdigest(),
            frame["sensitive_digest"],
        )

    def test_rejects_missing_terminator(self) -> None:
        with self.assertRaisesRegex(FrameError, "missing_terminator"):
            parse_frame(b"*SCOR,ZZ,000000000000001,H0,1,412,20,90,0\n")

    def test_rejects_non_device_header(self) -> None:
        with self.assertRaisesRegex(FrameError, "unsupported_header"):
            parse_frame(b"*SCOS,ZZ,000000000000001,H0,1,412,20,90,0#\n")

    def test_builds_prefixed_downlink(self) -> None:
        data = build_downlink("ZZ", "000000000000001", "D1", ["0"])
        self.assertEqual(
            b"\xff\xff*SCOS,ZZ,000000000000001,D1,0#\r\n",
            data,
        )


class EventLoggerTest(unittest.TestCase):
    def test_creates_private_log(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "logs"
            logger = EventLogger(path)
            logger.write("test")
            self.assertEqual(0o700, path.stat().st_mode & 0o777)
            self.assertEqual(0o600, (path / "events.jsonl").stat().st_mode & 0o777)

    def test_redacts_network_and_device_identifiers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "logs"
            logger = EventLogger(path)
            logger.write(
                "frame",
                peer_ip="192.0.2.10",
                peer_port=19680,
                imei="000000000000001",
                raw="*SCOR,ZZ,000000000000001,Q0#",
            )
            log_text = (path / "events.jsonl").read_text(encoding="utf-8")
            self.assertNotIn("192.0.2.10", log_text)
            self.assertNotIn("000000000000001", log_text)
            self.assertNotIn('"peer_port":19680', log_text)
            self.assertRegex(log_text, r'"imei":"[0-9a-f]{12}"')

    def test_consumes_private_rotation_key_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rotation-key"
            path.write_text("EXAMPLE1", encoding="ascii")
            os.chmod(path, 0o600)
            self.assertEqual("EXAMPLE1", consume_rotation_key(path))
            self.assertFalse(path.exists())


class CaptureServerTest(unittest.IsolatedAsyncioTestCase):
    class FakeWriter:
        def __init__(self) -> None:
            self.writes = []

        def write(self, data: bytes) -> None:
            self.writes.append(data)

        async def drain(self) -> None:
            return None

    async def test_runs_reporting_plan_once_in_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            capture = CaptureServer(
                host="127.0.0.1",
                port=0,
                target_imei="000000000000001",
                log_dir=Path(directory) / "logs",
                idle_timeout=60,
                max_connections=2,
                max_frame_bytes=4096,
                reporting_interval_seconds=3600,
                disable_location_tracking=True,
                disable_unlocked_telemetry=True,
            )
            writer = self.FakeWriter()
            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,Q0,0,100,31#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("awaiting_s5_query", capture._plan_state)
            self.assertEqual(
                b"\xff\xff*SCOS,ZZ,000000000000001,S5,0,0,0,0#\r\n",
                writer.writes[0],
            )

            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,S5,3,2,240,10#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("awaiting_d1", capture._plan_state)
            self.assertEqual(
                b"\xff\xff*SCOS,ZZ,000000000000001,D1,0#\r\n",
                writer.writes[1],
            )

            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,D1,0#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("awaiting_s5", capture._plan_state)
            self.assertEqual(
                b"\xff\xff*SCOS,ZZ,000000000000001,S5,0,1,3600,0#\r\n",
                writer.writes[2],
            )

            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,S5,3,1,3600,10#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("complete", capture._plan_state)
            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,Q0,0,100,31#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual(3, len(writer.writes))

    async def test_reporting_plan_stops_on_mismatched_s5_without_retry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            capture = CaptureServer(
                host="127.0.0.1",
                port=0,
                target_imei="000000000000001",
                log_dir=Path(directory) / "logs",
                idle_timeout=60,
                max_connections=2,
                max_frame_bytes=4096,
                reporting_interval_seconds=3600,
                disable_location_tracking=True,
                disable_unlocked_telemetry=True,
            )
            writer = self.FakeWriter()
            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,Q0,0,100,31#\r\n"),
                writer,
                "127.0.0.1",
            )
            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,S5,3,2,240,10#\r\n"),
                writer,
                "127.0.0.1",
            )
            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,D1,0#\r\n"),
                writer,
                "127.0.0.1",
            )
            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,S5,3,2,3600,10#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("failed", capture._plan_state)
            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,Q0,0,100,31#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual(3, len(writer.writes))

    async def test_rotates_key_once_and_redacts_logs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log_dir = Path(directory) / "logs"
            capture = CaptureServer(
                host="127.0.0.1",
                port=0,
                target_imei="000000000000001",
                log_dir=log_dir,
                idle_timeout=60,
                max_connections=2,
                max_frame_bytes=4096,
                rotation_key="EXAMPLE1",
            )
            writer = self.FakeWriter()
            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,Q0,0,100,31#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("awaiting_k0", capture._plan_state)
            self.assertEqual(
                b"\xff\xff*SCOS,ZZ,000000000000001,K0,1,EXAMPLE1#\r\n",
                writer.writes[0],
            )

            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,K0,EXAMPLE1#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("complete", capture._plan_state)
            self.assertIsNone(capture._rotation_key)
            log_text = (log_dir / "events.jsonl").read_text(encoding="utf-8")
            self.assertNotIn("EXAMPLE1", log_text)
            self.assertIn('"key_rotation_verified":true', log_text)

    async def test_runs_find_sound_once_and_waits_for_matching_reply(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            capture = CaptureServer(
                host="127.0.0.1",
                port=0,
                target_imei="000000000000001",
                log_dir=Path(directory) / "logs",
                idle_timeout=60,
                max_connections=2,
                max_frame_bytes=4096,
                one_shot_test="v0-find",
            )
            writer = self.FakeWriter()
            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,Q0,0,100,31#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("awaiting_test", capture._plan_state)
            self.assertEqual(
                b"\xff\xff*SCOS,ZZ,000000000000001,V0,2#\r\n",
                writer.writes[0],
            )

            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,H0,1,412,31,100,0#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("awaiting_test", capture._plan_state)
            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,V0,2#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("complete", capture._plan_state)
            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,Q0,0,100,31#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual(1, len(writer.writes))

    async def test_unlock_requires_r0_and_confirms_success_once(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            capture = CaptureServer(
                host="127.0.0.1",
                port=0,
                target_imei="000000000000001",
                log_dir=Path(directory) / "logs",
                idle_timeout=60,
                max_connections=2,
                max_frame_bytes=4096,
                one_shot_test="l0-unlock",
            )
            writer = self.FakeWriter()
            with patch("server.time.time", return_value=1755700000):
                await capture.process_command_plan(
                    parse_frame(b"*SCOR,ZZ,000000000000001,Q0,0,100,31#\r\n"),
                    writer,
                    "127.0.0.1",
                )
            self.assertEqual("awaiting_control_key", capture._plan_state)
            self.assertEqual(
                b"\xff\xff*SCOS,ZZ,000000000000001,R0,0,30,1,1755700000#\r\n",
                writer.writes[0],
            )

            await capture.process_command_plan(
                parse_frame(
                    b"*SCOR,ZZ,000000000000001,R0,0,55,1,1755700000#\r\n"
                ),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("awaiting_control_result", capture._plan_state)
            self.assertEqual(
                b"\xff\xff*SCOS,ZZ,000000000000001,L0,55,1,1755700000#\r\n",
                writer.writes[1],
            )

            await capture.process_command_plan(
                parse_frame(
                    b"*SCOR,ZZ,000000000000001,L0,0,1,1755700000#\r\n"
                ),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("complete", capture._plan_state)
            self.assertEqual(
                b"\xff\xff*SCOS,ZZ,000000000000001,L0#\r\n",
                writer.writes[2],
            )

            await capture.process_command_plan(
                parse_frame(b"*SCOR,ZZ,000000000000001,Q0,0,100,31#\r\n"),
                writer,
                "127.0.0.1",
            )
            self.assertEqual(3, len(writer.writes))

    async def test_lock_rejects_mismatched_r0_before_control(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            capture = CaptureServer(
                host="127.0.0.1",
                port=0,
                target_imei="000000000000001",
                log_dir=Path(directory) / "logs",
                idle_timeout=60,
                max_connections=2,
                max_frame_bytes=4096,
                one_shot_test="l1-lock",
            )
            writer = self.FakeWriter()
            with patch("server.time.time", return_value=1755700000):
                await capture.process_command_plan(
                    parse_frame(b"*SCOR,ZZ,000000000000001,Q0,0,100,31#\r\n"),
                    writer,
                    "127.0.0.1",
                )
            await capture.process_command_plan(
                parse_frame(
                    b"*SCOR,ZZ,000000000000001,R0,1,55,2,1755700000#\r\n"
                ),
                writer,
                "127.0.0.1",
            )
            self.assertEqual("failed", capture._plan_state)
            self.assertEqual(1, len(writer.writes))

    def test_verifies_wheel_lock_query_states(self) -> None:
        self.assertTrue(
            CaptureServer._verify_one_shot_reply("L5", ["34", "16"], ["34"])
        )
        self.assertTrue(
            CaptureServer._verify_one_shot_reply("L5", ["34", "17"], ["34"])
        )
        self.assertFalse(
            CaptureServer._verify_one_shot_reply("L5", ["34", "99"], ["34"])
        )

    async def test_accepts_only_target_and_sends_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            capture = CaptureServer(
                host="127.0.0.1",
                port=0,
                target_imei="000000000000001",
                log_dir=Path(directory) / "logs",
                idle_timeout=60,
                max_connections=2,
                max_frame_bytes=4096,
            )
            listener = await asyncio.start_server(
                capture.handle_client, "127.0.0.1", 0, limit=4096
            )
            port = listener.sockets[0].getsockname()[1]
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            writer.write(b"*SCOR,ZZ,000000000000001,H0,1,412,20,90,0#\r\n")
            await writer.drain()

            with self.assertRaises(asyncio.TimeoutError):
                await asyncio.wait_for(reader.read(1), timeout=0.05)

            writer.close()
            await writer.wait_closed()
            listener.close()
            await listener.wait_closed()
            await asyncio.sleep(0.05)

            records = [
                json.loads(line)
                for line in (Path(directory) / "logs" / "events.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()
            ]
            frames = [record for record in records if record["event"] == "frame"]
            self.assertEqual(1, len(frames))
            self.assertEqual("H0", frames[0]["function"])

    async def test_closes_connection_for_another_device(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            capture = CaptureServer(
                host="127.0.0.1",
                port=0,
                target_imei="000000000000001",
                log_dir=Path(directory) / "logs",
                idle_timeout=60,
                max_connections=2,
                max_frame_bytes=4096,
            )
            listener = await asyncio.start_server(
                capture.handle_client, "127.0.0.1", 0, limit=4096
            )
            port = listener.sockets[0].getsockname()[1]
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            writer.write(b"*SCOR,ZZ,000000000000002,Q0,412,90,20#\r\n")
            await writer.drain()

            self.assertEqual(b"", await asyncio.wait_for(reader.read(1), timeout=1))
            writer.close()
            await writer.wait_closed()
            listener.close()
            await listener.wait_closed()


if __name__ == "__main__":
    unittest.main()

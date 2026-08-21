"""自行车 IoT 文本协议的最小安全实现。"""

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable, Optional


MAX_FRAME_BYTES = 4096


@dataclass(frozen=True)
class Frame:
    vendor: str
    imei: str
    function: str
    fields: tuple[str, ...]
    header: str = "*SCOR"


@dataclass(frozen=True)
class LocationReport:
    source: str
    device_timestamp: Optional[int]
    valid: bool
    latitude: Optional[float]
    longitude: Optional[float]
    satellites: Optional[int]
    hdop: Optional[float]
    altitude_m: Optional[float]
    mode: Optional[str]
    raw_fields: tuple[str, ...]


def parse_d0(fields: Iterable[str]) -> Optional[LocationReport]:
    """解析 D0，并把 NMEA 度分坐标转换为 WGS84 十进制度数。"""
    values = tuple(value.strip() for value in fields)
    if len(values) < 10 or values[0] not in {"0", "1"} or values[2] not in {"A", "V"}:
        return None
    device_timestamp = _d0_timestamp(values[9], values[1])
    satellites = _optional_int(values[7])
    hdop = _optional_float(values[8])
    altitude = _optional_float(values[10]) if len(values) > 10 else None
    mode = values[12] or None if len(values) > 12 else None
    if values[2] == "V":
        return LocationReport(
            "once" if values[0] == "0" else "tracking", device_timestamp, False,
            None, None, satellites, hdop, altitude, mode, values,
        )
    if len(values) < 13 or values[4] not in {"N", "S"} or values[6] not in {"E", "W"}:
        return None
    latitude = _nmea_coordinate(values[3], 2, values[4], 90)
    longitude = _nmea_coordinate(values[5], 3, values[6], 180)
    if latitude is None or longitude is None:
        return None
    return LocationReport(
        "once" if values[0] == "0" else "tracking", device_timestamp, True,
        latitude, longitude, satellites, hdop, altitude, mode, values,
    )


def _d0_timestamp(date_value: str, time_value: str) -> Optional[int]:
    if len(date_value) != 6 or len(time_value) < 6:
        return None
    try:
        parsed = datetime.strptime(date_value + time_value[:6], "%d%m%y%H%M%S")
    except ValueError:
        return None
    return int(parsed.replace(tzinfo=timezone.utc).timestamp())


def _nmea_coordinate(value: str, degree_digits: int, hemisphere: str,
                     maximum: float) -> Optional[float]:
    if len(value) <= degree_digits:
        return None
    try:
        degrees = int(value[:degree_digits])
        minutes = float(value[degree_digits:])
    except ValueError:
        return None
    if not 0 <= minutes < 60:
        return None
    coordinate = degrees + minutes / 60
    if coordinate > maximum:
        return None
    if hemisphere in {"S", "W"}:
        coordinate = -coordinate
    return coordinate


def _optional_int(value: str) -> Optional[int]:
    try:
        return int(value) if value else None
    except ValueError:
        return None


def _optional_float(value: str) -> Optional[float]:
    try:
        return float(value) if value else None
    except ValueError:
        return None


def parse_frame(raw: bytes) -> Optional[Frame]:
    if not raw or len(raw) > MAX_FRAME_BYTES:
        return None
    try:
        text = raw.lstrip(b"\xff").decode("ascii").strip()
    except UnicodeDecodeError:
        return None
    if text.startswith("[") and text.endswith("]"):
        parts = text[1:-1].split("*")
        if len(parts) < 3:
            return None
        vendor, imei, function, *fields = parts
        header = "[legacy]"
    else:
        if not text.endswith("#"):
            return None
        parts = text[:-1].split(",")
        if len(parts) < 4:
            return None
        header, vendor, imei, function, *fields = parts
        if header not in {"*SCOR", "*CMDR"}:
            return None
        if not imei.isdigit() or not 14 <= len(imei) <= 17:
            return None
    if not vendor or not imei or len(function) != 2 or not function.isalnum():
        return None
    if any(not 0x20 <= ord(ch) <= 0x7E for ch in text):
        return None
    return Frame(vendor, imei, function.upper(), tuple(fields), header)


def build_downlink(vendor: str, imei: str, function: str,
                   fields: Iterable[object] = ()) -> bytes:
    values = [vendor, imei, function.upper(), *(str(value) for value in fields)]
    if not vendor or "," in vendor:
        raise ValueError("厂商字段无效")
    if not imei.isdigit() or not 14 <= len(imei) <= 17:
        raise ValueError("IMEI 无效")
    if len(values[2]) != 2 or not values[2].isalnum():
        raise ValueError("功能码无效")
    if any("," in value or "#" in value or "\r" in value or "\n" in value for value in values):
        raise ValueError("协议字段包含非法分隔符")
    payload = ",".join(["*SCOS", *values]) + "#\r\n"
    encoded = b"\xff\xff" + payload.encode("ascii")
    if len(encoded) > MAX_FRAME_BYTES:
        raise ValueError("协议帧过长")
    return encoded


def split_frames(buffer: bytes) -> tuple[list[bytes], bytes]:
    """从 TCP 字节流中提取真实 SCOR/CMDR 帧和旧方括号帧。"""
    frames: list[bytes] = []
    while True:
        starts = [position for position in (
            buffer.find(b"*SCOR"), buffer.find(b"*CMDR"), buffer.find(b"[")
        ) if position >= 0]
        if not starts:
            if not buffer.strip(b"\r\n\t "):
                return frames, b""
            return frames, b"" if len(buffer) > MAX_FRAME_BYTES else buffer
        start = min(starts)
        if start:
            buffer = buffer[start:]
        terminator = b"]" if buffer.startswith(b"[") else b"#"
        end = buffer.find(terminator, 1)
        if end < 0:
            return frames, b"" if len(buffer) > MAX_FRAME_BYTES else buffer
        frames.append(buffer[:end + 1])
        buffer = buffer[end + 1:]

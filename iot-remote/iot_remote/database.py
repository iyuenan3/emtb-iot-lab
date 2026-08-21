"""SQLite 持久化层。"""

import json
import hashlib
import math
import os
import secrets
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any, Optional

from .crypto import constant_time_token_matches, token_digest


SCHEMA = """
CREATE TABLE IF NOT EXISTS vehicles (
  id TEXT PRIMARY KEY, imei TEXT NOT NULL UNIQUE, display_name TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS vehicle_state (
  vehicle_id TEXT PRIMARY KEY REFERENCES vehicles(id), online INTEGER NOT NULL DEFAULT 0,
  last_seen_at INTEGER, lock_state TEXT NOT NULL DEFAULT 'unknown', power_mv INTEGER,
  battery_percent INTEGER, security_state TEXT NOT NULL DEFAULT 'unknown',
  active_unlock_user TEXT, active_unlock_timestamp TEXT, telemetry_fields_json TEXT,
  telemetry_updated_at INTEGER, lock_state_source TEXT NOT NULL DEFAULT 'unknown',
  lock_state_updated_at INTEGER, desired_tracking_interval INTEGER,
  confirmed_tracking_interval INTEGER, tracking_confirmed_at INTEGER,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS pairing_codes (
  digest TEXT PRIMARY KEY, expires_at INTEGER NOT NULL, used_at INTEGER
);
CREATE TABLE IF NOT EXISTS clients (
  id TEXT PRIMARY KEY, device_name TEXT NOT NULL, read_token_digest TEXT NOT NULL,
  control_public_key BLOB NOT NULL, permissions_json TEXT NOT NULL, created_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE TABLE IF NOT EXISTS nonces (
  client_id TEXT NOT NULL REFERENCES clients(id), nonce TEXT NOT NULL,
  created_at INTEGER NOT NULL, PRIMARY KEY(client_id, nonce)
);
CREATE TABLE IF NOT EXISTS commands (
  id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id), client_id TEXT,
  command_type TEXT NOT NULL, status TEXT NOT NULL, parameters_json TEXT NOT NULL,
  idempotency_key TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  sent_at INTEGER, completed_at INTEGER, result_json TEXT, error_code TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS commands_idempotency
  ON commands(client_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE TABLE IF NOT EXISTS command_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, command_id TEXT NOT NULL REFERENCES commands(id),
  status TEXT NOT NULL, detail_json TEXT NOT NULL, created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS locations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  vehicle_id TEXT NOT NULL REFERENCES vehicles(id), source TEXT NOT NULL,
  device_timestamp INTEGER, received_at INTEGER NOT NULL, valid INTEGER NOT NULL,
  latitude REAL, longitude REAL, satellites INTEGER, hdop REAL, altitude_m REAL,
  mode TEXT, display_eligible INTEGER NOT NULL DEFAULT 0, rejection_reason TEXT,
  distance_from_previous_m REAL, speed_mps REAL,
  raw_fields_json TEXT NOT NULL, fingerprint TEXT NOT NULL,
  UNIQUE(vehicle_id, fingerprint)
);
CREATE INDEX IF NOT EXISTS locations_vehicle_time
  ON locations(vehicle_id, received_at DESC);
CREATE TABLE IF NOT EXISTS ble_observations (
  id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id),
  client_id TEXT NOT NULL REFERENCES clients(id), lock_state TEXT NOT NULL,
  observed_at INTEGER NOT NULL, received_at INTEGER NOT NULL, applied INTEGER NOT NULL
);
"""


class Database:
    def __init__(self, path: str):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.path.parent, 0o700)
        self.connection = sqlite3.connect(str(self.path))
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA foreign_keys=ON")
        self.connection.execute("PRAGMA busy_timeout=5000")
        self.connection.executescript(SCHEMA)
        self._migrate_vehicle_state()
        self._migrate_locations()
        self.connection.commit()
        os.chmod(self.path, 0o600)

    def _migrate_vehicle_state(self) -> None:
        columns = {
            row[1] for row in self.connection.execute("PRAGMA table_info(vehicle_state)")
        }
        if "telemetry_fields_json" not in columns:
            self.connection.execute("ALTER TABLE vehicle_state ADD COLUMN telemetry_fields_json TEXT")
        if "telemetry_updated_at" not in columns:
            self.connection.execute("ALTER TABLE vehicle_state ADD COLUMN telemetry_updated_at INTEGER")
        if "lock_state_source" not in columns:
            self.connection.execute(
                "ALTER TABLE vehicle_state ADD COLUMN lock_state_source TEXT NOT NULL DEFAULT 'unknown'"
            )
        if "lock_state_updated_at" not in columns:
            self.connection.execute("ALTER TABLE vehicle_state ADD COLUMN lock_state_updated_at INTEGER")
        if "desired_tracking_interval" not in columns:
            self.connection.execute(
                "ALTER TABLE vehicle_state ADD COLUMN desired_tracking_interval INTEGER"
            )
        if "confirmed_tracking_interval" not in columns:
            self.connection.execute(
                "ALTER TABLE vehicle_state ADD COLUMN confirmed_tracking_interval INTEGER"
            )
        if "tracking_confirmed_at" not in columns:
            self.connection.execute(
                "ALTER TABLE vehicle_state ADD COLUMN tracking_confirmed_at INTEGER"
            )

    def _migrate_locations(self) -> None:
        columns = {
            row[1] for row in self.connection.execute("PRAGMA table_info(locations)")
        }
        if "display_eligible" not in columns:
            self.connection.execute(
                "ALTER TABLE locations ADD COLUMN display_eligible INTEGER NOT NULL DEFAULT 0"
            )
            self.connection.execute(
                "UPDATE locations SET display_eligible=valid WHERE valid=1"
            )
        if "rejection_reason" not in columns:
            self.connection.execute("ALTER TABLE locations ADD COLUMN rejection_reason TEXT")
        if "distance_from_previous_m" not in columns:
            self.connection.execute(
                "ALTER TABLE locations ADD COLUMN distance_from_previous_m REAL"
            )
        if "speed_mps" not in columns:
            self.connection.execute("ALTER TABLE locations ADD COLUMN speed_mps REAL")

    def close(self) -> None:
        self.connection.close()

    def ensure_vehicle(self, imei: str, display_name: str) -> str:
        now = int(time.time())
        vehicle_id = "vehicle-1"
        self.connection.execute(
            "INSERT OR IGNORE INTO vehicles(id, imei, display_name, created_at) VALUES(?,?,?,?)",
            (vehicle_id, imei, display_name, now),
        )
        self.connection.execute(
            "INSERT OR IGNORE INTO vehicle_state(vehicle_id, updated_at) VALUES(?,?)",
            (vehicle_id, now),
        )
        self.connection.commit()
        return vehicle_id

    def create_pairing_code(self, ttl_seconds: int = 600) -> str:
        code = "-".join(f"{secrets.randbelow(10000):04d}" for _ in range(2))
        now = int(time.time())
        self.connection.execute(
            "INSERT INTO pairing_codes(digest, expires_at) VALUES(?,?)",
            (token_digest(code), now + ttl_seconds),
        )
        self.connection.commit()
        return code

    def complete_pairing(self, code: str, device_name: str, read_token: str,
                         public_key: bytes) -> Optional[dict[str, Any]]:
        now = int(time.time())
        digest = token_digest(code)
        with self.connection:
            row = self.connection.execute(
                "SELECT * FROM pairing_codes WHERE digest=? AND used_at IS NULL AND expires_at>=?",
                (digest, now),
            ).fetchone()
            if row is None:
                return None
            client_id = str(uuid.uuid4())
            permissions = ["read", "find_sound", "unlock", "lock"]
            self.connection.execute(
                "INSERT INTO clients VALUES(?,?,?,?,?,?,NULL)",
                (client_id, device_name[:80], token_digest(read_token), public_key,
                 json.dumps(permissions), now),
            )
            self.connection.execute(
                "UPDATE pairing_codes SET used_at=? WHERE digest=?", (now, digest)
            )
        return {"client_id": client_id, "permissions": permissions}

    def authenticate(self, client_id: str, read_token: str) -> Optional[sqlite3.Row]:
        row = self.connection.execute(
            "SELECT * FROM clients WHERE id=? AND revoked_at IS NULL", (client_id,)
        ).fetchone()
        if row is None or not constant_time_token_matches(read_token, row["read_token_digest"]):
            return None
        return row

    def consume_nonce(self, client_id: str, nonce: str, now: int,
                      max_age: int = 300) -> bool:
        if not 16 <= len(nonce) <= 128:
            return False
        with self.connection:
            self.connection.execute("DELETE FROM nonces WHERE created_at<?", (now - max_age,))
            try:
                self.connection.execute(
                    "INSERT INTO nonces(client_id, nonce, created_at) VALUES(?,?,?)",
                    (client_id, nonce, now),
                )
            except sqlite3.IntegrityError:
                return False
        return True

    def update_vehicle_state(self, vehicle_id: str, **values: Any) -> None:
        allowed = {
            "online", "last_seen_at", "lock_state", "power_mv", "battery_percent",
            "security_state", "active_unlock_user", "active_unlock_timestamp",
            "telemetry_fields_json", "telemetry_updated_at", "lock_state_source",
            "lock_state_updated_at", "desired_tracking_interval",
            "confirmed_tracking_interval", "tracking_confirmed_at",
        }
        filtered = {key: value for key, value in values.items() if key in allowed}
        if not filtered:
            return
        filtered["updated_at"] = int(time.time())
        assignments = ",".join(f"{key}=?" for key in filtered)
        self.connection.execute(
            f"UPDATE vehicle_state SET {assignments} WHERE vehicle_id=?",
            (*filtered.values(), vehicle_id),
        )
        self.connection.commit()

    def vehicle(self, vehicle_id: str) -> dict[str, Any]:
        row = self.connection.execute(
            "SELECT v.id, v.imei, v.display_name, s.* FROM vehicles v "
            "JOIN vehicle_state s ON s.vehicle_id=v.id WHERE v.id=?", (vehicle_id,)
        ).fetchone()
        if row is None:
            raise KeyError(vehicle_id)
        result = dict(row)
        result["online"] = bool(result["online"])
        raw_telemetry = result.pop("telemetry_fields_json", None)
        result["telemetry_fields"] = json.loads(raw_telemetry) if raw_telemetry else None
        return result

    def save_ble_lock_observation(self, observation_id: str, vehicle_id: str,
                                  client_id: str, lock_state: str,
                                  observed_at: int) -> tuple[dict[str, Any], bool]:
        existing = self.connection.execute(
            "SELECT * FROM ble_observations WHERE id=?", (observation_id,)
        ).fetchone()
        if existing:
            result = dict(existing)
            result["applied"] = bool(result["applied"])
            return result, False
        received_at = int(time.time())
        current = self.connection.execute(
            "SELECT lock_state_updated_at FROM vehicle_state WHERE vehicle_id=?", (vehicle_id,)
        ).fetchone()
        applied = current is not None and (
            current["lock_state_updated_at"] is None or observed_at >= current["lock_state_updated_at"]
        )
        with self.connection:
            self.connection.execute(
                "INSERT INTO ble_observations(id,vehicle_id,client_id,lock_state,observed_at,"
                "received_at,applied) VALUES(?,?,?,?,?,?,?)",
                (observation_id, vehicle_id, client_id, lock_state, observed_at,
                 received_at, int(applied)),
            )
            if applied:
                self.connection.execute(
                    "UPDATE vehicle_state SET lock_state=?,lock_state_source='ble',"
                    "lock_state_updated_at=?,updated_at=? WHERE vehicle_id=?",
                    (lock_state, observed_at, received_at, vehicle_id),
                )
        row = self.connection.execute(
            "SELECT * FROM ble_observations WHERE id=?", (observation_id,)
        ).fetchone()
        result = dict(row)
        result["applied"] = bool(result["applied"])
        return result, True

    def save_location(self, vehicle_id: str, *, source: str,
                      device_timestamp: Optional[int], valid: bool,
                      latitude: Optional[float], longitude: Optional[float],
                      satellites: Optional[int], hdop: Optional[float],
                      altitude_m: Optional[float], mode: Optional[str],
                      raw_fields: tuple[str, ...], min_satellites: int = 4,
                      max_hdop: float = 8.0,
                      max_speed_mps: float = 25.0) -> dict[str, Any]:
        received_at = int(time.time())
        raw_json = json.dumps(list(raw_fields), separators=(",", ":"))
        fingerprint = hashlib.sha256(
            f"{source}\0{device_timestamp}\0{raw_json}".encode("utf-8")
        ).hexdigest()
        existing = self.connection.execute(
            "SELECT * FROM locations WHERE vehicle_id=? AND fingerprint=?",
            (vehicle_id, fingerprint),
        ).fetchone()
        if existing:
            return self._location_dict(existing)
        eligible, reason, distance, speed = self._location_quality(
            vehicle_id=vehicle_id,
            device_timestamp=device_timestamp,
            received_at=received_at,
            valid=valid,
            latitude=latitude,
            longitude=longitude,
            satellites=satellites,
            hdop=hdop,
            min_satellites=min_satellites,
            max_hdop=max_hdop,
            max_speed_mps=max_speed_mps,
        )
        with self.connection:
            self.connection.execute(
                "INSERT OR IGNORE INTO locations(vehicle_id,source,device_timestamp,received_at,"
                "valid,latitude,longitude,satellites,hdop,altitude_m,mode,display_eligible,"
                "rejection_reason,distance_from_previous_m,speed_mps,raw_fields_json,fingerprint) "
                "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (vehicle_id, source, device_timestamp, received_at, int(valid), latitude,
                 longitude, satellites, hdop, altitude_m, mode, int(eligible), reason,
                 distance, speed, raw_json, fingerprint),
            )
        row = self.connection.execute(
            "SELECT * FROM locations WHERE vehicle_id=? AND fingerprint=?",
            (vehicle_id, fingerprint),
        ).fetchone()
        return self._location_dict(row)

    def _location_quality(self, *, vehicle_id: str,
                          device_timestamp: Optional[int], received_at: int,
                          valid: bool, latitude: Optional[float],
                          longitude: Optional[float], satellites: Optional[int],
                          hdop: Optional[float], min_satellites: int,
                          max_hdop: float,
                          max_speed_mps: float) -> tuple[bool, Optional[str], Optional[float], Optional[float]]:
        if not valid:
            return False, "device_invalid", None, None
        if latitude is None or longitude is None:
            return False, "coordinate_missing", None, None
        if device_timestamp is None:
            return False, "timestamp_missing", None, None
        if device_timestamp > received_at + 300:
            return False, "timestamp_future", None, None
        if satellites is None or satellites < min_satellites:
            return False, "insufficient_satellites", None, None
        if hdop is None or hdop > max_hdop:
            return False, "poor_hdop", None, None

        previous = self.connection.execute(
            "SELECT device_timestamp,latitude,longitude FROM locations "
            "WHERE vehicle_id=? AND display_eligible=1 AND device_timestamp IS NOT NULL "
            "AND latitude IS NOT NULL AND longitude IS NOT NULL "
            "ORDER BY device_timestamp DESC,id DESC LIMIT 1",
            (vehicle_id,),
        ).fetchone()
        if previous is None:
            return True, None, None, None
        elapsed = device_timestamp - previous["device_timestamp"]
        if elapsed <= 0:
            return False, "out_of_order", None, None
        distance = self._distance_m(
            previous["latitude"], previous["longitude"], latitude, longitude
        )
        speed = distance / elapsed
        if speed > max_speed_mps:
            return False, "excessive_speed", distance, speed
        return True, None, distance, speed

    @staticmethod
    def _distance_m(latitude_a: float, longitude_a: float,
                    latitude_b: float, longitude_b: float) -> float:
        radius_m = 6371008.8
        lat_a = math.radians(latitude_a)
        lat_b = math.radians(latitude_b)
        delta_lat = lat_b - lat_a
        delta_lon = math.radians(longitude_b - longitude_a)
        value = (
            math.sin(delta_lat / 2) ** 2
            + math.cos(lat_a) * math.cos(lat_b) * math.sin(delta_lon / 2) ** 2
        )
        return 2 * radius_m * math.asin(min(1.0, math.sqrt(value)))

    def latest_location(self, vehicle_id: str, valid_only: bool = True) -> Optional[dict[str, Any]]:
        condition = " AND valid=1 AND display_eligible=1" if valid_only else ""
        row = self.connection.execute(
            "SELECT * FROM locations WHERE vehicle_id=?" + condition +
            " ORDER BY COALESCE(device_timestamp,received_at) DESC,id DESC LIMIT 1",
            (vehicle_id,),
        ).fetchone()
        return self._location_dict(row) if row else None

    def locations(self, vehicle_id: str, limit: int = 500,
                  since: Optional[int] = None, valid_only: bool = True) -> list[dict[str, Any]]:
        clauses = ["vehicle_id=?"]
        parameters: list[Any] = [vehicle_id]
        if valid_only:
            clauses.append("valid=1")
            clauses.append("display_eligible=1")
        if since is not None:
            clauses.append("COALESCE(device_timestamp,received_at)>=?")
            parameters.append(since)
        bounded_limit = max(1, min(limit, 2000))
        parameters.append(bounded_limit)
        rows = self.connection.execute(
            "SELECT * FROM (SELECT * FROM locations WHERE " + " AND ".join(clauses) +
            " ORDER BY COALESCE(device_timestamp,received_at) DESC,id DESC LIMIT ?) "
            "ORDER BY COALESCE(device_timestamp,received_at),id",
            parameters,
        ).fetchall()
        return [self._location_dict(row) for row in rows]

    def active_command(self, vehicle_id: str) -> Optional[dict[str, Any]]:
        row = self.connection.execute(
            "SELECT * FROM commands WHERE vehicle_id=? AND status IN "
            "('accepted','prechecking','awaiting_r0','awaiting_result') "
            "ORDER BY created_at LIMIT 1", (vehicle_id,)
        ).fetchone()
        return self._command_dict(row) if row else None

    def command_by_idempotency(self, client_id: str, idempotency_key: str) -> Optional[dict[str, Any]]:
        row = self.connection.execute(
            "SELECT * FROM commands WHERE client_id=? AND idempotency_key=?",
            (client_id, idempotency_key),
        ).fetchone()
        return self._command_dict(row) if row else None

    def latest_command_time(self, vehicle_id: str, command_type: str) -> Optional[int]:
        row = self.connection.execute(
            "SELECT created_at FROM commands WHERE vehicle_id=? AND command_type=? "
            "ORDER BY created_at DESC LIMIT 1", (vehicle_id, command_type)
        ).fetchone()
        return int(row["created_at"]) if row else None

    def create_command(self, vehicle_id: str, client_id: Optional[str], command_type: str,
                       parameters: dict[str, Any], idempotency_key: Optional[str]) -> tuple[dict[str, Any], bool]:
        if idempotency_key:
            existing = self.connection.execute(
                "SELECT * FROM commands WHERE client_id=? AND idempotency_key=?",
                (client_id, idempotency_key),
            ).fetchone()
            if existing:
                return self._command_dict(existing), False
        now = int(time.time())
        command_id = str(uuid.uuid4())
        with self.connection:
            self.connection.execute(
                "INSERT INTO commands VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (command_id, vehicle_id, client_id, command_type, "accepted",
                 json.dumps(parameters, separators=(",", ":")), idempotency_key,
                 now, now, None, None, None, None),
            )
            self.connection.execute(
                "INSERT INTO command_events(command_id,status,detail_json,created_at) VALUES(?,?,?,?)",
                (command_id, "accepted", "{}", now),
            )
        return self.command(command_id), True

    def transition_command(self, command_id: str, status: str,
                           detail: Optional[dict[str, Any]] = None,
                           error_code: Optional[str] = None) -> dict[str, Any]:
        now = int(time.time())
        terminal = status in {"succeeded", "failed", "unknown", "noop", "rejected"}
        sent_at = now if status in {"awaiting_r0", "awaiting_result"} else None
        result = json.dumps(detail or {}, separators=(",", ":")) if terminal else None
        with self.connection:
            self.connection.execute(
                "UPDATE commands SET status=?, updated_at=?, "
                "sent_at=COALESCE(sent_at,?), completed_at=?, result_json=COALESCE(?,result_json), "
                "error_code=? WHERE id=?",
                (status, now, sent_at, now if terminal else None, result, error_code, command_id),
            )
            self.connection.execute(
                "INSERT INTO command_events(command_id,status,detail_json,created_at) VALUES(?,?,?,?)",
                (command_id, status, json.dumps(detail or {}, separators=(",", ":")), now),
            )
        return self.command(command_id)

    def mark_inflight_unknown(self) -> int:
        rows = self.connection.execute(
            "SELECT id FROM commands WHERE status IN ('accepted','prechecking','awaiting_r0','awaiting_result')"
        ).fetchall()
        for row in rows:
            self.transition_command(row["id"], "unknown", {"reason": "service_restarted"}, "service_restarted")
        return len(rows)

    def command(self, command_id: str) -> dict[str, Any]:
        row = self.connection.execute("SELECT * FROM commands WHERE id=?", (command_id,)).fetchone()
        if row is None:
            raise KeyError(command_id)
        result = self._command_dict(row)
        result["events"] = [
            {**dict(event), "detail": json.loads(event["detail_json"])}
            for event in self.connection.execute(
                "SELECT status,detail_json,created_at FROM command_events WHERE command_id=? ORDER BY id",
                (command_id,),
            ).fetchall()
        ]
        for event in result["events"]:
            event.pop("detail_json", None)
        return result

    def commands(self, limit: int = 50) -> list[dict[str, Any]]:
        rows = self.connection.execute(
            "SELECT * FROM commands ORDER BY created_at DESC LIMIT ?", (max(1, min(limit, 100)),)
        ).fetchall()
        return [self._command_dict(row) for row in rows]

    @staticmethod
    def _command_dict(row: sqlite3.Row) -> dict[str, Any]:
        result = dict(row)
        result["parameters"] = json.loads(result.pop("parameters_json"))
        raw_result = result.pop("result_json")
        result["result"] = json.loads(raw_result) if raw_result else None
        return result

    @staticmethod
    def _location_dict(row: sqlite3.Row) -> dict[str, Any]:
        result = dict(row)
        result["valid"] = bool(result["valid"])
        result["display_eligible"] = bool(result["display_eligible"])
        result["raw_fields"] = json.loads(result.pop("raw_fields_json"))
        result.pop("fingerprint", None)
        return result

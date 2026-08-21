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
  grace_until INTEGER, active_alarm_id TEXT, active_trip_id TEXT,
  offline_since INTEGER, parked_location_id INTEGER,
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
CREATE TABLE IF NOT EXISTS trips (
  id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id),
  started_at INTEGER NOT NULL, ended_at INTEGER, start_command_id TEXT,
  end_command_id TEXT, status TEXT NOT NULL, recovered_after_restart INTEGER NOT NULL DEFAULT 0,
  point_count INTEGER NOT NULL DEFAULT 0, distance_m REAL NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS trips_active_vehicle
  ON trips(vehicle_id) WHERE status='active';
CREATE TABLE IF NOT EXISTS locations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  vehicle_id TEXT NOT NULL REFERENCES vehicles(id), source TEXT NOT NULL,
  device_timestamp INTEGER, received_at INTEGER NOT NULL, valid INTEGER NOT NULL,
  latitude REAL, longitude REAL, satellites INTEGER, hdop REAL, altitude_m REAL,
  mode TEXT, display_eligible INTEGER NOT NULL DEFAULT 0, rejection_reason TEXT,
  distance_from_previous_m REAL, speed_mps REAL, alarm_id TEXT,
  trip_id TEXT REFERENCES trips(id),
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
CREATE TABLE IF NOT EXISTS ble_events (
  id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id),
  client_id TEXT NOT NULL REFERENCES clients(id), action TEXT NOT NULL,
  ble_result TEXT NOT NULL, readback_lock_state TEXT NOT NULL,
  device_operation_at INTEGER NOT NULL, received_at INTEGER NOT NULL,
  state_effect_applied INTEGER NOT NULL, ignored_reason TEXT
);
CREATE TABLE IF NOT EXISTS alarms (
  id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id),
  alarm_type TEXT NOT NULL, state TEXT NOT NULL,
  inferred INTEGER NOT NULL DEFAULT 0, first_triggered_at INTEGER NOT NULL,
  last_triggered_at INTEGER NOT NULL, trigger_count INTEGER NOT NULL DEFAULT 1,
  acknowledged_at INTEGER, cleared_at INTEGER, acknowledged_by TEXT,
  note TEXT, offline_started_at INTEGER, baseline_location_id INTEGER,
  reconnect_location_one_id INTEGER, reconnect_location_two_id INTEGER,
  baseline_distance_one_m REAL, baseline_distance_two_m REAL,
  sample_distance_m REAL, movement_threshold_m REAL,
  sample_max_separation_m REAL
);
CREATE UNIQUE INDEX IF NOT EXISTS alarms_active_type
  ON alarms(vehicle_id, alarm_type) WHERE state='active';
CREATE TABLE IF NOT EXISTS alarm_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, vehicle_id TEXT NOT NULL REFERENCES vehicles(id),
  alarm_id TEXT REFERENCES alarms(id), event_type TEXT NOT NULL,
  detail_json TEXT NOT NULL, created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS alarm_events_vehicle_time
  ON alarm_events(vehicle_id, created_at DESC);
CREATE TABLE IF NOT EXISTS settings (
  vehicle_id TEXT PRIMARY KEY REFERENCES vehicles(id),
  location_history_days INTEGER NOT NULL DEFAULT 7,
  pending_location_history_days INTEGER,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS cleanup_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, vehicle_id TEXT NOT NULL REFERENCES vehicles(id),
  history_days INTEGER NOT NULL, deleted_trips INTEGER NOT NULL,
  deleted_locations INTEGER NOT NULL, created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS device_sessions (
  id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id),
  peer_fingerprint TEXT NOT NULL, connected_at INTEGER NOT NULL,
  disconnected_at INTEGER, disconnect_reason TEXT,
  rx_count INTEGER NOT NULL DEFAULT 0, tx_count INTEGER NOT NULL DEFAULT 0,
  parse_error_count INTEGER NOT NULL DEFAULT 0,
  last_rx_at INTEGER, last_tx_at INTEGER, last_q0_at INTEGER, last_h0_at INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS device_sessions_active_vehicle
  ON device_sessions(vehicle_id) WHERE disconnected_at IS NULL;
CREATE INDEX IF NOT EXISTS device_sessions_vehicle_time
  ON device_sessions(vehicle_id, connected_at DESC);
CREATE TABLE IF NOT EXISTS audit_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  actor TEXT NOT NULL, action TEXT NOT NULL,
  object_type TEXT NOT NULL, object_id TEXT,
  result TEXT NOT NULL, request_id TEXT,
  detail_json TEXT NOT NULL, created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS audit_logs_time ON audit_logs(created_at DESC, id DESC);
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
        self._migrate_alarms()
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
        if "grace_until" not in columns:
            self.connection.execute("ALTER TABLE vehicle_state ADD COLUMN grace_until INTEGER")
        if "active_alarm_id" not in columns:
            self.connection.execute("ALTER TABLE vehicle_state ADD COLUMN active_alarm_id TEXT")
        if "active_trip_id" not in columns:
            self.connection.execute("ALTER TABLE vehicle_state ADD COLUMN active_trip_id TEXT")
        if "offline_since" not in columns:
            self.connection.execute("ALTER TABLE vehicle_state ADD COLUMN offline_since INTEGER")
        if "parked_location_id" not in columns:
            self.connection.execute(
                "ALTER TABLE vehicle_state ADD COLUMN parked_location_id INTEGER"
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
        if "alarm_id" not in columns:
            self.connection.execute("ALTER TABLE locations ADD COLUMN alarm_id TEXT")
        if "trip_id" not in columns:
            self.connection.execute("ALTER TABLE locations ADD COLUMN trip_id TEXT")
        self.connection.execute(
            "CREATE INDEX IF NOT EXISTS locations_trip_time "
            "ON locations(trip_id, received_at) WHERE trip_id IS NOT NULL"
        )

    def _migrate_alarms(self) -> None:
        columns = {
            row[1] for row in self.connection.execute("PRAGMA table_info(alarms)")
        }
        additions = {
            "offline_started_at": "INTEGER",
            "baseline_location_id": "INTEGER",
            "reconnect_location_one_id": "INTEGER",
            "reconnect_location_two_id": "INTEGER",
            "baseline_distance_one_m": "REAL",
            "baseline_distance_two_m": "REAL",
            "sample_distance_m": "REAL",
            "movement_threshold_m": "REAL",
            "sample_max_separation_m": "REAL",
        }
        for name, column_type in additions.items():
            if name not in columns:
                self.connection.execute(
                    f"ALTER TABLE alarms ADD COLUMN {name} {column_type}"
                )

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
        self.connection.execute(
            "INSERT OR IGNORE INTO settings(vehicle_id,updated_at) VALUES(?,?)",
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
            self._insert_audit(
                client_id, "pairing.complete", "client", client_id,
                "succeeded", client_id, {"permissions": permissions}, now,
            )
        return {"client_id": client_id, "permissions": permissions}

    def open_device_session(self, vehicle_id: str, peer_fingerprint: str,
                            now: Optional[int] = None) -> dict[str, Any]:
        current_time = int(time.time()) if now is None else now
        session_id = str(uuid.uuid4())
        with self.connection:
            replaced = self.connection.execute(
                "SELECT id FROM device_sessions WHERE vehicle_id=? "
                "AND disconnected_at IS NULL",
                (vehicle_id,),
            ).fetchall()
            for row in replaced:
                self.connection.execute(
                    "UPDATE device_sessions SET disconnected_at=?,disconnect_reason='replaced' "
                    "WHERE id=?",
                    (current_time, row["id"]),
                )
                self._insert_audit(
                    "iot_device", "device_session.closed", "device_session", row["id"],
                    "replaced", row["id"], {}, current_time,
                )
            self.connection.execute(
                "INSERT INTO device_sessions(id,vehicle_id,peer_fingerprint,connected_at) "
                "VALUES(?,?,?,?)",
                (session_id, vehicle_id, peer_fingerprint, current_time),
            )
            self._insert_audit(
                "iot_device", "device_session.connected", "device_session", session_id,
                "succeeded", session_id, {"peer_fingerprint": peer_fingerprint}, current_time,
            )
        return self.device_session(session_id)

    def record_device_rx(self, session_id: str, function: str,
                         now: Optional[int] = None) -> None:
        current_time = int(time.time()) if now is None else now
        q0_at = current_time if function == "Q0" else None
        h0_at = current_time if function == "H0" else None
        with self.connection:
            self.connection.execute(
                "UPDATE device_sessions SET rx_count=rx_count+1,last_rx_at=?,"
                "last_q0_at=COALESCE(?,last_q0_at),last_h0_at=COALESCE(?,last_h0_at) "
                "WHERE id=? AND disconnected_at IS NULL",
                (current_time, q0_at, h0_at, session_id),
            )

    def record_device_tx(self, session_id: str,
                         now: Optional[int] = None) -> None:
        current_time = int(time.time()) if now is None else now
        with self.connection:
            self.connection.execute(
                "UPDATE device_sessions SET tx_count=tx_count+1,last_tx_at=? "
                "WHERE id=? AND disconnected_at IS NULL",
                (current_time, session_id),
            )

    def record_device_parse_error(self, session_id: str) -> None:
        with self.connection:
            self.connection.execute(
                "UPDATE device_sessions SET parse_error_count=parse_error_count+1 "
                "WHERE id=? AND disconnected_at IS NULL",
                (session_id,),
            )

    def close_device_session(self, session_id: str, reason: str,
                             now: Optional[int] = None) -> None:
        current_time = int(time.time()) if now is None else now
        with self.connection:
            cursor = self.connection.execute(
                "UPDATE device_sessions SET disconnected_at=?,disconnect_reason=? "
                "WHERE id=? AND disconnected_at IS NULL",
                (current_time, reason, session_id),
            )
            if cursor.rowcount:
                self._insert_audit(
                    "iot_device", "device_session.closed", "device_session", session_id,
                    reason, session_id, {}, current_time,
                )

    def close_active_device_sessions(self, vehicle_id: str, reason: str,
                                     now: Optional[int] = None) -> int:
        current_time = int(time.time()) if now is None else now
        with self.connection:
            rows = self.connection.execute(
                "SELECT id FROM device_sessions WHERE vehicle_id=? "
                "AND disconnected_at IS NULL",
                (vehicle_id,),
            ).fetchall()
            for row in rows:
                self.connection.execute(
                    "UPDATE device_sessions SET disconnected_at=?,disconnect_reason=? "
                    "WHERE id=?",
                    (current_time, reason, row["id"]),
                )
                self._insert_audit(
                    "system", "device_session.closed", "device_session", row["id"],
                    reason, row["id"], {}, current_time,
                )
        return len(rows)

    def device_session(self, session_id: str) -> dict[str, Any]:
        row = self.connection.execute(
            "SELECT * FROM device_sessions WHERE id=?", (session_id,)
        ).fetchone()
        if row is None:
            raise KeyError(session_id)
        return dict(row)

    def device_sessions(self, vehicle_id: str,
                        limit: int = 50) -> list[dict[str, Any]]:
        rows = self.connection.execute(
            "SELECT * FROM device_sessions WHERE vehicle_id=? "
            "ORDER BY connected_at DESC LIMIT ?",
            (vehicle_id, max(1, min(limit, 100))),
        ).fetchall()
        return [dict(row) for row in rows]

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
            "grace_until", "active_alarm_id", "active_trip_id",
            "offline_since", "parked_location_id",
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

    def mark_device_disconnected(self, vehicle_id: str,
                                 now: Optional[int] = None) -> dict[str, Any]:
        current_time = int(time.time()) if now is None else now
        state = self.connection.execute(
            "SELECT lock_state FROM vehicle_state WHERE vehicle_id=?", (vehicle_id,)
        ).fetchone()
        if state is None:
            raise KeyError(vehicle_id)
        baseline_id = None
        if state["lock_state"] == "locked":
            baseline = self.connection.execute(
                "SELECT id FROM locations WHERE vehicle_id=? AND valid=1 "
                "AND display_eligible=1 ORDER BY "
                "COALESCE(device_timestamp,received_at) DESC,id DESC LIMIT 1",
                (vehicle_id,),
            ).fetchone()
            baseline_id = baseline["id"] if baseline else None
        with self.connection:
            self.connection.execute(
                "UPDATE vehicle_state SET online=0,offline_since=?,parked_location_id=?,"
                "updated_at=? WHERE vehicle_id=?",
                (
                    current_time if state["lock_state"] == "locked" else None,
                    baseline_id,
                    current_time,
                    vehicle_id,
                ),
            )
            self._insert_alarm_event(
                vehicle_id, None, "device_disconnected",
                {
                    "locked": state["lock_state"] == "locked",
                    "offline_check_available": baseline_id is not None,
                },
                current_time,
            )
        return self.vehicle(vehicle_id)

    def pending_offline_check(self, vehicle_id: str) -> Optional[dict[str, Any]]:
        state = self.connection.execute(
            "SELECT offline_since,parked_location_id FROM vehicle_state WHERE vehicle_id=?",
            (vehicle_id,),
        ).fetchone()
        if state is None:
            raise KeyError(vehicle_id)
        if state["offline_since"] is None:
            return None
        baseline = None
        if state["parked_location_id"] is not None:
            row = self.connection.execute(
                "SELECT * FROM locations WHERE id=? AND vehicle_id=? AND valid=1 "
                "AND display_eligible=1",
                (state["parked_location_id"], vehicle_id),
            ).fetchone()
            baseline = self._location_dict(row) if row else None
        return {
            "offline_since": state["offline_since"],
            "baseline_location": baseline,
        }

    def clear_offline_check(self, vehicle_id: str, event_type: str,
                            detail: Optional[dict[str, Any]] = None,
                            now: Optional[int] = None) -> None:
        current_time = int(time.time()) if now is None else now
        with self.connection:
            self.connection.execute(
                "UPDATE vehicle_state SET offline_since=NULL,parked_location_id=NULL,"
                "updated_at=? WHERE vehicle_id=?",
                (current_time, vehicle_id),
            )
            self._insert_alarm_event(
                vehicle_id, None, event_type, detail or {}, current_time
            )

    def apply_confirmed_lock_state(self, vehicle_id: str, lock_state: str,
                                   source: str, updated_at: int,
                                   unlock_user: Optional[str] = None,
                                   unlock_timestamp: Optional[str] = None,
                                   command_id: Optional[str] = None) -> None:
        if lock_state not in {"locked", "unlocked"}:
            raise ValueError("锁状态无效")
        with self.connection:
            self._apply_confirmed_lock_state(
                vehicle_id, lock_state, source, updated_at, unlock_user,
                unlock_timestamp, command_id,
            )

    def _apply_confirmed_lock_state(self, vehicle_id: str, lock_state: str,
                                    source: str, updated_at: int,
                                    unlock_user: Optional[str] = None,
                                    unlock_timestamp: Optional[str] = None,
                                    command_id: Optional[str] = None) -> None:
        if lock_state == "unlocked":
            active_alarms = self.connection.execute(
                "SELECT id FROM alarms WHERE vehicle_id=? AND state='active'",
                (vehicle_id,),
            ).fetchall()
            self.connection.execute(
                "UPDATE alarms SET state='cleared',cleared_at=? "
                "WHERE vehicle_id=? AND state='active'",
                (updated_at, vehicle_id),
            )
            self.connection.execute(
                "UPDATE vehicle_state SET lock_state='unlocked',security_state='disarmed',"
                "grace_until=NULL,active_alarm_id=NULL,active_unlock_user=?,"
                "active_unlock_timestamp=?,lock_state_source=?,lock_state_updated_at=?,"
                "offline_since=NULL,parked_location_id=NULL,updated_at=? WHERE vehicle_id=?",
                (unlock_user, unlock_timestamp, source, updated_at, updated_at, vehicle_id),
            )
            for alarm in active_alarms:
                self._insert_alarm_event(
                    vehicle_id, alarm["id"], "cleared_by_unlock", {}, updated_at
                )
            self._ensure_active_trip(
                vehicle_id, updated_at, command_id, recovered_after_restart=False
            )
        else:
            self._finish_active_trip(vehicle_id, updated_at, command_id)
            self.connection.execute(
                "UPDATE vehicle_state SET lock_state='locked',"
                "security_state=CASE WHEN active_alarm_id IS NULL "
                "THEN 'disarmed' ELSE 'alarm_active' END,"
                "grace_until=NULL,lock_state_source=?,lock_state_updated_at=?,updated_at=? "
                "WHERE vehicle_id=?",
                (source, updated_at, updated_at, vehicle_id),
            )

    def _ensure_active_trip(self, vehicle_id: str, started_at: int,
                            command_id: Optional[str],
                            recovered_after_restart: bool) -> str:
        state = self.connection.execute(
            "SELECT active_trip_id FROM vehicle_state WHERE vehicle_id=?", (vehicle_id,)
        ).fetchone()
        if state is None:
            raise KeyError(vehicle_id)
        if state["active_trip_id"]:
            return state["active_trip_id"]
        existing = self.connection.execute(
            "SELECT id FROM trips WHERE vehicle_id=? AND status='active'",
            (vehicle_id,),
        ).fetchone()
        trip_id = existing["id"] if existing else str(uuid.uuid4())
        if existing is None:
            self.connection.execute(
                "INSERT INTO trips(id,vehicle_id,started_at,start_command_id,status,"
                "recovered_after_restart,updated_at) VALUES(?,?,?,?,'active',?,?)",
                (trip_id, vehicle_id, started_at, command_id,
                 int(recovered_after_restart), started_at),
            )
            self._insert_audit(
                "system", "trip.started", "trip", trip_id, "active",
                command_id or trip_id,
                {"recovered_after_restart": recovered_after_restart}, started_at,
            )
        self.connection.execute(
            "UPDATE vehicle_state SET active_trip_id=?,updated_at=? WHERE vehicle_id=?",
            (trip_id, started_at, vehicle_id),
        )
        return trip_id

    def _finish_active_trip(self, vehicle_id: str, ended_at: int,
                            command_id: Optional[str]) -> Optional[str]:
        state = self.connection.execute(
            "SELECT active_trip_id FROM vehicle_state WHERE vehicle_id=?", (vehicle_id,)
        ).fetchone()
        if state is None:
            raise KeyError(vehicle_id)
        trip_id = state["active_trip_id"]
        if trip_id is None:
            return None
        self.connection.execute(
            "UPDATE trips SET ended_at=?,end_command_id=?,status='completed',updated_at=? "
            "WHERE id=? AND status='active'",
            (ended_at, command_id, ended_at, trip_id),
        )
        self._insert_audit(
            "system", "trip.completed", "trip", trip_id, "completed",
            command_id or trip_id, {}, ended_at,
        )
        self.connection.execute(
            "UPDATE vehicle_state SET active_trip_id=NULL,updated_at=? WHERE vehicle_id=?",
            (ended_at, vehicle_id),
        )
        return trip_id

    def recover_active_trip_if_needed(self, vehicle_id: str,
                                      now: Optional[int] = None) -> Optional[dict[str, Any]]:
        current_time = int(time.time()) if now is None else now
        state = self.connection.execute(
            "SELECT lock_state,active_trip_id FROM vehicle_state WHERE vehicle_id=?",
            (vehicle_id,),
        ).fetchone()
        if state is None:
            raise KeyError(vehicle_id)
        if state["lock_state"] != "unlocked":
            return None
        with self.connection:
            trip_id = self._ensure_active_trip(
                vehicle_id, current_time, None, recovered_after_restart=True
            )
        return self.trip(trip_id)

    def reconcile_trip_for_lock_state(self, vehicle_id: str, lock_state: str,
                                      now: Optional[int] = None) -> Optional[dict[str, Any]]:
        if lock_state not in {"locked", "unlocked"}:
            raise ValueError("锁状态无效")
        current_time = int(time.time()) if now is None else now
        with self.connection:
            if lock_state == "unlocked":
                trip_id = self._ensure_active_trip(
                    vehicle_id, current_time, None, recovered_after_restart=True
                )
            else:
                trip_id = self._finish_active_trip(vehicle_id, current_time, None)
        return self.trip(trip_id) if trip_id is not None else None

    def trip(self, trip_id: str) -> dict[str, Any]:
        row = self.connection.execute(
            "SELECT * FROM trips WHERE id=?", (trip_id,)
        ).fetchone()
        if row is None:
            raise KeyError(trip_id)
        return self._trip_dict(row)

    def trips(self, vehicle_id: str, limit: int = 100) -> list[dict[str, Any]]:
        rows = self.connection.execute(
            "SELECT * FROM trips WHERE vehicle_id=? "
            "ORDER BY started_at DESC LIMIT ?",
            (vehicle_id, max(1, min(limit, 500))),
        ).fetchall()
        return [self._trip_dict(row) for row in rows]

    def trip_locations(self, vehicle_id: str, trip_id: str,
                       include_filtered: bool = False) -> list[dict[str, Any]]:
        condition = "" if include_filtered else " AND valid=1 AND display_eligible=1"
        rows = self.connection.execute(
            "SELECT * FROM locations WHERE vehicle_id=? AND trip_id=?" + condition
            + " ORDER BY COALESCE(device_timestamp,received_at),id",
            (vehicle_id, trip_id),
        ).fetchall()
        return [self._location_dict(row) for row in rows]

    def start_lock_grace(self, vehicle_id: str, grace_seconds: int = 300,
                         now: Optional[int] = None) -> dict[str, Any]:
        current_time = int(time.time()) if now is None else now
        grace_until = current_time + grace_seconds
        with self.connection:
            self.connection.execute(
                "UPDATE vehicle_state SET security_state='grace_period',grace_until=?,"
                "updated_at=? WHERE vehicle_id=?",
                (grace_until, current_time, vehicle_id),
            )
            self._insert_alarm_event(
                vehicle_id, None, "grace_started",
                {"grace_until": grace_until}, current_time,
            )
        return self.vehicle(vehicle_id)

    def arm_security(self, vehicle_id: str, event_type: str = "manual_armed",
                     now: Optional[int] = None) -> dict[str, Any]:
        current_time = int(time.time()) if now is None else now
        with self.connection:
            self.connection.execute(
                "UPDATE vehicle_state SET security_state='armed',grace_until=NULL,updated_at=? "
                "WHERE vehicle_id=? AND active_alarm_id IS NULL",
                (current_time, vehicle_id),
            )
            self._insert_alarm_event(vehicle_id, None, event_type, {}, current_time)
        return self.vehicle(vehicle_id)

    def arm_if_grace_expired(self, vehicle_id: str,
                             now: Optional[int] = None) -> bool:
        current_time = int(time.time()) if now is None else now
        with self.connection:
            cursor = self.connection.execute(
                "UPDATE vehicle_state SET security_state='armed',grace_until=NULL,updated_at=? "
                "WHERE vehicle_id=? AND security_state='grace_period' "
                "AND grace_until IS NOT NULL AND grace_until<=?",
                (current_time, vehicle_id, current_time),
            )
            if cursor.rowcount:
                self._insert_alarm_event(
                    vehicle_id, None, "grace_completed", {}, current_time
                )
        return bool(cursor.rowcount)

    def record_movement_event(self, vehicle_id: str,
                              now: Optional[int] = None) -> dict[str, Any]:
        current_time = int(time.time()) if now is None else now
        self.arm_if_grace_expired(vehicle_id, current_time)
        state = self.connection.execute(
            "SELECT security_state,grace_until FROM vehicle_state WHERE vehicle_id=?",
            (vehicle_id,),
        ).fetchone()
        if state is None:
            raise KeyError(vehicle_id)
        if state["security_state"] == "grace_period":
            with self.connection:
                self._insert_alarm_event(
                    vehicle_id, None, "movement_suppressed",
                    {"grace_until": state["grace_until"]}, current_time,
                )
            return {"suppressed": True, "alarm": None, "should_notify": False}
        if state["security_state"] not in {"armed", "alarm_active"}:
            with self.connection:
                self._insert_alarm_event(
                    vehicle_id, None, "movement_disarmed", {}, current_time
                )
            return {"suppressed": False, "alarm": None, "should_notify": False}

        existing = self.connection.execute(
            "SELECT * FROM alarms WHERE vehicle_id=? AND alarm_type='illegal_movement' "
            "AND state='active'",
            (vehicle_id,),
        ).fetchone()
        alarm_id = existing["id"] if existing else str(uuid.uuid4())
        should_notify = existing is None or current_time - existing["last_triggered_at"] >= 60
        with self.connection:
            if existing:
                self.connection.execute(
                    "UPDATE alarms SET last_triggered_at=?,trigger_count=trigger_count+1 "
                    "WHERE id=?",
                    (current_time, alarm_id),
                )
            else:
                self.connection.execute(
                    "INSERT INTO alarms(id,vehicle_id,alarm_type,state,inferred,"
                    "first_triggered_at,last_triggered_at,trigger_count) "
                    "VALUES(?,?,?,'active',0,?,?,1)",
                    (alarm_id, vehicle_id, "illegal_movement", current_time, current_time),
                )
            self.connection.execute(
                "UPDATE vehicle_state SET security_state='alarm_active',active_alarm_id=?,"
                "grace_until=NULL,updated_at=? WHERE vehicle_id=?",
                (alarm_id, current_time, vehicle_id),
            )
            self._insert_alarm_event(
                vehicle_id, alarm_id,
                "movement_triggered" if existing is None else "movement_repeated",
                {"should_notify": should_notify}, current_time,
            )
        return {
            "suppressed": False,
            "alarm": self.alarm(alarm_id),
            "should_notify": should_notify,
        }

    def finalize_offline_movement_check(
        self, vehicle_id: str, *, offline_started_at: int,
        baseline_location_id: int, reconnect_location_one_id: int,
        reconnect_location_two_id: int, movement_threshold_m: float,
        sample_max_separation_m: float, now: Optional[int] = None,
    ) -> dict[str, Any]:
        if movement_threshold_m <= 0 or sample_max_separation_m <= 0:
            raise ValueError("离线移动阈值无效")
        current_time = int(time.time()) if now is None else now
        location_ids = (
            baseline_location_id,
            reconnect_location_one_id,
            reconnect_location_two_id,
        )
        if len(set(location_ids)) != 3:
            raise ValueError("离线移动定位必须互不重复")
        rows = self.connection.execute(
            "SELECT * FROM locations WHERE vehicle_id=? AND id IN (?,?,?)",
            (vehicle_id, *location_ids),
        ).fetchall()
        by_id = {row["id"]: row for row in rows}
        if any(location_id not in by_id for location_id in location_ids):
            raise ValueError("离线移动定位不存在")
        if any(
            not row["valid"] or not row["display_eligible"]
            or row["latitude"] is None or row["longitude"] is None
            for row in by_id.values()
        ):
            raise ValueError("离线移动定位不可信")
        baseline = by_id[baseline_location_id]
        sample_one = by_id[reconnect_location_one_id]
        sample_two = by_id[reconnect_location_two_id]
        distance_one = self._distance_m(
            baseline["latitude"], baseline["longitude"],
            sample_one["latitude"], sample_one["longitude"],
        )
        distance_two = self._distance_m(
            baseline["latitude"], baseline["longitude"],
            sample_two["latitude"], sample_two["longitude"],
        )
        sample_distance = self._distance_m(
            sample_one["latitude"], sample_one["longitude"],
            sample_two["latitude"], sample_two["longitude"],
        )
        movement_consistent = (
            distance_one >= movement_threshold_m
            and distance_two >= movement_threshold_m
            and sample_distance <= sample_max_separation_m
        )
        detail = {
            "baseline_location_id": baseline_location_id,
            "reconnect_location_one_id": reconnect_location_one_id,
            "reconnect_location_two_id": reconnect_location_two_id,
            "baseline_distance_one_m": round(distance_one, 1),
            "baseline_distance_two_m": round(distance_two, 1),
            "sample_distance_m": round(sample_distance, 1),
            "movement_threshold_m": movement_threshold_m,
            "sample_max_separation_m": sample_max_separation_m,
        }
        alarm_id = None
        with self.connection:
            active = self.connection.execute(
                "SELECT active_alarm_id,lock_state FROM vehicle_state WHERE vehicle_id=?",
                (vehicle_id,),
            ).fetchone()
            inferred = bool(
                movement_consistent and active and active["lock_state"] == "locked"
            )
            detail["lock_state_at_evaluation"] = (
                active["lock_state"] if active is not None else "unknown"
            )
            if inferred and active and active["active_alarm_id"] is None:
                alarm_id = str(uuid.uuid4())
                self.connection.execute(
                    "INSERT INTO alarms(id,vehicle_id,alarm_type,state,inferred,"
                    "first_triggered_at,last_triggered_at,trigger_count,note,"
                    "offline_started_at,baseline_location_id,reconnect_location_one_id,"
                    "reconnect_location_two_id,baseline_distance_one_m,"
                    "baseline_distance_two_m,sample_distance_m,movement_threshold_m,"
                    "sample_max_separation_m) VALUES(?,?,?,'active',1,?,?,1,?,?,?,?,?,?,?,?,?,?)",
                    (
                        alarm_id, vehicle_id, "suspected_offline_movement",
                        current_time, current_time,
                        "服务端根据两次重连定位推断，不是实时 W0",
                        offline_started_at, baseline_location_id,
                        reconnect_location_one_id, reconnect_location_two_id,
                        distance_one, distance_two, sample_distance,
                        movement_threshold_m, sample_max_separation_m,
                    ),
                )
                self.connection.execute(
                    "UPDATE vehicle_state SET security_state='alarm_active',"
                    "active_alarm_id=?,grace_until=NULL WHERE vehicle_id=?",
                    (alarm_id, vehicle_id),
                )
            self.connection.execute(
                "UPDATE vehicle_state SET offline_since=NULL,parked_location_id=NULL,"
                "updated_at=? WHERE vehicle_id=?",
                (current_time, vehicle_id),
            )
            self._insert_alarm_event(
                vehicle_id, alarm_id,
                "offline_movement_inferred" if alarm_id else "offline_movement_not_inferred",
                detail,
                current_time,
            )
        return {
            "inferred": alarm_id is not None,
            "alarm": self.alarm(alarm_id) if alarm_id else None,
            **detail,
        }

    def acknowledge_alarm(self, vehicle_id: str, client_id: str,
                          now: Optional[int] = None) -> Optional[dict[str, Any]]:
        current_time = int(time.time()) if now is None else now
        alarm = self.connection.execute(
            "SELECT * FROM alarms WHERE vehicle_id=? AND state='active' "
            "ORDER BY last_triggered_at DESC LIMIT 1",
            (vehicle_id,),
        ).fetchone()
        if alarm is None:
            return None
        lock = self.connection.execute(
            "SELECT lock_state FROM vehicle_state WHERE vehicle_id=?", (vehicle_id,)
        ).fetchone()
        security_state = "armed" if lock and lock["lock_state"] == "locked" else "disarmed"
        with self.connection:
            self.connection.execute(
                "UPDATE alarms SET state='acknowledged',acknowledged_at=?,"
                "acknowledged_by=? WHERE id=?",
                (current_time, client_id, alarm["id"]),
            )
            self.connection.execute(
                "UPDATE vehicle_state SET security_state=?,active_alarm_id=NULL,"
                "grace_until=NULL,updated_at=? WHERE vehicle_id=?",
                (security_state, current_time, vehicle_id),
            )
            self._insert_alarm_event(
                vehicle_id, alarm["id"], "acknowledged", {}, current_time
            )
        return self.alarm(alarm["id"])

    def alarm(self, alarm_id: str) -> dict[str, Any]:
        row = self.connection.execute(
            "SELECT * FROM alarms WHERE id=?", (alarm_id,)
        ).fetchone()
        if row is None:
            raise KeyError(alarm_id)
        return self._alarm_dict(row)

    def alarms(self, vehicle_id: str, active_only: bool = False,
               limit: int = 100) -> list[dict[str, Any]]:
        condition = " AND state='active'" if active_only else ""
        rows = self.connection.execute(
            "SELECT * FROM alarms WHERE vehicle_id=?" + condition
            + " ORDER BY last_triggered_at DESC LIMIT ?",
            (vehicle_id, max(1, min(limit, 500))),
        ).fetchall()
        return [self._alarm_dict(row) for row in rows]

    def alarm_events(self, vehicle_id: str,
                     limit: int = 100) -> list[dict[str, Any]]:
        rows = self.connection.execute(
            "SELECT * FROM alarm_events WHERE vehicle_id=? ORDER BY id DESC LIMIT ?",
            (vehicle_id, max(1, min(limit, 500))),
        ).fetchall()
        result = []
        for row in rows:
            event = dict(row)
            event["detail"] = json.loads(event.pop("detail_json"))
            result.append(event)
        return result

    def settings(self, vehicle_id: str) -> dict[str, Any]:
        row = self.connection.execute(
            "SELECT * FROM settings WHERE vehicle_id=?", (vehicle_id,)
        ).fetchone()
        if row is None:
            raise KeyError(vehicle_id)
        return dict(row)

    def set_location_history_days(self, vehicle_id: str, days: int,
                                  confirm_shorten: bool = False,
                                  now: Optional[int] = None,
                                  actor: str = "system",
                                  request_id: Optional[str] = None) -> dict[str, Any]:
        if days not in {7, 30}:
            raise ValueError("轨迹保留天数无效")
        current_time = int(time.time()) if now is None else now
        current = self.settings(vehicle_id)
        if current["location_history_days"] == 30 and days == 7:
            if not confirm_shorten:
                raise PermissionError("缩短轨迹保留期需要确认")
            with self.connection:
                self.connection.execute(
                    "UPDATE settings SET pending_location_history_days=7,updated_at=? "
                    "WHERE vehicle_id=?",
                    (current_time, vehicle_id),
                )
                self._insert_audit(
                    actor, "settings.location_history.updated", "vehicle", vehicle_id,
                    "pending", request_id,
                    {"days": days, "confirm_shorten": True}, current_time,
                )
        else:
            with self.connection:
                self.connection.execute(
                    "UPDATE settings SET location_history_days=?,"
                    "pending_location_history_days=NULL,updated_at=? WHERE vehicle_id=?",
                    (days, current_time, vehicle_id),
                )
                self._insert_audit(
                    actor, "settings.location_history.updated", "vehicle", vehicle_id,
                    "succeeded", request_id,
                    {"days": days, "confirm_shorten": confirm_shorten}, current_time,
                )
        return self.settings(vehicle_id)

    def run_retention_cleanup(self, vehicle_id: str,
                              now: Optional[int] = None) -> dict[str, int]:
        current_time = int(time.time()) if now is None else now
        with self.connection:
            setting = self.connection.execute(
                "SELECT location_history_days,pending_location_history_days "
                "FROM settings WHERE vehicle_id=?",
                (vehicle_id,),
            ).fetchone()
            if setting is None:
                raise KeyError(vehicle_id)
            history_days = (
                setting["pending_location_history_days"]
                if setting["pending_location_history_days"] is not None
                else setting["location_history_days"]
            )
            if setting["pending_location_history_days"] is not None:
                self.connection.execute(
                    "UPDATE settings SET location_history_days=?,"
                    "pending_location_history_days=NULL,updated_at=? WHERE vehicle_id=?",
                    (history_days, current_time, vehicle_id),
                )
            cutoff = current_time - history_days * 86400
            deleted_trip_locations = self.connection.execute(
                "SELECT COUNT(*) FROM locations WHERE trip_id IN "
                "(SELECT id FROM trips WHERE vehicle_id=? AND status!='active' "
                "AND ended_at IS NOT NULL AND ended_at<?)",
                (vehicle_id, cutoff),
            ).fetchone()[0]
            deleted_trips = self.connection.execute(
                "SELECT COUNT(*) FROM trips WHERE vehicle_id=? AND status!='active' "
                "AND ended_at IS NOT NULL AND ended_at<?",
                (vehicle_id, cutoff),
            ).fetchone()[0]
            self.connection.execute(
                "DELETE FROM locations WHERE trip_id IN "
                "(SELECT id FROM trips WHERE vehicle_id=? AND status!='active' "
                "AND ended_at IS NOT NULL AND ended_at<?)",
                (vehicle_id, cutoff),
            )
            self.connection.execute(
                "DELETE FROM trips WHERE vehicle_id=? AND status!='active' "
                "AND ended_at IS NOT NULL AND ended_at<?",
                (vehicle_id, cutoff),
            )
            ordinary_locations = self.connection.execute(
                "DELETE FROM locations WHERE vehicle_id=? AND trip_id IS NULL "
                "AND received_at<?",
                (vehicle_id, cutoff),
            ).rowcount
            deleted_locations = deleted_trip_locations + ordinary_locations
            self.connection.execute(
                "INSERT INTO cleanup_events(vehicle_id,history_days,deleted_trips,"
                "deleted_locations,created_at) VALUES(?,?,?,?,?)",
                (vehicle_id, history_days, deleted_trips,
                 deleted_locations, current_time),
            )
            thirty_day_cutoff = current_time - 30 * 86400
            seven_day_cutoff = current_time - 7 * 86400
            deleted_ble_events = self.connection.execute(
                "DELETE FROM ble_events WHERE vehicle_id=? AND received_at<?",
                (vehicle_id, thirty_day_cutoff),
            ).rowcount
            deleted_ble_observations = self.connection.execute(
                "DELETE FROM ble_observations WHERE vehicle_id=? AND received_at<?",
                (vehicle_id, thirty_day_cutoff),
            ).rowcount
            terminal_command_ids = [
                row["id"] for row in self.connection.execute(
                    "SELECT id FROM commands WHERE vehicle_id=? AND status IN "
                    "('succeeded','failed','unknown','noop','rejected') "
                    "AND completed_at IS NOT NULL AND completed_at<?",
                    (vehicle_id, thirty_day_cutoff),
                ).fetchall()
            ]
            deleted_commands = 0
            if terminal_command_ids:
                placeholders = ",".join("?" for _ in terminal_command_ids)
                self.connection.execute(
                    f"DELETE FROM command_events WHERE command_id IN ({placeholders})",
                    terminal_command_ids,
                )
                deleted_commands = self.connection.execute(
                    f"DELETE FROM commands WHERE id IN ({placeholders})",
                    terminal_command_ids,
                ).rowcount
            ended_alarm_ids = [
                row["id"] for row in self.connection.execute(
                    "SELECT id FROM alarms WHERE vehicle_id=? AND state!='active' "
                    "AND COALESCE(cleared_at,acknowledged_at,last_triggered_at)<?",
                    (vehicle_id, thirty_day_cutoff),
                ).fetchall()
            ]
            deleted_alarms = 0
            if ended_alarm_ids:
                placeholders = ",".join("?" for _ in ended_alarm_ids)
                self.connection.execute(
                    f"DELETE FROM alarm_events WHERE alarm_id IN ({placeholders})",
                    ended_alarm_ids,
                )
                deleted_alarms = self.connection.execute(
                    f"DELETE FROM alarms WHERE id IN ({placeholders})",
                    ended_alarm_ids,
                ).rowcount
            deleted_alarm_events = self.connection.execute(
                "DELETE FROM alarm_events WHERE vehicle_id=? AND created_at<?",
                (vehicle_id, thirty_day_cutoff),
            ).rowcount
            deleted_sessions = self.connection.execute(
                "DELETE FROM device_sessions WHERE vehicle_id=? AND disconnected_at IS NOT NULL "
                "AND disconnected_at<?",
                (vehicle_id, seven_day_cutoff),
            ).rowcount
            deleted_cleanup_events = self.connection.execute(
                "DELETE FROM cleanup_events WHERE vehicle_id=? AND created_at<?",
                (vehicle_id, thirty_day_cutoff),
            ).rowcount
            deleted_audits = self.connection.execute(
                "DELETE FROM audit_logs WHERE created_at<?", (thirty_day_cutoff,)
            ).rowcount
            self._insert_audit(
                "system", "retention.cleanup", "vehicle", vehicle_id, "succeeded",
                str(uuid.uuid4()),
                {
                    "history_days": history_days,
                    "deleted_trips": deleted_trips,
                    "deleted_locations": deleted_locations,
                    "deleted_ble_events": deleted_ble_events,
                    "deleted_ble_observations": deleted_ble_observations,
                    "deleted_commands": deleted_commands,
                    "deleted_alarms": deleted_alarms,
                    "deleted_alarm_events": deleted_alarm_events,
                    "deleted_sessions": deleted_sessions,
                    "deleted_cleanup_events": deleted_cleanup_events,
                    "deleted_audits": deleted_audits,
                },
                current_time,
            )
        return {
            "history_days": history_days,
            "deleted_trips": deleted_trips,
            "deleted_locations": deleted_locations,
            "deleted_ble_events": deleted_ble_events,
            "deleted_ble_observations": deleted_ble_observations,
            "deleted_commands": deleted_commands,
            "deleted_alarms": deleted_alarms,
            "deleted_alarm_events": deleted_alarm_events,
            "deleted_sessions": deleted_sessions,
            "deleted_audits": deleted_audits,
        }

    def cleanup_events(self, vehicle_id: str,
                       limit: int = 30) -> list[dict[str, Any]]:
        rows = self.connection.execute(
            "SELECT * FROM cleanup_events WHERE vehicle_id=? ORDER BY id DESC LIMIT ?",
            (vehicle_id, max(1, min(limit, 100))),
        ).fetchall()
        return [dict(row) for row in rows]

    def write_audit(self, actor: str, action: str, object_type: str,
                    object_id: Optional[str], result: str,
                    request_id: Optional[str] = None,
                    detail: Optional[dict[str, Any]] = None,
                    now: Optional[int] = None) -> dict[str, Any]:
        current_time = int(time.time()) if now is None else now
        with self.connection:
            audit_id = self._insert_audit(
                actor, action, object_type, object_id, result,
                request_id, detail or {}, current_time,
            )
        return self.audit_log(audit_id)

    def _insert_audit(self, actor: str, action: str, object_type: str,
                      object_id: Optional[str], result: str,
                      request_id: Optional[str], detail: dict[str, Any],
                      created_at: int) -> int:
        cursor = self.connection.execute(
            "INSERT INTO audit_logs(actor,action,object_type,object_id,result,request_id,"
            "detail_json,created_at) VALUES(?,?,?,?,?,?,?,?)",
            (
                actor, action, object_type, object_id, result, request_id,
                json.dumps(detail, separators=(",", ":"), ensure_ascii=False), created_at,
            ),
        )
        return int(cursor.lastrowid)

    def audit_log(self, audit_id: int) -> dict[str, Any]:
        row = self.connection.execute(
            "SELECT * FROM audit_logs WHERE id=?", (audit_id,)
        ).fetchone()
        if row is None:
            raise KeyError(audit_id)
        return self._audit_dict(row)

    def audit_logs(self, limit: int = 100) -> list[dict[str, Any]]:
        rows = self.connection.execute(
            "SELECT * FROM audit_logs ORDER BY created_at DESC,id DESC LIMIT ?",
            (max(1, min(limit, 500)),),
        ).fetchall()
        return [self._audit_dict(row) for row in rows]

    @staticmethod
    def _audit_dict(row: sqlite3.Row) -> dict[str, Any]:
        result = dict(row)
        detail = json.loads(result.pop("detail_json"))
        result["detail"] = detail
        result["detail_summary"] = json.dumps(
            detail, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ) if detail else ""
        return result

    def _insert_alarm_event(self, vehicle_id: str, alarm_id: Optional[str],
                            event_type: str, detail: dict[str, Any],
                            created_at: int) -> None:
        self.connection.execute(
            "INSERT INTO alarm_events(vehicle_id,alarm_id,event_type,detail_json,created_at) "
            "VALUES(?,?,?,?,?)",
            (vehicle_id, alarm_id, event_type,
             json.dumps(detail, separators=(",", ":")), created_at),
        )
        self._insert_audit(
            "iot_device" if event_type.startswith("movement_") else "system",
            f"alarm.{event_type}", "alarm", alarm_id or vehicle_id,
            "recorded", alarm_id or vehicle_id, detail, created_at,
        )

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
            self._insert_audit(
                client_id, "ble_observation.received", "ble_observation", observation_id,
                "applied" if applied else "ignored", observation_id,
                {"lock_state": lock_state}, received_at,
            )
        row = self.connection.execute(
            "SELECT * FROM ble_observations WHERE id=?", (observation_id,)
        ).fetchone()
        result = dict(row)
        result["applied"] = bool(result["applied"])
        return result, True

    def save_ble_event(self, event_id: str, vehicle_id: str, client_id: str,
                       action: str, ble_result: str, readback_lock_state: str,
                       device_operation_at: int) -> tuple[dict[str, Any], bool]:
        existing = self.connection.execute(
            "SELECT * FROM ble_events WHERE id=?", (event_id,)
        ).fetchone()
        if existing:
            return self._ble_event_dict(existing), False

        received_at = int(time.time())
        expected_lock_state = {"unlock": "unlocked", "lock": "locked"}.get(action)
        ignored_reason: Optional[str] = None
        if device_operation_at < received_at - 86400:
            ignored_reason = "stale_over_24h"
        elif ble_result != "succeeded":
            ignored_reason = "result_not_succeeded"
        elif expected_lock_state != readback_lock_state:
            ignored_reason = "readback_mismatch"
        else:
            current = self.connection.execute(
                "SELECT lock_state_updated_at FROM vehicle_state WHERE vehicle_id=?",
                (vehicle_id,),
            ).fetchone()
            if current is None:
                raise KeyError(vehicle_id)
            if (current["lock_state_updated_at"] is not None
                    and device_operation_at <= current["lock_state_updated_at"]):
                ignored_reason = "superseded_by_newer_state"

        applied = ignored_reason is None
        with self.connection:
            self.connection.execute(
                "INSERT INTO ble_events(id,vehicle_id,client_id,action,ble_result,"
                "readback_lock_state,device_operation_at,received_at,state_effect_applied,"
                "ignored_reason) VALUES(?,?,?,?,?,?,?,?,?,?)",
                (event_id, vehicle_id, client_id, action, ble_result,
                 readback_lock_state, device_operation_at, received_at,
                 int(applied), ignored_reason),
            )
            if applied:
                self._apply_confirmed_lock_state(
                    vehicle_id, readback_lock_state, "ble_event", device_operation_at
                )
            self._insert_audit(
                client_id, "ble_event.received", "ble_event", event_id,
                "applied" if applied else "ignored", event_id,
                {
                    "action": action,
                    "ble_result": ble_result,
                    "readback_lock_state": readback_lock_state,
                    "ignored_reason": ignored_reason,
                },
                received_at,
            )
        row = self.connection.execute(
            "SELECT * FROM ble_events WHERE id=?", (event_id,)
        ).fetchone()
        return self._ble_event_dict(row), True

    @staticmethod
    def _ble_event_dict(row: sqlite3.Row) -> dict[str, Any]:
        result = dict(row)
        result["state_effect_applied"] = bool(result["state_effect_applied"])
        return result

    def save_location(self, vehicle_id: str, *, source: str,
                      device_timestamp: Optional[int], valid: bool,
                      latitude: Optional[float], longitude: Optional[float],
                      satellites: Optional[int], hdop: Optional[float],
                      altitude_m: Optional[float], mode: Optional[str],
                      raw_fields: tuple[str, ...], min_satellites: int = 4,
                      max_hdop: float = 8.0,
                      max_speed_mps: float = 25.0,
                      alarm_id: Optional[str] = None) -> dict[str, Any]:
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
        state = self.connection.execute(
            "SELECT active_trip_id FROM vehicle_state WHERE vehicle_id=?", (vehicle_id,)
        ).fetchone()
        trip_id = state["active_trip_id"] if state else None
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
        trip_distance = 0.0
        if eligible and trip_id is not None:
            previous_trip_point = self.connection.execute(
                "SELECT device_timestamp,latitude,longitude FROM locations "
                "WHERE vehicle_id=? AND trip_id=? AND display_eligible=1 "
                "AND device_timestamp IS NOT NULL AND latitude IS NOT NULL "
                "AND longitude IS NOT NULL "
                "ORDER BY device_timestamp DESC,id DESC LIMIT 1",
                (vehicle_id, trip_id),
            ).fetchone()
            if previous_trip_point is not None and device_timestamp is not None:
                elapsed = device_timestamp - previous_trip_point["device_timestamp"]
                if 0 < elapsed <= 600:
                    trip_distance = self._distance_m(
                        previous_trip_point["latitude"], previous_trip_point["longitude"],
                        latitude, longitude,
                    )
        with self.connection:
            cursor = self.connection.execute(
                "INSERT OR IGNORE INTO locations(vehicle_id,source,device_timestamp,received_at,"
                "valid,latitude,longitude,satellites,hdop,altitude_m,mode,display_eligible,"
                "rejection_reason,distance_from_previous_m,speed_mps,alarm_id,trip_id,"
                "raw_fields_json,fingerprint) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (vehicle_id, source, device_timestamp, received_at, int(valid), latitude,
                 longitude, satellites, hdop, altitude_m, mode, int(eligible), reason,
                 distance, speed, alarm_id, trip_id, raw_json, fingerprint),
            )
            if cursor.rowcount and eligible and trip_id is not None:
                self.connection.execute(
                    "UPDATE trips SET point_count=point_count+1,distance_m=distance_m+?,"
                    "updated_at=? WHERE id=? AND status='active'",
                    (trip_distance, received_at, trip_id),
                )
            if cursor.rowcount:
                location_id = str(cursor.lastrowid)
                self._insert_audit(
                    "iot_device", "location.received", "location", location_id,
                    "accepted" if eligible else "filtered", location_id,
                    {"source": source, "rejection_reason": reason, "trip_id": trip_id},
                    received_at,
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
            self._insert_audit(
                client_id or "system", "command.created", "command", command_id,
                "accepted", command_id, {"command_type": command_type}, now,
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
            command = self.connection.execute(
                "SELECT client_id,command_type FROM commands WHERE id=?", (command_id,)
            ).fetchone()
            self._insert_audit(
                (command["client_id"] if command and command["client_id"] else "system"),
                "command.status", "command", command_id, status, command_id,
                {
                    "command_type": command["command_type"] if command else "unknown",
                    "error_code": error_code,
                    "detail": detail or {},
                },
                now,
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

    def latest_command(self, vehicle_id: str,
                       command_type: str) -> Optional[dict[str, Any]]:
        row = self.connection.execute(
            "SELECT * FROM commands WHERE vehicle_id=? AND command_type=? "
            "ORDER BY created_at DESC LIMIT 1",
            (vehicle_id, command_type),
        ).fetchone()
        return self._command_dict(row) if row else None

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

    def _alarm_dict(self, row: sqlite3.Row) -> dict[str, Any]:
        result = dict(row)
        result["inferred"] = bool(result["inferred"])
        baseline_id = result.get("baseline_location_id")
        reconnect_id = result.get("reconnect_location_two_id")
        result["baseline_captured_at"] = self._location_captured_at(baseline_id)
        result["reconnect_captured_at"] = self._location_captured_at(reconnect_id)
        return result

    def _location_captured_at(self, location_id: Optional[int]) -> Optional[int]:
        if location_id is None:
            return None
        row = self.connection.execute(
            "SELECT COALESCE(device_timestamp,received_at) AS captured_at "
            "FROM locations WHERE id=?",
            (location_id,),
        ).fetchone()
        return int(row["captured_at"]) if row else None

    @staticmethod
    def _trip_dict(row: sqlite3.Row) -> dict[str, Any]:
        result = dict(row)
        result["recovered_after_restart"] = bool(result["recovered_after_restart"])
        return result

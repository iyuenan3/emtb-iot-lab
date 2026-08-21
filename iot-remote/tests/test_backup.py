import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

from iot_remote.backup import (
    BackupError,
    create_encrypted_backup,
    decrypt_and_verify_backup,
    record_backup_audit,
)
from iot_remote.database import Database


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.openssl = shutil.which("openssl")
        if self.openssl is None:
            self.skipTest("OpenSSL 不可用")
        self.database_path = self.root / "iot.sqlite3"
        database = Database(str(self.database_path))
        database.ensure_vehicle("123", "测试车")
        database.close()
        self.certificate = self.root / "recipient.pem"
        self.private_key = self.root / "recipient-key.pem"
        self._make_identity(self.certificate, self.private_key, "backup-test")

    def tearDown(self):
        self.temp.cleanup()

    def _make_identity(self, certificate: Path, private_key: Path, name: str) -> None:
        subprocess.run([
            self.openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-subj", f"/CN={name}", "-days", "1", "-keyout", str(private_key),
            "-out", str(certificate),
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.chmod(private_key, 0o600)

    def test_encrypted_backup_round_trip_and_atomic_replacement(self):
        output = self.root / "recovery"
        first = create_encrypted_backup(
            str(self.database_path), str(self.certificate), str(output),
            self.openssl, now=100,
        )
        first_cipher = (output / "latest.cms").read_bytes()
        second = create_encrypted_backup(
            str(self.database_path), str(self.certificate), str(output),
            self.openssl, now=200,
        )

        self.assertEqual(first["created_at"], 100)
        self.assertEqual(second["created_at"], 200)
        self.assertNotEqual(first_cipher, (output / "latest.cms").read_bytes())
        self.assertEqual(list(output.glob("*.cms")), [output / "latest.cms"])
        self.assertEqual(os.stat(output).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(output / "latest.cms").st_mode & 0o777, 0o600)
        self.assertFalse(any(output.glob(".backup-*")))
        metadata = json.loads((output / "latest.json").read_text())
        self.assertEqual(metadata["created_at"], 200)

        restored = self.root / "restored.sqlite3"
        result = decrypt_and_verify_backup(
            str(output / "latest.cms"), str(self.certificate),
            str(self.private_key), str(restored), self.openssl,
        )
        self.assertEqual(result["created_at"], 200)
        connection = sqlite3.connect(str(restored))
        try:
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM vehicles").fetchone()[0], 1
            )
            self.assertEqual(
                connection.execute("PRAGMA integrity_check").fetchone()[0], "ok"
            )
        finally:
            connection.close()

    def test_wrong_private_key_is_rejected_without_output(self):
        output = self.root / "recovery"
        create_encrypted_backup(
            str(self.database_path), str(self.certificate), str(output), self.openssl
        )
        other_certificate = self.root / "other.pem"
        other_key = self.root / "other-key.pem"
        self._make_identity(other_certificate, other_key, "other-test")
        restored = self.root / "should-not-exist.sqlite3"

        with self.assertRaises(BackupError):
            decrypt_and_verify_backup(
                str(output / "latest.cms"), str(other_certificate),
                str(other_key), str(restored), self.openssl,
            )

        self.assertFalse(restored.exists())

    def test_backup_audit_contains_only_safe_metadata(self):
        detail = {
            "created_at": 100,
            "cipher": "CMS AES-256-CBC with RSA recipient",
            "cipher_bytes": 123,
            "cipher_sha256": "a" * 64,
        }
        record_backup_audit(str(self.database_path), "succeeded", detail)

        database = Database(str(self.database_path))
        try:
            audit = database.audit_logs(1)[0]
        finally:
            database.close()
        self.assertEqual(audit["action"], "recovery.backup")
        self.assertEqual(audit["result"], "succeeded")
        self.assertEqual(audit["detail"], detail)
        self.assertNotIn("key", audit["detail_summary"].lower())


if __name__ == "__main__":
    unittest.main()

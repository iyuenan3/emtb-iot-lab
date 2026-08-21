"""SQLite 加密恢复副本与人工恢复校验。"""

import fcntl
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Optional


BACKUP_FORMAT_VERSION = 1
MAX_DATABASE_BYTES = 2 * 1024 * 1024 * 1024


class BackupError(RuntimeError):
    """恢复副本创建或校验失败。"""


def _regular_file(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.is_file():
        raise BackupError(f"{label}不是普通文件")
    return path.resolve()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _check_sqlite(path: Path) -> None:
    connection = sqlite3.connect(f"{path.as_uri()}?mode=ro&immutable=1", uri=True)
    try:
        result = connection.execute("PRAGMA integrity_check").fetchone()
        if result is None or result[0] != "ok":
            raise BackupError("SQLite 完整性检查失败")
    finally:
        connection.close()


def _online_snapshot(source_path: Path, target_path: Path) -> None:
    source = sqlite3.connect(f"{source_path.as_uri()}?mode=ro", uri=True)
    target = sqlite3.connect(str(target_path))
    try:
        source.execute("PRAGMA busy_timeout=5000")
        source.backup(target)
        target.commit()
    finally:
        target.close()
        source.close()
    os.chmod(target_path, 0o600)
    _check_sqlite(target_path)


def _archive_snapshot(snapshot: Path, archive: Path, created_at: int) -> dict[str, Any]:
    database_bytes = snapshot.stat().st_size
    if database_bytes <= 0 or database_bytes > MAX_DATABASE_BYTES:
        raise BackupError("SQLite 副本大小无效")
    manifest = {
        "format_version": BACKUP_FORMAT_VERSION,
        "created_at": created_at,
        "database_name": "iot.sqlite3",
        "database_bytes": database_bytes,
        "database_sha256": _sha256(snapshot),
    }
    manifest_path = archive.parent / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    )
    os.chmod(manifest_path, 0o600)

    def normalize(info: tarfile.TarInfo) -> tarfile.TarInfo:
        info.uid = 0
        info.gid = 0
        info.uname = ""
        info.gname = ""
        info.mode = 0o600
        info.mtime = created_at
        return info

    with tarfile.open(archive, "w") as bundle:
        bundle.add(snapshot, arcname="iot.sqlite3", recursive=False, filter=normalize)
        bundle.add(manifest_path, arcname="manifest.json", recursive=False, filter=normalize)
    os.chmod(archive, 0o600)
    return manifest


def _run_openssl(arguments: list[str]) -> None:
    try:
        subprocess.run(
            arguments, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            timeout=300,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise BackupError("OpenSSL CMS 操作失败") from error


def _atomic_json(path: Path, value: dict[str, Any]) -> Path:
    descriptor, temporary = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}-", text=True
    )
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(value, output, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists() and not temporary_path.is_symlink():
            temporary_path.unlink()
    return path


def create_encrypted_backup(database_path: str, recipient_certificate: str,
                            output_directory: str, openssl_path: str = "/usr/bin/openssl",
                            now: Optional[int] = None) -> dict[str, Any]:
    database = _regular_file(Path(database_path), "SQLite 数据库")
    certificate = _regular_file(Path(recipient_certificate), "恢复公钥证书")
    output = Path(output_directory)
    if output.is_symlink():
        raise BackupError("恢复副本目录不能是符号链接")
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(output, 0o700)
    output = output.resolve()
    latest = output / "latest.cms"
    metadata = output / "latest.json"
    for managed in (latest, metadata):
        if managed.is_symlink():
            raise BackupError("恢复副本目标不能是符号链接")

    lock_flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_CLOEXEC"):
        lock_flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        lock_flags |= os.O_NOFOLLOW
    lock_descriptor = os.open(output / ".backup.lock", lock_flags, 0o600)
    work_directory: Optional[Path] = None
    try:
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        created_at = int(time.time()) if now is None else now
        work_directory = Path(tempfile.mkdtemp(dir=output, prefix=".backup-"))
        os.chmod(work_directory, 0o700)
        snapshot = work_directory / "iot.sqlite3"
        archive = work_directory / "payload.tar"
        encrypted = work_directory / "latest.cms"
        _online_snapshot(database, snapshot)
        manifest = _archive_snapshot(snapshot, archive, created_at)
        _run_openssl([
            openssl_path, "cms", "-encrypt", "-binary", "-aes256",
            "-outform", "DER", "-in", str(archive), "-out", str(encrypted),
            str(certificate),
        ])
        if not encrypted.is_file() or encrypted.stat().st_size <= 0:
            raise BackupError("加密恢复副本为空")
        os.chmod(encrypted, 0o600)
        cipher_sha256 = _sha256(encrypted)
        result = {
            "format_version": BACKUP_FORMAT_VERSION,
            "created_at": manifest["created_at"],
            "cipher": "CMS AES-256-CBC with RSA recipient",
            "cipher_bytes": encrypted.stat().st_size,
            "cipher_sha256": cipher_sha256,
        }
        os.replace(encrypted, latest)
        os.chmod(latest, 0o600)
        _atomic_json(metadata, result)
        directory_descriptor = os.open(output, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
        return result
    finally:
        if work_directory is not None and work_directory.exists():
            shutil.rmtree(work_directory)
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def verify_decrypted_archive(archive_path: str, output_database: str) -> dict[str, Any]:
    archive = _regular_file(Path(archive_path), "解密归档")
    destination = Path(output_database)
    if destination.exists() or destination.is_symlink():
        raise BackupError("恢复目标已经存在")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if destination.parent.is_symlink():
        raise BackupError("恢复目标目录不能是符号链接")
    descriptor, temporary = tempfile.mkstemp(
        dir=destination.parent, prefix=f".{destination.name}-"
    )
    temporary_path = Path(temporary)
    os.close(descriptor)
    try:
        with tarfile.open(archive, "r:") as bundle:
            member_list = bundle.getmembers()
            members = {member.name: member for member in member_list}
            if (len(member_list) != 2
                    or set(members) != {"iot.sqlite3", "manifest.json"}):
                raise BackupError("恢复归档内容无效")
            if any(not member.isfile() for member in members.values()):
                raise BackupError("恢复归档包含非普通文件")
            database_member = members["iot.sqlite3"]
            manifest_member = members["manifest.json"]
            if (database_member.size <= 0 or database_member.size > MAX_DATABASE_BYTES
                    or manifest_member.size <= 0 or manifest_member.size > 65536):
                raise BackupError("恢复归档成员大小无效")
            manifest_source = bundle.extractfile(manifest_member)
            database_source = bundle.extractfile(database_member)
            if manifest_source is None or database_source is None:
                raise BackupError("恢复归档成员缺失")
            manifest = json.loads(manifest_source.read().decode("utf-8"))
            with temporary_path.open("wb") as target:
                shutil.copyfileobj(database_source, target, length=1024 * 1024)
                target.flush()
                os.fsync(target.fileno())
        os.chmod(temporary_path, 0o600)
        if manifest.get("format_version") != BACKUP_FORMAT_VERSION:
            raise BackupError("恢复副本格式版本不支持")
        if not isinstance(manifest.get("created_at"), int):
            raise BackupError("恢复副本创建时间无效")
        if manifest.get("database_name") != "iot.sqlite3":
            raise BackupError("恢复副本数据库名称无效")
        if (not isinstance(manifest.get("database_bytes"), int)
                or manifest.get("database_bytes") != temporary_path.stat().st_size):
            raise BackupError("恢复副本数据库大小不一致")
        database_sha256 = manifest.get("database_sha256")
        if (not isinstance(database_sha256, str) or len(database_sha256) != 64
                or database_sha256 != _sha256(temporary_path)):
            raise BackupError("恢复副本数据库摘要不一致")
        _check_sqlite(temporary_path)
        os.replace(temporary_path, destination)
        os.chmod(destination, 0o600)
        return {
            "format_version": manifest["format_version"],
            "created_at": manifest["created_at"],
            "database_bytes": manifest["database_bytes"],
            "database_sha256": manifest["database_sha256"],
        }
    except (json.JSONDecodeError, tarfile.TarError) as error:
        raise BackupError("恢复归档无法解析") from error
    finally:
        if temporary_path.exists() and not temporary_path.is_symlink():
            temporary_path.unlink()


def decrypt_and_verify_backup(encrypted_path: str, recipient_certificate: str,
                              private_key: str, output_database: str,
                              openssl_path: str = "/usr/bin/openssl") -> dict[str, Any]:
    encrypted = _regular_file(Path(encrypted_path), "加密恢复副本")
    certificate = _regular_file(Path(recipient_certificate), "恢复公钥证书")
    key = _regular_file(Path(private_key), "恢复私钥")
    destination = Path(output_database)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(
        dir=destination.parent, prefix=".decrypted-", suffix=".tar"
    )
    archive = Path(temporary)
    os.close(descriptor)
    try:
        _run_openssl([
            openssl_path, "cms", "-decrypt", "-binary", "-inform", "DER",
            "-in", str(encrypted), "-recip", str(certificate),
            "-inkey", str(key), "-out", str(archive),
        ])
        os.chmod(archive, 0o600)
        return verify_decrypted_archive(str(archive), str(destination))
    finally:
        if archive.exists() and not archive.is_symlink():
            archive.unlink()


def record_backup_audit(database_path: str, result: str,
                        detail: Optional[dict[str, Any]] = None) -> None:
    database = Path(database_path)
    if database.is_symlink() or not database.is_file():
        return
    connection = sqlite3.connect(str(database))
    try:
        connection.execute("PRAGMA busy_timeout=5000")
        table = connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='audit_logs'"
        ).fetchone()
        if table is None:
            return
        current_time = int(time.time())
        with connection:
            connection.execute(
                "INSERT INTO audit_logs(actor,action,object_type,object_id,result,request_id,"
                "detail_json,created_at) VALUES(?,?,?,?,?,?,?,?)",
                (
                    "system", "recovery.backup", "database_backup", "latest",
                    result, str(uuid.uuid4()),
                    json.dumps(detail or {}, separators=(",", ":")), current_time,
                ),
            )
    finally:
        connection.close()

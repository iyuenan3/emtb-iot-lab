"""命令行入口。"""

import argparse
import asyncio
import logging
import os

from .backup import (
    create_encrypted_backup,
    decrypt_and_verify_backup,
    record_backup_audit,
    verify_decrypted_archive,
)
from .database import Database
from .service import RemoteService, run_servers


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="单车 IoT 远程调试服务")
    subcommands = root.add_subparsers(dest="command", required=True)
    serve = subcommands.add_parser("serve", help="运行 TCP 网关和 HTTP API")
    serve.add_argument("--db", required=True)
    serve.add_argument("--target-imei", required=True)
    serve.add_argument("--vehicle-name", default="测试山地车")
    serve.add_argument("--tcp-host", default="0.0.0.0")
    serve.add_argument("--tcp-port", type=int, default=19680)
    serve.add_argument("--http-host", default="127.0.0.1")
    serve.add_argument("--http-port", type=int, default=18081)
    serve.add_argument("--location-min-satellites", type=int, default=4)
    serve.add_argument("--location-max-hdop", type=float, default=8.0)
    serve.add_argument("--location-max-speed-mps", type=float, default=25.0)
    serve.add_argument("--offline-movement-threshold-m", type=float, default=200.0)
    serve.add_argument("--offline-sample-max-separation-m", type=float, default=75.0)
    pairing = subcommands.add_parser("pairing-code", help="生成十分钟有效的一次性配对码")
    pairing.add_argument("--db", required=True)
    pairing.add_argument("--ttl", type=int, default=600)
    backup = subcommands.add_parser("backup", help="创建 SQLite 加密恢复副本")
    backup.add_argument("--db", required=True)
    backup.add_argument("--recipient-cert", required=True)
    backup.add_argument("--output-dir", required=True)
    backup.add_argument("--openssl", default="/usr/bin/openssl")
    decrypt = subcommands.add_parser("decrypt-backup", help="解密并校验恢复副本")
    decrypt.add_argument("--input", required=True)
    decrypt.add_argument("--recipient-cert", required=True)
    decrypt.add_argument("--private-key", required=True)
    decrypt.add_argument("--output-db", required=True)
    decrypt.add_argument("--openssl", default="/usr/bin/openssl")
    verify = subcommands.add_parser("verify-backup", help="校验已解密的恢复归档")
    verify.add_argument("--archive", required=True)
    verify.add_argument("--output-db", required=True)
    return root


def main() -> None:
    arguments = parser().parse_args()
    if arguments.command == "backup":
        try:
            result = create_encrypted_backup(
                arguments.db, arguments.recipient_cert,
                arguments.output_dir, arguments.openssl,
            )
            record_backup_audit(arguments.db, "succeeded", result)
        except Exception:
            record_backup_audit(arguments.db, "failed")
            raise SystemExit("加密恢复副本创建失败")
        print(f"backup_created_at={result['created_at']}")
        print(f"cipher_sha256={result['cipher_sha256']}")
        return
    if arguments.command == "decrypt-backup":
        result = decrypt_and_verify_backup(
            arguments.input, arguments.recipient_cert, arguments.private_key,
            arguments.output_db, arguments.openssl,
        )
        print(f"backup_created_at={result['created_at']}")
        print("restore_verification=ok")
        return
    if arguments.command == "verify-backup":
        result = verify_decrypted_archive(arguments.archive, arguments.output_db)
        print(f"backup_created_at={result['created_at']}")
        print("restore_verification=ok")
        return
    database = Database(arguments.db)
    if arguments.command == "pairing-code":
        print(database.create_pairing_code(arguments.ttl))
        database.close()
        return
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    revision = os.environ.get("EMTB_IOT_REVISION", "dev").strip() or "dev"
    service = RemoteService(
        database, arguments.target_imei, arguments.vehicle_name, revision=revision,
        location_min_satellites=arguments.location_min_satellites,
        location_max_hdop=arguments.location_max_hdop,
        location_max_speed_mps=arguments.location_max_speed_mps,
        offline_movement_threshold_m=arguments.offline_movement_threshold_m,
        offline_sample_max_separation_m=arguments.offline_sample_max_separation_m,
    )
    try:
        asyncio.run(run_servers(
            service, arguments.tcp_host, arguments.tcp_port,
            arguments.http_host, arguments.http_port,
        ))
    finally:
        database.close()


if __name__ == "__main__":
    main()

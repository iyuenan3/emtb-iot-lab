"""命令行入口。"""

import argparse
import asyncio
import logging
import os

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
    pairing = subcommands.add_parser("pairing-code", help="生成十分钟有效的一次性配对码")
    pairing.add_argument("--db", required=True)
    pairing.add_argument("--ttl", type=int, default=600)
    return root


def main() -> None:
    arguments = parser().parse_args()
    database = Database(arguments.db)
    if arguments.command == "pairing-code":
        print(database.create_pairing_code(arguments.ttl))
        database.close()
        return
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    revision = os.environ.get("EMTB_IOT_REVISION", "dev").strip() or "dev"
    service = RemoteService(
        database, arguments.target_imei, arguments.vehicle_name, revision=revision
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

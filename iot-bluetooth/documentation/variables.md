# 变量与配置

文档只记录变量名称和用途，不保存真实密钥或短期凭据。

## iPhone App

| 配置 | 存储位置 | 说明 |
| --- | --- | --- |
| 设备密钥 | iOS Keychain | 8 个 ASCII 字节，用于 BLE 认证 |
| 维护密钥 | iOS Keychain | 4 个 ASCII 字节，用于维护能力 |
| 服务地址 | iOS Keychain | 必须为 HTTPS，目前使用 `/iot/` 路径 |
| 客户端编号 | iOS Keychain | 云端配对后返回 |
| 读取令牌 | iOS Keychain | 32 字节随机值，配对时生成 |
| 控制私钥 | Secure Enclave，引用存于 Keychain | P-256 签名密钥，不导出明文 |

固定目标设备的 IMEI、BLE MAC、广播名和 GATT UUID 定义在 `IoTBluetooth/Models.swift`。它们是当前单车调试配置，不是通用多设备目录。

## Mac 调试

| 变量 | 文件 | 说明 |
| --- | --- | --- |
| `BLE_KEY` | 工作区 `.env.local` | 命令行 BLE 探针使用，文件权限应为 `600` |

不要 `source .env.local`，工具应只解析需要的字段，不打印变量值。

## 远程服务

服务运行参数包括 SQLite 路径、目标 IMEI、TCP 端口和内部 HTTP 端口。生产部署以 systemd 单元为准。配对码是短期凭据，只在需要时即时生成，不写入文档。

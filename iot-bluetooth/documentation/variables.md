# 变量与配置

文档只记录变量名称和用途，不保存真实值。

## iPhone App

| 配置 | 存储位置 | 说明 |
| --- | --- | --- |
| 设备密钥 | iOS Keychain | 8 个 ASCII 字节，用于 BLE 认证 |
| `DEVICE_IMEI` | `Secrets.xcconfig` | 用于隔离该车辆的 Keychain 账户 |
| `DEVICE_BLE_MAC` | `Secrets.xcconfig` | 用于构造目标 BLE manufacturer data |
| `DEVELOPMENT_TEAM` | `Secrets.xcconfig` | 真机签名团队 |
| `PRODUCT_BUNDLE_IDENTIFIER` | `Secrets.xcconfig` | App Bundle ID |

NUS GATT UUID 固定定义在 `IoTBluetooth/Models.swift`。真实设备配置不得提交。

## Mac 调试

| 变量 | 文件 | 说明 |
| --- | --- | --- |
| `BLE_KEY` | 工作区 `.env.local` | 仅供 Mac 命令行 BLE 探针使用，文件权限应为 `600` |

不要 `source .env.local`。工具只应解析所需字段，禁止输出密钥值。iPhone App 不读取该文件。

## 已取消的 App 配置

Build 23 不使用远程服务地址、配对令牌、Secure Enclave 控制私钥、Face ID、维护密钥、服务器配置、APN 或 OTA 文件。

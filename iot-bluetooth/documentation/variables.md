# 变量与配置

文档只记录变量名称，不保存真实值。

## iPhone App

| 配置 | 存储位置 | 用途 |
| --- | --- | --- |
| 设备密钥 | iOS Keychain | 8 个 ASCII 字节，用于 `0x01` 认证 |
| 连接 Key | 仅内存 | 认证响应产生，只用于当前连接 |
| `DEVICE_BLE_MAC` | `Secrets.xcconfig` | 匹配目标 BLE manufacturer data |
| `DEVELOPMENT_TEAM` | `Secrets.xcconfig` | 真机签名团队 |
| `PRODUCT_BUNDLE_IDENTIFIER` | `Secrets.xcconfig` | App Bundle ID |

NUS UUID、帧规则和等待时间分别定义在 `BluetoothKeyController.swift`、`Shared/BikeWireProtocol.swift` 和 `Shared/BikeControlEngine.swift`。

## MacBook 工具

| 变量 | 文件 | 用途 |
| --- | --- | --- |
| `BLE_KEY` | 工作区 `.env.local` | 一次性 MacBook BLE 控制的设备密钥 |
| `DEVICE_BLE_MAC` | `Secrets.xcconfig` | 目标广播匹配 |

工具逐行解析需要的字段，不执行 `source .env.local`，也不输出密钥或完整设备标识。

Build 33 不使用 IMEI、远程服务地址、配对令牌、Face ID、维护密钥、服务器、APN 或 OTA 配置。

# eMTB IoT Lab

面向电助力山地车的非官方 IoT 研究与调试工具。项目将 iPhone 近场蓝牙、单车远程接入和 TCP 协议实验整合在一个仓库中，用于验证开关锁、声音找车、设备状态、定位和安全控制流程。

> 本项目只用于已获授权的自有硬件，不提供厂商密钥、固件、私有协议文档或生产服务凭据。

## 核心能力

- **近场 BLE**：使用 SwiftUI 和 CoreBluetooth 扫描指定设备，完成认证、状态读取、开关锁、声音找车及维护操作。无网络时仍可使用。
- **远程控制**：单车专用 Python 服务接收 IoT TCP 上报，并向 iPhone 提供状态、定位、找车及受保护的开关锁 API。
- **安全认证**：设备密钥保存在 iOS Keychain，远程控制使用 Secure Enclave P-256 签名、一次性配对码和随机数防重放。
- **协议实验**：独立 TCP 工具支持报文采集、脱敏日志和白名单内的一次性实车测试，不自动重试控制指令。
- **状态一致性**：已认证的 BLE 回读优先于远程缓存，App 会显示状态来源和更新时间。

## 项目结构

| 目录 | 技术 | 用途 |
| --- | --- | --- |
| `iot-bluetooth/` | SwiftUI、CoreBluetooth、MapKit | iPhone 现场调试与远程控制 App |
| `iot-remote/` | Python 3、asyncio、SQLite | 单车 TCP 接入、签名 HTTP API、状态与定位存储 |
| `iot-tcp-lab/` | Python 3、asyncio | 隔离的协议采集与一次性命令验证 |

## 快速开始

### iPhone App

1. 将 `iot-bluetooth/Secrets.xcconfig.example` 复制为 `Secrets.xcconfig`。
2. 填入自己的设备标识、BLE MAC、开发团队和 Bundle ID。该文件已被 Git 忽略。
3. 使用 Xcode 打开 `iot-bluetooth/IoTBluetooth.xcodeproj`。
4. 选择个人开发团队和真实 iPhone，然后运行安装。模拟器无法连接真实 BLE 设备。
5. 在 App 的“更多 > 密钥与日志”中保存 8 字节设备密钥。

更完整的安装、功能和实车边界见 [蓝牙工具说明](iot-bluetooth/README.md)。

### 远程服务

```bash
cd iot-remote
cp .env.example .env
python3 -m iot_remote pairing-code --db var/iot.sqlite3
python3 -m iot_remote serve \
  --db var/iot.sqlite3 \
  --target-imei '<目标 IMEI>' \
  --tcp-port 19680 \
  --http-port 18081
```

HTTP 默认只监听本机回环地址，公网使用时必须通过 HTTPS 反向代理。部署细节见 [远程服务说明](iot-remote/README.md)。

### TCP 实验工具

```bash
cd iot-tcp-lab
python3 server.py \
  --host 127.0.0.1 \
  --port 19680 \
  --target-imei '<目标 IMEI>' \
  --log-dir ./runtime/logs
```

任何下行测试都应先核对目标设备和现场状态。允许的白名单参数见 [TCP 实验说明](iot-tcp-lab/README.md)。

## 验证

```bash
cd iot-remote
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v

cd ../iot-tcp-lab
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v
```

当前代码基线包含 77 项远程服务测试和 16 项 TCP 工具测试。Build 17 已通过无签名与签名真机目标编译，并完成真机安装、版本读回和系统启动；线上服务在本轮累计部署前仍为 revision `05043e0`。代码存在或 App 能启动不等于所有硬件能力均已实车验收，具体状态见 [实现状态](iot-bluetooth/IMPLEMENTATION-STATUS.md)。

## 安全与隐私

- 不得提交 IMEI、蓝牙 MAC、SIM 标识、精确位置、密钥、令牌、数据库或现场日志。
- App 导出的 BLE 日志和设备快照会遮罩设备、位置及基础设施标识。
- TCP 工具使用会话级指纹替代原始设备标识和客户端地址，并遮罩定位与敏感控制字段。
- 开锁、关锁、服务器配置、APN 和 OTA 只能针对明确授权的设备执行，并需要现场确认和回滚方案。

发现安全问题时，请按 [安全政策](SECURITY.md) 私密报告，不要在公开 Issue 中附带设备报文或利用细节。

## 文档

- [App 架构](iot-bluetooth/documentation/architecture.md)
- [关键流程](iot-bluetooth/documentation/flows.md)
- [权限与安全](iot-bluetooth/documentation/permissions.md)
- [远程控制需求](iot-bluetooth/REMOTE-CONTROL-REQUIREMENTS.md)
- [API 设计](iot-bluetooth/API-DESIGN.md)
- [数据模型](iot-bluetooth/DATA-MODEL.md)
- [贡献指南](AGENTS.md)

## 项目声明

这是面向自有硬件的独立研究项目，与任何设备制造商、平台运营方或通信服务商均无隶属或认可关系。产品名称和商标归各自权利人所有。

## 许可证

本项目以 [Apache License 2.0](LICENSE) 发布。第三方名称和商标不在该许可授权范围内，具体声明见 [NOTICE](NOTICE)。

# eMTB IoT Lab

面向电助力山地车的非官方 IoT 研究与调试工具。当前 iPhone App 已收缩为纯蓝牙车钥匙，远程服务和 TCP 实验代码作为独立研究模块保留在同一仓库。

> 本项目只用于已获授权的自有硬件，不提供厂商密钥、固件、私有协议文档或生产服务凭据。

## 核心能力

- **近场 BLE App**：使用 SwiftUI 和 CoreBluetooth 手动连接指定设备，每次连接只执行一次受保护的开锁或关锁，完成必要回执后立即断开。
- **远程服务研究**：单车专用 Python 服务保留 TCP 上报、状态、定位和受保护 API，但 Build 22 App 不连接该服务。
- **本机安全**：设备密钥保存在 iOS Keychain，开锁和关锁只由 1.2 秒长按触发，不再调用 Face ID。
- **协议实验**：独立 TCP 工具支持报文采集、脱敏日志和白名单内的一次性实车测试，不自动重试控制指令。
- **物理结果优先**：App 不自动读取或推断锁态，用户以仪表、动力和轮毂锁的实际状态作为最终结果。

## 项目结构

| 目录 | 技术 | 用途 |
| --- | --- | --- |
| `iot-bluetooth/` | SwiftUI、CoreBluetooth | 纯蓝牙 iPhone 车钥匙 App |
| `iot-remote/` | Python 3、asyncio、SQLite | 单车 TCP 接入、签名 HTTP API、状态与定位存储 |
| `iot-tcp-lab/` | Python 3、asyncio | 隔离的协议采集与一次性命令验证 |

## 快速开始

### iPhone App

1. 将 `iot-bluetooth/Secrets.xcconfig.example` 复制为 `Secrets.xcconfig`。
2. 填入自己的设备标识、BLE MAC、开发团队和 Bundle ID。该文件已被 Git 忽略。
3. 使用 Xcode 打开 `iot-bluetooth/IoTBluetooth.xcodeproj`。
4. 选择个人开发团队和真实 iPhone，然后运行安装。模拟器无法连接真实 BLE 设备。
5. 在 App 右上角“密钥”中保存 8 字节设备密钥。

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

Build 21 安装后，用户现场反馈开锁和关锁均未产生车辆动作。Build 22 已移除 Face ID 异步授权路径，增加可分享的脱敏控制链诊断，并完成签名构建、覆盖安装和 Build 22 读回；App 尚未启动，也没有发送车辆指令。远程控制、自动状态读取、自动重连、BLE 事件上传和维护能力仍未进入 App。线上服务 revision `469f154b75bb243e61cd1dd3f291fde0256bb7bb` 保持原状，本轮没有重新部署。具体边界见 [实现状态](iot-bluetooth/IMPLEMENTATION-STATUS.md)。

## 安全与隐私

- 不得提交 IMEI、蓝牙 MAC、SIM 标识、精确位置、密钥、令牌、数据库或现场日志。
- Build 22 的可分享诊断不保存密钥、完整设备标识、位置或服务器信息。
- TCP 工具使用会话级指纹替代原始设备标识和客户端地址，并遮罩定位与敏感控制字段。
- 开锁和关锁只能针对明确授权的设备执行，并需要现场确认车辆物理状态。

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

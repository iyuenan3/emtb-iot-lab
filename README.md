# eMTB IoT Lab

面向电助力山地车的非官方 IoT 研究与调试工具。当前产品是 Build 26 纯蓝牙 iPhone 工具。远程服务已退役，代码只作为历史研究材料保留；TCP 实验工具仅用于受控维护。

> 本项目只用于已获授权的自有硬件，不提供厂商密钥、固件、私有协议文档或生产服务凭据。

## 核心能力

- **近场 BLE App**：使用 SwiftUI 和 CoreBluetooth 手动连接指定设备，同一认证连接内可以连续读取和操作，不为每次动作重新连接。
- **实车验证范围**：开放主锁、车辆信息和旧骑行数据；实车不可靠的设置和外部锁命令没有生产入口。
- **本机安全**：设备密钥保存在 iOS Keychain，开锁和关锁只由 1.2 秒长按触发，不再调用 Face ID。
- **协议实验**：独立 TCP 工具支持报文采集、脱敏日志和白名单内的一次性实车测试，不自动重试控制指令。
- **物理结果优先**：App 会读取协议状态，但不会把回包等同于机械结果，用户仍以仪表、动力和锁具的实际状态作为最终结果。

## 项目结构

| 目录 | 技术 | 用途 |
| --- | --- | --- |
| `iot-bluetooth/` | SwiftUI、CoreBluetooth | 纯蓝牙 iPhone 车钥匙 App |
| `iot-remote/` | Python 3、asyncio、SQLite | 已退役的远程服务历史实现，不在线运行 |
| `iot-tcp-lab/` | Python 3、asyncio | 隔离的协议采集与一次性命令验证 |

## 快速开始

### iPhone App

1. 将 `iot-bluetooth/Secrets.xcconfig.example` 复制为 `Secrets.xcconfig`。
2. 填入自己的设备标识、BLE MAC、开发团队和 Bundle ID。该文件已被 Git 忽略。
3. 使用 Xcode 打开 `iot-bluetooth/IoTBluetooth.xcodeproj`。
4. 选择个人开发团队和真实 iPhone，然后运行安装。模拟器无法连接真实 BLE 设备。
5. 在 App 右上角“密钥”中保存 8 字节设备密钥。

更完整的安装、功能和实车边界见 [蓝牙工具说明](iot-bluetooth/README.md)。

### 历史远程服务

远程服务已于 2026 年 8 月 23 日停止。服务器上的程序、数据、脚本、发布目录、旧名目录和历史备份均已按授权永久删除，公网路由也已移除。仓库中的 `iot-remote/` 仅供历史审计，不代表存在可用部署，不得在没有新的明确授权时恢复。

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

Build 24 用于完成常连接和 V1.2.5 实车验收。用户已确认同一连接内连续开锁和关锁，中途没有断开；Mac 探针完成认证、`0x31`、`0x60`、`0x51` 和 `0x52` 验收。`0x61` 回包与实际状态不一致，`0x62` 和三类 `0x81` 查询无回包，因此 Build 25 移除了这些不可靠入口。Build 26 在不改变 BLE 范围的前提下重新设计了连接、控制、车辆状态和数据记录界面。最终车辆已通过干净主锁复位恢复为仪表熄灭、动力断开、轮毂锁锁住。完整证据见 [实现状态](iot-bluetooth/IMPLEMENTATION-STATUS.md)。

## 安全与隐私

- 不得提交 IMEI、蓝牙 MAC、SIM 标识、精确位置、密钥、令牌、数据库或现场日志。
- Build 26 的可分享诊断不保存密钥、完整设备标识、旧骑行用户 ID、位置或服务器信息。
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

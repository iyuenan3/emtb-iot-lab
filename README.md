# eMTB 蓝牙车钥匙

当前仓库只维护两项能力：

- Build 33 纯蓝牙 iPhone 车钥匙。
- MacBook 一次性蓝牙开锁、关锁工具。

两端共用同一套 BLE 帧实现和控制状态机。App 不访问网络，不使用 Face ID，不提供远程服务、定位、车辆遥测、诊断或轮毂锁功能。

> 本项目只用于已获授权的自有硬件。不要提交设备密钥、蓝牙 MAC、签名凭据、日志或设备标识。

## 目录

| 路径 | 用途 |
| --- | --- |
| `iot-bluetooth/IoTBluetooth/` | Build 33 iPhone App |
| `iot-bluetooth/Shared/` | iPhone 与 MacBook 共用的协议和控制状态机 |
| `iot-bluetooth/tools/emtb_ble_control.swift` | MacBook 一次性 BLE 控制工具 |
| `iot-bluetooth/tests/` | 当前协议、状态机、App 边界和 Mac 工具测试 |
| `iot-bluetooth/documentation/` | 当前 BLE 架构、流程、安全和验收说明 |
| `archive/` | 本机历史资料，不进入 Git |

## iPhone Build 33

1. 将 `iot-bluetooth/Secrets.xcconfig.example` 复制为 `iot-bluetooth/Secrets.xcconfig`。
2. 填写目标 BLE MAC、开发团队和 Bundle ID。
3. 用 Xcode 打开 `iot-bluetooth/IoTBluetooth.xcodeproj` 并安装到真实 iPhone。
4. 首次打开 App，在右上角保存 8 字节 ASCII 蓝牙密钥。

Build 33 每次长按只执行一次开锁或关锁。认证、会话初始化、控制和必要回执完成后，App 主动断开蓝牙，不自动重连或重试。

## MacBook BLE 工具

工具从仓库根目录 `.env.local` 读取 `BLE_KEY`，从 `iot-bluetooth/Secrets.xcconfig` 读取 `DEVICE_BLE_MAC`。它不会打印密钥或完整设备标识。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swiftc \
  -module-cache-path /tmp/emtb-ble-control-module-cache \
  iot-bluetooth/Shared/BikeWireProtocol.swift \
  iot-bluetooth/Shared/BikeControlEngine.swift \
  iot-bluetooth/tools/emtb_ble_control.swift \
  -o /tmp/emtb-ble-control

/tmp/emtb-ble-control lock --physical-ready
```

将 `lock` 换成 `unlock` 可执行开锁。发送实车指令前必须确保车辆静止、现场安全，并确认手机没有占用 IoT 蓝牙连接。

## 验证

```bash
cd iot-bluetooth
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project IoTBluetooth.xcodeproj \
  -scheme IoTBluetooth \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

自动测试和编译不能替代实车结果。开锁后应确认仪表稳定常亮且晃动无蜂鸣，关锁后应确认仪表熄灭且晃动有蜂鸣。

详细说明见 [iot-bluetooth/README.md](iot-bluetooth/README.md)。

## 许可证

本项目以 [Apache License 2.0](LICENSE) 发布，第三方名称和商标声明见 [NOTICE](NOTICE)。

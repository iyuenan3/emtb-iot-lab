# App 架构

## 产品边界

Build 22 是单车、单用户、纯 BLE 的 iPhone 车钥匙。App 不访问网络，不保存服务器凭据，不展示远程状态，不自动读取车辆状态，也不调用 Face ID。

## 当前构建目标

| 代码 | 职责 |
| --- | --- |
| `IoTBluetoothApp.swift` | 创建唯一的 BLE 状态管理器 |
| `ContentView.swift` | 单页连接、开锁、关锁、结果与密钥界面 |
| `BLEDeviceManager.swift` | 手动扫描、认证、单次控制、回执和主动断开 |
| `OmniProtocol.swift` | 最小命令白名单、CRC8、帧编码和解码 |
| `Models.swift` | 连接阶段、控制动作、结果和设备配置 |
| `KeychainStore.swift` | 设备密钥的本机 Keychain 存储与旧值迁移 |

`RemoteControlManager.swift`、`RemoteControlView.swift` 和 `PendingBLEEventStore.swift` 仍保留在 Git 历史和工作树中，但不在 Xcode Target 中，不会编译进 App。控制链诊断只包含脱敏事件，可由用户主动分享。

## 数据流

```text
用户手动连接
    ↓
指定 BLE 广播与 NUS 服务
    ↓
设备密钥认证
    ↓
一次开锁或关锁
    ↓
设备协议结果
    ↓
必要回执
    ↓
App 主动断开
    ↓
用户检查车辆物理状态
```

## 不变量

- 认证成功后不发送状态读取或维护命令。
- 一个连接最多发送一个控制请求。
- 控制结果完成前不允许第二次操作。
- 控制流程结束后主动断开，不自动重连。
- 协议结果只表示设备已接收或拒绝，不能替代物理状态确认。

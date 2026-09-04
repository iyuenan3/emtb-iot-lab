# App 架构

## 产品边界

Build 33 是单车、单用户、纯 BLE 的 iPhone 车钥匙。App 不访问网络，不调用 Face ID。用户可见的车辆功能只有开锁和关锁。

## 当前构建目标

| 文件 | 职责 |
| --- | --- |
| `BikeKeyApp.swift` | 创建唯一控制器并装配单页界面 |
| `BikeKeyView.swift` | 两个长按按钮、操作状态、物理检查和密钥录入 |
| `BluetoothKeyController.swift` | CoreBluetooth 扫描、连接、超时、断开和状态发布 |
| `SecureKeyStore.swift` | 全新的本机 Keychain 存储 |
| `Shared/BikeWireProtocol.swift` | 帧编码、解码、CRC8 和大端整数 |
| `Shared/BikeControlEngine.swift` | 开锁与关锁共用的纯状态机 |

以上六个文件是 Xcode Target 的全部 Swift 源码。旧 App 文件已删除，不再作为隐藏备用实现保留。

## 分层

```text
长按开锁或关锁
        ↓
BikeKeyView
        ↓
BluetoothKeyController
        ↓
BikeControlEngine
        ↓
BikeWireProtocol
        ↓
CoreBluetooth NUS
```

状态机不知道 iOS 界面或 CoreBluetooth，Controller 只负责把通知、写回调和定时器事件送入状态机。MacBook 工具使用同一状态机和协议模块，因此步骤、载荷和等待时间不会分别维护。

## 不变量

- 每次长按只固定一个动作并建立一个连接。
- 一个连接只认证一次，连接 Key 不跨连接保存。
- 所有请求串行，前一步写回调和业务响应齐备后才推进。
- 控制帧只发送一次，不自动重试或补发反向动作。
- 必要回执写入后等待 800 毫秒再主动断开。
- 提前断开且控制尚未发送时显示“未发送”，已发送时显示“结果未知”。
- 协议接受不等于车辆物理成功。

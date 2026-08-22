# 测试策略

## 自动化证据

| 范围 | 命令 | 当前结果 |
| --- | --- | --- |
| iOS 源码守卫 | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v` | 7 项通过 |
| iOS 无签名编译 | `xcodebuild -project IoTBluetooth.xcodeproj -scheme IoTBluetooth -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | Build 21 通过 |

源码守卫固定以下边界：

- Xcode Target 不包含远程管理器、远程页面和 BLE 事件队列。
- 协议命令白名单只有认证、开锁、错误和关锁。
- 活跃 BLE 代码不含 `0x31`、`0x60`、`0xFA`、自动刷新或自动重连。
- 每个连接只允许一次控制，必要回执写入完成后主动断开。
- 开关锁要求设备所有者验证。
- 界面不显示“开锁成功”或“关锁成功”。

## 自动化不能证明

- iPhone 是否能发现并认证真实车辆 IoT。
- Face ID 文案、取消和通过后的真实交互。
- 设备是否只执行一次命令。
- 仪表、动力和轮毂锁是否到达正确物理状态。
- 主动断开后仪表是否保持稳定，不再出现重启循环。

## 人工验收顺序

1. 签名编译并安装 Build 21，确认版本读回。
2. 只连接和认证，不按控制按钮，再手动断开，观察至少 15 秒。
3. 新连接中只执行一次开锁，等待 App 主动断开，再观察至少 15 秒。
4. 车辆完全静止后，新连接中只执行一次关锁，等待 App 主动断开，再观察至少 15 秒。
5. 每一步分别记录 App 诊断、仪表、动力和轮毂锁结果。

任一步发生仪表重启、动作反向或状态不一致，应立即关闭手机蓝牙并停止后续步骤。

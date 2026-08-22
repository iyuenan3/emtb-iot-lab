# 测试策略

## 自动化证据

| 范围 | 命令 | 当前结果 |
| --- | --- | --- |
| 生产会话状态机 | Python 测试调用 `swiftc` 编译并运行生产 `BLEControlSession` 与 Swift Harness | Build 23 覆盖两种回调顺序、单连接单动作、重复和反向结果 |
| iOS 源码守卫 | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v` | Build 23 共 10 项，包括 1 项生产状态机测试 |
| iOS 无签名编译 | `xcodebuild -project IoTBluetooth.xcodeproj -scheme IoTBluetooth -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | Build 23 通过 |
| iOS 签名与安装 | 签名 `xcodebuild`、`codesign --verify`、`devicectl device install app`、安装版本读回 | Build 23 通过，设备读回 `1.0 (23)`；未启动 App |

源码守卫固定以下边界：

- Xcode Target 不包含远程管理器、远程页面和 BLE 事件队列。
- 协议命令白名单只有认证、开锁、错误和关锁。
- 活跃 BLE 代码只恢复 `0x31` 主锁读取，不含 `0x60`、`0xFA`、系统信息、维护读取或自动重连。
- 每个连接只允许一次控制，必要回执后回读主锁并主动断开。
- 控制状态机不包含 `pendingWrite` 或 `WritePurpose`，两种认证回调顺序都能开放控制。
- 活跃 App 不包含 LocalAuthentication、Face ID 权限或设备所有者验证调用。
- 控制链脱敏诊断可以由用户分享。
- 界面不显示“开锁成功”或“关锁成功”。

## 自动化不能证明

- iPhone 是否能发现并认证真实车辆 IoT。
- 设备是否只执行一次命令。
- 仪表、动力和轮毂锁是否到达正确物理状态。
- 主动断开后仪表是否保持稳定，不再出现重启循环。

## 人工验收顺序

1. 打开已经读回为 Build 23 的 App，检查页面和诊断分享入口。
2. 只连接和认证，确认显示的锁态与车辆一致，不按控制按钮，再手动断开，观察至少 15 秒。
3. 新连接中只执行一次开锁，等待 App 主动断开，再观察至少 15 秒。
4. 车辆完全静止后，新连接中只执行一次关锁，等待 App 主动断开，再观察至少 15 秒。
5. 每一步分别记录 App 诊断、仪表、动力和轮毂锁结果。

任一步发生仪表重启、动作反向或状态不一致，应立即关闭手机蓝牙并停止后续步骤。

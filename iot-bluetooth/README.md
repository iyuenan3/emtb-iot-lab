# eMTB 蓝牙钥匙

这是一个面向自有车辆的最小化 iPhone App。Build 23 只保留附近蓝牙连接、锁态读取、开锁和关锁，不访问网络，也不包含远程控制和维护功能。控制链恢复自早期 Build 2 的直接写入方式，不再等待 BLE 写入完成回调后才开放按钮或推进协议。

## 当前行为

1. 用户手动连接指定车辆 IoT。
2. App 完成 BLE 服务发现和设备密钥认证后，只读取一次 `0x31` 主锁状态，不读取电量、骑行或系统信息。
3. 用户长按开锁或关锁 1.2 秒，App 直接发送一次对应请求，不调用 Face ID。当前锁态与请求一致时，不发送重复控制。
4. 每次连接只允许一个控制动作。
5. 收到设备协议结果后，App 立即发送必要回执，等待 0.8 秒，再回读一次锁态。
6. 设备结果与锁态回读一致、被拒绝或不一致后，App 主动断开。
7. 协议状态不能替代物理验收，用户仍需检查仪表、动力和轮毂锁。

App 不会自动重连、自动刷新、自动重试、反向补发、上传事件或切换远程通道。

## 安装

1. 复制 `Secrets.xcconfig.example` 为被 Git 忽略的 `Secrets.xcconfig`。
2. 填写目标设备 IMEI、BLE MAC、开发团队和 Bundle ID。真实值不得提交。
3. 使用 Xcode 打开 `IoTBluetooth.xcodeproj`。
4. 选择个人开发团队和真实 iPhone，运行安装。模拟器不能连接真实 BLE 设备。
5. 首次启动后，在右上角“密钥”中保存 8 字节 ASCII 设备密钥。

工作区 `.env.local` 中的 `BLE_KEY` 只供 Mac 命令行探针使用。iPhone App 无法读取该文件，设备密钥仍只保存在 iOS Keychain。

## 验证

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project IoTBluetooth.xcodeproj \
  -scheme IoTBluetooth \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

自动测试会编译并运行实际生产 `BLEControlSession`，覆盖认证通知先于或晚于写入完成回调的两种顺序。源码守卫同时检查最小命令白名单、单连接单动作、回执后锁态回读、Face ID 代码已移除、脱敏诊断可分享，以及远程代码未进入构建目标。编译通过不代表真实车辆动作已验收。

## 实车验收边界

Build 21 和 Build 22 已确认能够认证设备，但控制按钮受新增写入状态门限制，未产生车辆动作。Build 23 删除该门禁并恢复早期直接写入、协议回执和锁态回读链路。首次打开后必须分步验收：先只连接并确认锁态回读正确，再单独验证一次开锁，最后从新的连接单独验证一次关锁。任一步出现仪表重启、动作反向或物理状态不一致，应立即关闭手机蓝牙并停止测试。

详细边界见 [实现状态](IMPLEMENTATION-STATUS.md)、[架构](documentation/architecture.md)、[关键流程](documentation/flows.md)、[权限与安全](documentation/permissions.md)和[测试策略](documentation/tests.md)。

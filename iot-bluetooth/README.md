# eMTB 蓝牙钥匙

这是一个面向自有车辆的最小化 iPhone App。Build 22 只保留附近蓝牙连接、开锁和关锁，不访问网络，不读取或推断车辆锁态，也不包含远程控制和维护功能。

## 当前行为

1. 用户手动连接指定车辆 IoT。
2. App 只完成 BLE 服务发现和设备密钥认证，不自动读取锁态、电量、骑行或系统信息。
3. 用户长按开锁或关锁 1.2 秒，App 直接发送一次对应请求，不调用 Face ID。
4. 每次连接只允许一个控制动作。
5. 收到设备协议结果后，App 发送必要回执并立即主动断开。
6. App 只显示“设备已接收”或“结果未知”，物理结果始终由用户检查仪表、动力和轮毂锁确认。

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

源码守卫检查最小命令白名单、单连接单动作、必要回执后断开、Face ID 代码已移除、脱敏诊断可分享，以及远程代码未进入构建目标。编译通过不代表真实车辆动作已验收。

## 实车验收边界

Build 21 安装后，用户现场反馈开锁和关锁均未产生车辆动作。Build 22 已移除身份验证异步路径，在“诊断记录”中增加“分享脱敏诊断”，并完成签名构建、覆盖安装和版本读回。App 尚未启动。首次打开后必须分步验收：先只连接和断开，确认仪表不重启；再单独验证一次开锁；最后从新的连接单独验证一次关锁。任一步出现仪表重启、状态反向或物理状态不一致，应立即关闭 App 蓝牙并停止测试。

详细边界见 [实现状态](IMPLEMENTATION-STATUS.md)、[架构](documentation/architecture.md)、[关键流程](documentation/flows.md)、[权限与安全](documentation/permissions.md)和[测试策略](documentation/tests.md)。

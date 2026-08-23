# eMTB 蓝牙工具

Build 25 是面向自有车辆的纯蓝牙 iPhone App。它不访问网络，不包含远程控制和 Face ID，只开放已经在本车上完成实车验证的 BLE 功能。

## 当前功能

- 手动扫描、连接和设备密钥认证，连接 Key 在当前 BLE 会话中持续复用。
- 主锁状态、电压、固件版本和旧数据标志读取。
- 长按开锁与关锁，收到设备结果后发送必要回执，再回读主锁和车辆状态。
- 电量、骑行模式、速度、本次里程和剩余里程读取。
- 上一笔骑行数据读取、主动分享和确认后清除。
- 进程内脱敏诊断分享。

认证成功后 App 会保持 BLE 连接，一次操作完成后可以继续查询或执行下一项操作。App 不会自动连接、自动重连、自动重试、反向补发、上传事件或切换远程通道。

## 已停用的文档功能

V1.2.5 文档还列出了 `0x61` 设置、`0x62` 高级设置和 `0x81` 外部锁。实车验收发现：

- `0x61` 在锁车和开锁通电状态下都返回成功，但 `0x60` 回读模式没有变化。
- `0x62` 在锁车状态下无回包。
- 电池锁、车轮锁和钢缆锁三项 `0x81` 查询均无回包。
- 一轮设置验收后曾出现逻辑已关锁、轮毂锁已锁、仪表仍亮的异常状态，随后通过一次不含设置的干净主锁复位循环恢复正常。

因此 Build 25 移除了这些功能的界面和主动发送入口。协议编号与载荷模型只保留为审计参考，不能把设备文档等同于本车可用能力。

## 安全边界

- 主锁开关必须长按 1.2 秒，并依据当前主锁状态阻止重复动作。
- 旧数据清除必须先读取，再由用户确认。设备确认清除后无法恢复。
- 写操作超时、连接中断、写入失败或状态回读不一致时，结果视为未知，App 会断开蓝牙且不重试。
- 仪表与车辆动力绑定。仪表亮表示车辆有动力，仪表灭表示车辆无动力。
- 协议回包不能替代物理验收。主锁操作后必须检查仪表、动力和轮毂锁。
- 轮毂锁只随主锁流程联动，不使用 `0x81` 独立控制。

完整实车结论见 [实现状态](IMPLEMENTATION-STATUS.md)和[BLE V1.2.5 功能清单](documentation/protocol-v1.2.5.md)。

## 安装

1. 复制 `Secrets.xcconfig.example` 为被 Git 忽略的 `Secrets.xcconfig`。
2. 填写目标设备 IMEI、BLE MAC、开发团队和 Bundle ID。真实值不得提交。
3. 使用 Xcode 打开 `IoTBluetooth.xcodeproj`。
4. 选择个人开发团队和真实 iPhone，运行安装。模拟器不能连接真实 BLE 设备。
5. 首次启动后，在车钥匙页右上角“密钥”中保存 8 字节 ASCII 设备密钥。

工作区 `.env.local` 中的 `BLE_KEY` 只供 Mac 命令行探针使用。iPhone App 无法读取该文件，设备密钥只保存在 iOS Keychain。

## 验证

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project IoTBluetooth.xcodeproj \
  -scheme IoTBluetooth \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

自动测试编译生产 `BLEControlSession`、协议和模型，检查常连接、回执、回读、危险命令无生产入口、Face ID 移除、脱敏诊断和远程代码未进入构建目标。编译通过不能替代实车物理验收。

详细边界见 [架构](documentation/architecture.md)、[关键流程](documentation/flows.md)、[权限与安全](documentation/permissions.md)和[测试策略](documentation/tests.md)。

# eMTB 蓝牙工具

Build 24 是面向自有车辆的纯蓝牙 iPhone App。它不访问网络，不包含远程控制和 Face ID，完整实现《欧米滑板车 IoT 设备接口协议（内置 IoT 版）V1.2.5 云途》正式列出的 11 条 BLE 命令。

## 当前功能

- 手动扫描、连接和设备密钥认证，连接 Key 在当前 BLE 会话中持续复用。
- 主锁状态、电压、固件版本和旧数据标志读取。
- 长按开锁与关锁，收到设备结果后发送必要回执，再回读主锁和车辆状态。
- 电量、骑行模式、速度、本次里程和剩余里程读取。
- 前灯、骑行模式、油门和尾灯设置。
- 掉电保存、定速巡航、启动方式和三档限速设置。
- 上一笔骑行数据读取、主动分享和确认后清除。
- 电池锁、车轮锁和钢缆锁的状态查询、解锁与上锁。
- 进程内脱敏诊断分享。

认证成功后 App 会保持 BLE 连接。一次操作完成后可以继续查询或执行下一项操作，不再为了每次开关锁重新扫描和认证。App 不会自动连接、自动重连、自动重试、反向补发、上传事件或切换远程通道。

## 安全边界

- 主锁开关必须长按 1.2 秒，并依据当前主锁状态阻止重复动作。
- 基础设置、高级设置、旧数据清除和外部锁写操作都需要用户确认。
- 写操作超时、连接中断、写入失败或状态回读不一致时，结果视为未知，App 会断开蓝牙且不重试。
- 协议回包不能替代物理验收。主锁和外部锁操作后仍需检查仪表、动力、轮毂锁和对应机械锁。
- 归档工具中存在但 V1.2.5 文档未正式列出的系统信息、日志、RFID、电源、服务器、APN 和 OTA 命令不进入当前 App。

完整命令矩阵见 [BLE V1.2.5 功能清单](documentation/protocol-v1.2.5.md)。

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

自动测试编译并运行生产 `BLEControlSession`，覆盖两种认证回调顺序、同一连接连续操作、大端解析、设置载荷和外部锁操作码。源码守卫检查 11 条命令白名单、常连接规则、危险写操作确认、Face ID 移除、脱敏诊断和远程代码未进入构建目标。编译通过不代表新增功能已经完成实车验收。

## 实车验收边界

Build 23 的开锁和关锁直接控制链已经由用户实车测试通过。Build 24 新增常连接、多功能读取和设置能力，仍需逐项人工验收。建议先连接并核对只读信息，再在车辆完全静止时分别测试基础设置、旧数据和外部锁。任何一步出现仪表重启、动作反向、状态不一致或设备无回包，应立即关闭手机蓝牙并停止后续写操作。

详细边界见 [实现状态](IMPLEMENTATION-STATUS.md)、[架构](documentation/architecture.md)、[关键流程](documentation/flows.md)、[权限与安全](documentation/permissions.md)和[测试策略](documentation/tests.md)。

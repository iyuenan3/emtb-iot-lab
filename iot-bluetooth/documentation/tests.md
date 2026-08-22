# 测试策略

## 自动化证据

| 范围 | 命令 | Build 24 当前结果 |
| --- | --- | --- |
| 生产会话与协议模型 | Python 测试调用 `swiftc` 编译生产 `BLEControlSession`、协议和模型，再运行 Swift Harness | 通过，覆盖两种回调顺序、同连接连续动作、大端解析、设置载荷和外部锁操作码 |
| iOS 源码守卫 | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v` | 13 项通过 |
| iOS 无签名编译 | `xcodebuild -project IoTBluetooth.xcodeproj -scheme IoTBluetooth -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | 通过 |
| iOS 签名与安装 | 签名 `xcodebuild`、`codesign --verify`、`devicectl device install app`、安装版本读回 | 通过，设备读回 `1.0 (24)`，未启动 App |

源码守卫固定以下边界：

- Xcode Target 不包含远程管理器、远程页面和 BLE 事件队列。
- 协议白名单严格等于 V1.2.5 文档的 11 条 BLE 命令。
- 系统信息、日志、RFID、电源、服务器、APN、OTA 和归档扩展设备码不进入当前协议层。
- 同一认证连接允许连续操作，但同一时刻只允许一个协议操作。
- 主锁必要回执后回读主锁和车辆状态，成功一致时保持连接。
- 写操作的未知结果会断开，App 不自动重连或重试。
- 基础设置、高级设置、旧数据清除和外部锁写操作都有用户确认。
- 活跃 App 不包含 LocalAuthentication、Face ID 权限或设备所有者验证调用。
- 旧骑行用户 ID 不进入脱敏诊断。
- 界面不显示“开锁成功”或“关锁成功”。

## 自动化不能证明

- iPhone 是否能发现并持续连接真实车辆 IoT。
- 设备对 `0x51`、`0x52`、`0x60`、`0x61`、`0x62`、`0x81` 的实际固件行为。
- 电量、速度、里程、锁电压和固件版本的现场数值是否准确。
- 设置是否真实生效，掉电保存是否符合选择。
- 仪表、动力、轮毂锁和外部机械锁是否达到正确物理状态。
- 连续操作后仪表是否稳定，不再出现重启循环。

## 人工验收

人工验收以 [关键流程](flows.md) 的顺序为准。新增功能第一次测试时，每次只改变一个变量，等待车辆稳定并记录 App 诊断、设备回包和物理结果。任何异常都先关闭手机蓝牙，不进行自动或连续重试。

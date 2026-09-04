# eMTB 蓝牙钥匙

Build 33 是从空白实现的纯蓝牙 iPhone 车钥匙。旧 App Swift 源码已从工作树和 Xcode Target 删除，新实现没有复制或调用旧 App 代码。用户可见的车辆功能只有开锁和关锁。

Build 33 已在目标 iPhone 完成开锁和关锁实车闭环验收。开锁后仪表稳定常亮、晃动无蜂鸣；关锁后仪表熄灭、晃动有蜂鸣；两次操作均在回执后自动断开蓝牙。

## 功能

- 长按 1.2 秒选择一次开锁或关锁。
- 自动扫描指定车辆、连接 NUS 服务并用 8 字节设备密钥认证。
- 按固定顺序完成 `0x31`、`0x60` 会话初始化。
- 静默 1 秒后发送一次 `0x05` 开锁或 `0x15` 关锁。
- 收到控制结果并完成 GATT 写回调后，发送同命令 `0x02` 回执。
- 回执写入后静默 800 毫秒，主动断开蓝牙。

App 不访问网络，不使用 Face ID，不读取或展示车辆数据，不提供远程控制、设置、旧骑行数据、诊断、外部锁或轮毂锁入口，也不会自动重连或重试控制。

## 代码边界

生产 Target 只编译六个 Swift 文件：

- `BikeKeyApp.swift`
- `BikeKeyView.swift`
- `BluetoothKeyController.swift`
- `SecureKeyStore.swift`
- `Shared/BikeControlEngine.swift`
- `Shared/BikeWireProtocol.swift`

MacBook 工具和 iPhone App 共用 `Shared` 中的协议编码与控制状态机，避免两端再次出现步骤、载荷或等待时间漂移。

## 安装前配置

1. 将 `Secrets.xcconfig.example` 复制为被 Git 忽略的 `Secrets.xcconfig`。
2. 设置 `DEVICE_BLE_MAC`、开发团队和 Bundle ID。
3. 用 Xcode 打开 `IoTBluetooth.xcodeproj`，选择真实 iPhone。
4. 安装后首次打开 App，在右上角“密钥”中保存 8 字节 ASCII 设备密钥。

Build 33 使用新的 Keychain 服务，不迁移旧 App 保存的值。工作区 `.env.local` 中的 `BLE_KEY` 只供 MacBook 工具读取，iPhone 无法读取该文件。

## 验证

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project IoTBluetooth.xcodeproj \
  -scheme IoTBluetooth \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

自动测试和编译不能替代实车验收。开锁后应确认仪表稳定常亮且晃动无蜂鸣，关锁后应确认仪表熄灭且晃动有蜂鸣。

详细说明见[架构](documentation/architecture.md)、[流程](documentation/flows.md)和[测试](documentation/tests.md)。

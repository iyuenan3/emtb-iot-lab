# Repository Guidelines

## Project Structure

仓库当前只维护 Build 33 纯蓝牙 iPhone App 和 MacBook 一次性 BLE 工具。

- `iot-bluetooth/IoTBluetooth/`：SwiftUI 界面、CoreBluetooth 连接和 Keychain。
- `iot-bluetooth/Shared/`：iPhone 与 MacBook 共用的 BLE 帧和控制状态机。
- `iot-bluetooth/tools/`：MacBook 一次性开锁、关锁工具。
- `iot-bluetooth/tests/`：当前实现的协议、状态机、源码边界和编译测试。
- `iot-bluetooth/documentation/`：当前 BLE 设计和验收说明。
- `archive/`：本机历史资料，不属于当前实现，不得提交。

## Build and Test

- `cd iot-bluetooth && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`：运行当前自动测试。
- `cd iot-bluetooth && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project IoTBluetooth.xcodeproj -scheme IoTBluetooth -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`：检查 iPhoneOS 编译。
- MacBook 工具编译命令见根目录 `README.md`。

## Coding Style

Swift 使用四空格缩进，类型采用 `UpperCamelCase`，属性和函数采用 `lowerCamelCase`。协议帧构造、解析与状态机只维护在 `Shared/`，不得在 App 或 MacBook 工具中复制。

中文文档保持简洁，不使用破折号。

## Safety and Testing

每次控制只允许发送一次，不自动重连、不自动重试、不补发反向动作。未经用户明确确认，不发送实车控制指令。

自动测试、编译和 BLE 回包不能证明车辆物理成功。实车验收必须记录仪表是否稳定、晃动报警是否符合预期以及蓝牙是否按设计断开。

## Git and Security

提交信息使用 `feat:`、`fix:`、`docs:`、`refactor:`、`test:` 或 `build:`。保留用户已有改动，只暂存本次明确文件，不使用 `git add -A`。

不得提交 `archive/`、`.env*`、`Secrets.xcconfig`、设备密钥、蓝牙 MAC、签名凭据、日志、Xcode 用户状态或构建产物。

# Repository Guidelines

## Project Structure & Module Organization

`iot-bluetooth/` 是 SwiftUI iPhone 调试 App，BLE 协议、设备连接和界面代码位于 `IoTBluetooth/`，设计与测试说明位于 `documentation/`。`iot-remote/` 是仅使用 Python 标准库的单车 TCP 与 HTTP 服务，源码在 `iot_remote/`，测试在 `tests/`。`iot-tcp-lab/` 用于协议采集和受控的一次性实车验证。本机历史代码和私有资料不属于公开仓库，不得作为当前实现直接提交。

## Build, Test, and Development Commands

- `cd iot-remote && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`：运行远程服务测试。
- `cd iot-tcp-lab && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v`：运行协议工具测试。
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project iot-bluetooth/IoTBluetooth.xcodeproj -scheme IoTBluetooth -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`：检查 iOS 工程编译。
- 使用 Xcode 打开工程并选择个人开发团队，将 App 安装到真机进行 BLE 验收。

## Coding Style & Naming Conventions

Swift 使用四空格缩进，类型采用 `UpperCamelCase`，属性和函数采用 `lowerCamelCase`。Python 遵循 PEP 8、四空格缩进和 `snake_case`。协议帧构造与解析应集中在现有协议模块，不在界面或 HTTP 路由中复制字节逻辑。中文文档保持简洁，不使用破折号。

## Testing Guidelines

Python 测试文件使用 `test_*.py`，每项修复至少覆盖成功、拒绝和幂等路径。BLE 与车辆物理状态不能只靠自动化证明，需记录真机连接、回包以及仪表、动力、轮毂锁的现场结果。未经用户明确确认，不发送实车控制指令。

## Commit & Pull Request Guidelines

提交信息使用 `feat:`、`fix:`、`docs:`、`refactor:`、`test:` 或 `build:`，主题写明模块和结果。Pull Request 应列出影响目录、协议或数据模型变化、执行过的验证和仍需实车确认的事项。界面修改附截图，控制链路修改附脱敏日志。

## Generated Files & Security

不得提交 `archive/`、`.env*`、私钥、设备密钥、配对码、SQLite、日志、Xcode 用户状态或构建产物。日志必须脱敏设备密钥和认证材料。部署配置使用占位符或环境注入，不把真实设备标识、服务器地址和本机绝对路径写入公开文档。

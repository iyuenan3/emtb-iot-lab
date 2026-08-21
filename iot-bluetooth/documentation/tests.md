# 测试策略

## 已有自动化

| 范围 | 命令 | 当前覆盖 |
| --- | --- | --- |
| 远程服务 | `cd ../iot-remote && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v` | 30 项，覆盖签名、BLE 状态同步、数据库、D0 转换与去重、位置 API、协议、命令状态机、通信静默、部署版本读回与优雅停机 |
| iOS 编译 | `xcodebuild -project IoTBluetooth.xcodeproj -scheme IoTBluetooth -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | Swift 类型检查、资源和工程配置 |

iOS 工程目前没有 XCTest 或 XCUITest Target。自动构建不能证明 CoreBluetooth、Face ID、真机网络或车辆物理动作正确。

## 已完成实车验收

- BLE 开锁和关锁会联动仪表、动力与轮毂锁。
- 远程开锁链路已完成实车验收。
- 远程声音找车已成功发声。
- S6 能读取车端电量和原始字段。

## 待验收

- Build 9 MapKit 车辆标记、双找车按钮、首页远程关锁入口和户外可读性。
- Build 10 BLE 状态优先、冲突提示、服务器同步和断开回退。
- 远程关锁的新版 App 端交互。
- 真实 D0 有效坐标、MapKit 标记、时间与精度字段展示。
- BLE 高级设置、RFID、外部锁、OTA 等逐项能力。

## 回归清单

1. 启动 App 不发送车辆控制指令。
2. 远程和 BLE 通道切换不触发自动补发。
3. 已在目标锁状态时按钮禁用或服务返回无需操作。
4. 结果未知时不出现自动重试。
5. 密钥不出现在日志、截图文案和构建产物配置中。
6. D0 为 `V` 时不覆盖最后有效位置，轨迹间隔超过 10 分钟时不跨缺口连线。
7. 未实现告警时，界面明确标注缺口。

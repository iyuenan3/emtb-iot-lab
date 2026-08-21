# App 架构

## 产品边界

`IoTBluetooth` 是单车、单用户的 iPhone 实车调试工具，支持附近 BLE 和经 `iot-remote` 的云端控制。两个通道各自维护连接与结果，不自动切换、不补发控制指令。

## 当前结构

| 层级 | 代码 | 职责 | 当前状态 |
| --- | --- | --- | --- |
| 界面 | `ContentView.swift` | 车辆、地图、记录、更多四页导航 | Build 14 已实现 |
| BLE 状态 | `BLEDeviceManager.swift` | 扫描、认证、读写、重连和本地日志 | 已实现，部分指令待实车验证 |
| BLE 协议 | `OmniProtocol.swift` | 帧编码、解码、校验和命令定义 | 已实现 |
| 云端状态 | `RemoteControlManager.swift` | 配对、签名、车辆与命令 API | 已实现首期能力 |
| 本机密钥 | `KeychainStore.swift` | BLE 密钥和远程凭据 | 已实现 |
| 远程服务 | `../iot-remote/` | 单车 TCP、HTTPS API、命令状态机 | 2026 年 8 月 22 日已部署 revision `5002f2f` |
| 位置存储 | `../iot-remote/iot_remote/database.py` | D0 原始报告、质量过滤、去重和历史查询 | 已部署，真实坐标与阈值待验收 |

## 数据流

```text
iPhone App -> CoreBluetooth -> 车辆 IoT
iPhone App -> HTTPS -> iot-remote -> TCP -> 车辆 IoT
```

远程开关锁由 Secure Enclave 私钥签名，服务端完成防重放、幂等和设备回包校验。BLE 密钥不上传服务器。

## 设计约束

- 首页只放日常状态和开关锁，维护能力统一进入“更多”。
- 地图、基础位置、漂移过滤、D1 协调、布防、前台告警、骑行分段、保留清理和离线移动推断已实现。
- 当前没有邮件、定时任务、公开 SEO、支付或 App 内智能体自动化。
- 车辆状态必须标注来源。远程状态和 BLE 状态不能合并为未经证实的单一结果。
- 主锁状态优先级为当前 BLE 回读、服务器最近确认、未知。BLE 结果通过签名观察接口同步，但不会转换成新的开关锁命令。

## 相关文档

- [界面设计](../APP-DESIGN.md)
- [关键流程](flows.md)
- [权限与安全](permissions.md)
- [变量与配置](variables.md)
- [测试策略](tests.md)
- [实现状态](../IMPLEMENTATION-STATUS.md)
- [远程 API](../API-DESIGN.md)
- [服务端数据模型](../DATA-MODEL.md)

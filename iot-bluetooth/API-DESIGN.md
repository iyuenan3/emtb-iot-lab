# 单车远程控制 API 设计

## 1. 目标与边界

本 API 只服务一台测试车辆和一台 iPhone。设备通过独立公网 TCP 端口连接单车网关，手机只通过 HTTPS 访问服务。服务端不依赖原业务后台，不提供多租户、支付、订单或运营能力。

本文记录已确认需求。协议能力仍须通过模拟器和实车分阶段验收，未验证能力保持禁用。

现有 `iot-tcp-lab` 保留为协议采集和一次性配置工具。新服务建议放在独立的 `iot-remote/` 目录，复用其帧解析、IMEI 白名单、脱敏和测试思路，不直接扩展临时脚本。

## 2. 服务组成

```text
IoT TCP 连接
  -> 帧解析器
  -> 单车会话注册表
  -> 命令状态机
  -> 车辆、定位、告警状态机
  -> SQLite
  -> HTTPS API
  -> iPhone App
```

- TCP 监听：对外使用现有 `19680`，只接受目标设备。
- HTTP 监听：仅绑定 `127.0.0.1`，由 Caddy 独立子域名反向代理。
- 数据库：SQLite WAL，数据库文件和备份目录权限为 `600`、`700`。
- 运行方式：独立低权限系统用户和 systemd 单元，不修改其他项目服务。

实际内部端口、域名和 systemd 名称在部署前通过只读端口清单确定，本文不预占具体值。

## 3. 客户端认证

### 3.1 首次配对

1. 服务端命令行生成一次性配对码，10 分钟失效，只保存摘要。
2. App 在 Secure Enclave 中生成 P-256 控制密钥，并生成普通只读请求密钥。
3. App 提交配对码、两个公钥和设备名称。
4. 服务端校验后立即作废配对码，只保存公钥。

控制私钥使用 `biometryCurrentSet` 保护。BLE 与云端开锁、关锁、直接车轮锁控制、修改设备密钥、服务器、APN、OTA 和清除设备数据需要 Face ID 才能完成签名或本地授权。只读请求和声音找车不触发 Face ID。

### 3.2 请求签名

受保护请求携带以下头部：

```text
X-Client-Id
X-Timestamp
X-Nonce
X-Body-SHA256
X-Signature
```

签名原文固定为：

```text
METHOD\nPATH\nCANONICAL_QUERY\nTIMESTAMP\nNONCE\nBODY_SHA256
```

服务端拒绝超过 60 秒的时间偏差、10 分钟内重复 nonce、未知公钥和权限不匹配的签名。日志不得记录签名、配对码、设备密钥或维护密钥。

## 4. 通用约定

- 基础路径：`/api/v1`。
- 时间：API 使用 UTC ISO 8601，App 按 `Asia/Shanghai` 显示。
- 标识：使用 UUID，不在 URL 暴露 IMEI。
- 分页：使用不透明 `cursor`，默认 100 条，最大 500 条。
- 写请求：必须携带 `Idempotency-Key`。24 小时内重复键返回原命令，不重新下发。
- 响应：每个响应包含 `request_id` 和 `server_time`。
- 缓存：车辆状态接口返回 `ETag`，App 可使用条件请求。

错误格式：

```json
{
  "error": {
    "code": "vehicle_offline",
    "message": "设备当前离线，命令未排队",
    "retryable": false
  },
  "request_id": "uuid",
  "server_time": "2026-08-21T02:00:00Z"
}
```

## 5. 读取接口

| 方法与路径 | 作用 | 主要返回 |
| --- | --- | --- |
| `POST /pairings/complete` | 完成一次性配对 | `client_id`、权限 |
| `GET /vehicle` | 首页聚合状态 | 在线、锁、布防、电量、D1、最后位置、活动告警 |
| `GET /vehicle/telemetry` | 完整遥测 | `S6` 已验证字段及采集时间 |
| `GET /locations` | 查询位置点 | 最后有效点、最后一次报告、有效点列表、来源和精度 |
| `GET /trips` | 查询骑行列表 | 起止时间、距离、点数 |
| `GET /trips/{trip_id}` | 查询单次轨迹 | 骑行摘要和轨迹点 |
| `GET /alarms` | 查询告警 | 活动、已解除或全部告警 |
| `GET /commands/{command_id}` | 查询命令结果 | 状态、阶段、回包摘要、超时信息 |
| `GET /commands` | 查询命令历史 | 类型、状态、时间和操作者 |
| `GET /capabilities` | 指令中心目录 | 通道、风险、验证级别、可执行性 |
| `GET /settings` | 查询用户设置 | 轨迹保留天数等 |
| `GET /audit-logs` | 查询统一审计 | 操作者类别、动作、对象、结果、安全摘要和时间 |
| `GET /device-sessions` | 查询设备会话 | 地址摘要、收发计数、解析错误、Q0/H0 和结束原因 |
| `PUT /settings/location-history` | 修改轨迹保留期 | 只接受 7 或 30；缩短时需要确认字段 |
| `POST /ble-events` | 同步 BLE 操作结果 | 事件 UUID、动作、设备时间、结果、回读状态 |
| `POST /ble-observations` | 同步 BLE 主锁回读 | 观察 UUID、锁状态、观察时间、是否应用 |

`GET /vehicle` 的位置字段同时给出 `captured_at` 和 `age_seconds`。无效定位不得替换 `last_valid_position`。

Build 9 当前实现路径为 `GET /api/v1/locations?limit=500&since=<UTC秒>`。`latest` 是最后有效位置，`last_report` 包含最近一次有效或无效 D0，`points` 只返回有效点并按设备时间升序排列。读取需要已配对客户端认证。

Build 10 当前实现 `POST /api/v1/ble-observations`。请求必须使用配对客户端的 P-256 私钥签名，只接受 24 小时内的 `locked` 或 `unlocked` 观察。观察 UUID 保证幂等，只有时间不早于服务器现有锁状态时才更新快照。该接口不创建命令、不发送 TCP 帧。

Build 15 实现签名的 `POST /api/v1/ble-events`。请求必须使用规范 UUID，`Idempotency-Key` 必须与事件 UUID 一致。服务端先全局去重，再按时效、BLE 结果、动作与回读一致性、当前锁状态时间判定是否产生状态影响。无论是否生效都保留审计记录；只有新建且生效的在线事件才进入 D1 协调。

Build 13 已实现 `GET /api/v1/trips`、`GET /api/v1/trips/{trip_id}`、`GET /api/v1/settings` 和签名的 `PUT /api/v1/settings/location-history`。保留期只接受 7 或 30，缩短到 7 天必须携带确认字段，并在下一次每日清理时生效。

Build 16 扩展 `GET /api/v1/settings`，只把 `location_history_days` 标记为可修改，其余命令超时、通信静默、离线、布防、定位质量和离线移动阈值均为服务端受控只读值。新增 `GET /api/v1/audit-logs` 和 `GET /api/v1/device-sessions`，只返回安全摘要和带随机盐的地址指纹，不返回原始网络地址、签名、nonce、令牌或设备密钥。

位置历史、单次轨迹、统一审计和设备会话属于敏感明细读取。四类接口在认证、参数校验和数据读取均成功后写入统一审计，只记录客户端、对象、查询上限、可选起始时间或点数。审计读取记录从下一次查询开始可见。App 的 15 秒前台轮询只读取车辆、能力、命令和告警，不反复读取敏感明细。

`GET /capabilities` 的每项至少包含 `capability_id`、中文名称、协议编号、通道、参数模式、风险等级、证据等级、是否可执行和禁用原因。App 与本地 BLE 能力目录按 `capability_id` 合并，但不能由服务端文本动态生成未经审核的操作按钮。

## 6. 控制接口

所有控制统一使用 `POST /commands`，但只能提交服务端能力目录中的 `capability_id`，不接受原始协议字符串。

```json
{
  "capability_id": "vehicle.unlock",
  "channel": "cloud",
  "parameters": {},
  "client_context": {
    "app_version": "1.0",
    "confirmed_at": "2026-08-21T02:00:00Z"
  }
}
```

首期可执行能力：

| capability_id | 设备流程 | 权限与限制 |
| --- | --- | --- |
| `vehicle.unlock` | `R0 -> L0` | Face ID、长按、设备在线 |
| `vehicle.lock` | 人工停稳确认，`R0 -> L1` | Face ID、长按、签名确认车辆停稳 |
| `location.once` | `D0` | 在线；30 秒等待有效或无效定位 |
| `vehicle.find_sound` | `V0,2` | 在线；10 秒冷却 |
| `telemetry.refresh` | `S6` | 在线；只读 |
| `alarm.acknowledge` | 服务端状态转换，在线时下发 `D1` | 活动告警存在；IoT 离线时只更新服务端状态 |
| `tracking.set_policy` | 按策略下发 `D1` | 维护权限，不允许任意原始值 |

其余协议能力由 `/capabilities` 展示。当前车辆的 `L5` 与 BLE `0x81` 实测无回包，且曾出现无法归因的延迟关锁，统一标记为“危险维护”和“因果未确认”并禁用。不能把无回包解释为“不适用”。只有完成隔离变量验证、显式参数校验、结果解析和验收标签后，才允许执行。

任何需要向 IoT 下发协议帧的请求，在设备处于 `silent` 或 `offline` 时立即返回 `rejected`，包括 `D0`、`D1`、`S5`、H0 间隔相关配置和所有控制指令。H0 本身是设备上行心跳，不作为下行命令。服务端不创建待发送队列，也不在重连时重放被拒绝的请求。App 的状态读取和 BLE 事件上传不属于设备下行请求，仍可正常处理。

## 7. 命令状态机

命令状态固定为：

```text
accepted
  -> noop
  -> rejected
  -> prechecking
  -> awaiting_r0
  -> awaiting_result
  -> succeeded
  -> failed
  -> unknown
```

- `noop`：设备已处于目标状态，没有下发。
- `rejected`：离线、冷却中、无权限或关锁预检失败。
- `failed`：设备明确返回失败、KEY 错误或通信超时结果。
- `unknown`：服务端等待超时、连接中断或服务重启，实际效果不确定。

同一车辆同时只允许一个在途命令，包括只读查询，因为设备协议没有通用命令编号用于并发关联。命令一旦写入 TCP，不允许取消。`failed` 和 `unknown` 均不自动重试。

### 7.1 主开关锁

1. 检查设备在线、当前锁状态和在途命令。
2. 已在目标状态则返回 `noop`。
3. 创建持久化命令，再发送 `R0`。
4. 校验返回的操作 KEY、动作、用户 ID 和操作序列。
5. 发送 `L0` 或 `L1`。
6. 等待最终设备结果并发送协议确认。
7. 成功后提交锁状态、骑行和 D1 策略变更。

### 7.2 远程关锁预检

轮毂锁可能造成骑行风险。当前个人测试版本没有可信的 S6 速度或 RPM 字段，因此不伪造自动静止判断。App 必须先完成 1.2 秒长按和 Face ID，并在签名请求体中提交 `stationary_confirmed=true`。服务端缺少该参数时返回 `stationary_confirmation_required`，只有参数存在、设备在线且当前不是已关锁状态时才进入 R0、L1 流程。

L1 成功只证明 IoT 已确认逻辑关锁。App 仍要求用户核对仪表熄灭、车辆动力断开和轮毂不能转动。没有可靠电子反馈前不自动启动 5 分钟布防。以后确认可信速度字段后，再用两次新鲜的零速遥测替代人工停稳确认。

### 7.3 D1 策略协调

锁状态或告警状态变化时，服务端计算 `desired_tracking_interval`：

- 已开锁：60 秒。
- 已关锁：3600 秒。
- 活动异常移动告警：300 秒。

只有设备回包与目标值一致时才更新 `confirmed_tracking_interval`。超时保留两个不同值并显示“未确认”，不自动重发。

设备离线时不创建 D1 命令。新会话建立并收到新的 H0 后，服务端根据当时确认的锁状态和活动告警重新计算策略，可以创建一条新的 D1 命令。新命令必须具有新的命令 ID 和审计记录，不能复用任何离线期间被拒绝的请求。

Build 11 已实现该协调器。成功开锁申请 60 秒，成功关锁申请 3600 秒，新设备会话收到首个 H0 时按当前状态重新协调。服务端只在 D1 回包与目标值完全一致时更新确认值，同一会话超时不重发；App 同时展示期望值和确认值。300 秒告警策略将在告警状态机接入时复用同一协调器。

### 7.4 BLE 事件同步

BLE 开关锁成功后，App 使用独立事件 UUID 调用 `POST /api/v1/ble-events`。服务端先按事件 UUID 去重，再校验操作时间、BLE 结果和回读锁状态：

- 24 小时内的有效事件可以更新锁、安全和骑行状态。
- 超过 24 小时的事件只写审计，不改变当前状态或触发 D1。
- IoT 在线时，根据新的锁状态创建 D1 命令。
- IoT 离线时，不创建 D1 或其他设备请求。
- 后续 H0、L0、L1 与 BLE 事件冲突时，以时间更新且由设备网络回包确认的状态为准，并保留冲突审计。

补报只同步已经发生的 BLE 结果，绝不转换成云端开锁或关锁命令。

## 8. 告警接口与状态

车辆安全状态为 `disarmed`、`grace_period`、`armed`、`alarm_active`；实际告警记录状态为 `active`、`acknowledged`、`cleared`。等待布防和已布防不创建虚假告警记录。

- 关锁成功创建 5 分钟 `grace_period`，到时自动进入 `armed`。
- 等待期收到 `W0,1` 只记事件，不创建活动告警。
- 布防后收到 `W0,1`，创建或合并 `active` 告警并立即回复设备确认，再启动一个内部复合命令。复合命令先申请 `D1=300`，随后发送 `D0`，某一步结果未知也不重发该步骤。
- `POST /commands` 的 `alarm.acknowledge` 记录用户确认。车辆仍关锁时的策略为 `D1=3600`，已开锁时为 `D1=60`。IoT 离线时只更新服务端告警和安全状态，D1 请求立即拒绝且不排队。
- 授权开锁成功自动确认并解除活动告警。
- IoT 从离线恢复并确认仍为关锁状态时，服务端串行请求两次有效 `D0`。若两次位置均可信，且相对断网前最后停车位置发生明显变化，创建 `suspected_offline_movement` 告警。该告警始终标记为推断，不伪装成实时 `W0`。

Build 14 已实现离线移动检查。断连时只在关锁且存在可信位置时冻结基线；新会话首个 H0 仍为关锁才开始两次 `location.once`，每一步终态后才创建下一步。无效定位、质量拒绝、超时、断连、开锁或已有活动告警都会终止，且同一会话不重试。默认位移阈值 200 米、两次样本最大间距 75 米，均为服务端可配置的待校准初值。

`acknowledged` 表示用户已在 App 中确认并解除提醒，不再作为活动告警；`cleared` 用于设备明确上报条件消失，或授权开锁导致系统自动解除。D1 恢复是独立结果，失败时不能把告警重新改回活动状态，但必须保留“定位策略未确认”提示。

App 未运行不影响服务端告警处理。由于免费签名不保证 APNs，App 下次读取 `/vehicle` 或 `/alarms` 时展示活动告警。

Build 12 已实现 `security.confirm_locked`、`security.arm`、`alarm.acknowledge` 和 `GET /api/v1/alarms`。逻辑关锁不会直接启动等待期，用户必须在核对仪表、动力和轮毂后提交独立签名确认。W0,1 在等待期只记录，布防后创建或合并告警，回复空字段 W0 确认，再串行执行受控 D1 300 秒与 D0。W0 云端帧和设备确认格式仍需实车验证，未验证前不外推协议模拟结果。

## 9. 在线与健康判断

设备在线必须同时满足：存在当前会话，最近收到过有效协议帧，静默时间没有超过阈值。仅有 TCP `ESTABLISHED` 不算在线。

服务端记录：

- 当前会话建立时间和对端地址摘要。
- 最后有效收包时间、最后发包时间。
- 收包数、发包数、解析失败数。
- 最近一次 `Q0`、`H0` 时间。
- 当前静默秒数和离线原因。

`H0` 目标值为 300 秒。超过 420 秒没有有效报文时进入 `silent`，超过 720 秒进入 `offline`。阈值只在实车长期测试发现明显误判时调整，并记录配置变更。

当前实现的公开 `GET /healthz` 返回 `ok`、`revision`、`device_online`、`device_connectivity` 和 `last_frame_age_seconds`。`device_connectivity` 取值为 `online`、`silent` 或 `offline`；只有 `online` 允许下发控制。部署时通过 `EMTB_IOT_REVISION` 注入 Git SHA，并从公网入口读回相同值。`GET /api/v1/vehicle` 同步返回 `connection_state`，App 必须把 `silent` 明确显示为“通信静默”，不能合并成普通在线状态。

## 10. 配置与运维接口边界

API 不提供数据库下载、服务器 Shell、任意 TCP 下发、任意 SQL 或密钥读取。设备密钥轮换、服务器地址、APN、OTA 和设备电源首版只在近场 BLE 维护页执行。云端能力目录可以展示，但远程执行保持禁用。未来若开放远程维护，必须重新确认需求，并增加独立 capability、参数白名单、二次确认和单项验收。

部署切换时先在内部测试端口使用模拟器验证，再在维护窗口接管 `19680`。旧服务停止后确认端口释放，新服务启动失败时恢复旧服务，不并行监听同一公网端口。

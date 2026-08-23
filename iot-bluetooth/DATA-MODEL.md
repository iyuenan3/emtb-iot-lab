# 单车远程服务数据模型

> 历史文档：远程服务已于 2026 年 8 月 23 日停止并完成远端资产永久清理。当前产品为 Build 25 纯 BLE App，本文只保留此前的数据设计和验证记录。

## 1. 设计原则

- 只支持一台测试车辆，但保留 `vehicle_id` 外键，避免业务表直接散落 IMEI。
- SQLite 使用 WAL、外键约束和事务。命令状态与设备回包必须原子提交。
- 时间统一保存为 UTC 毫秒时间戳，设备原始 UTC 日期和时间另外保留。
- 设备密钥、维护密钥、APN 密码和配对码明文不得进入数据库。
- 原始定位与展示判定分开保存。过滤漂移点不能破坏诊断证据。

本文记录已确认的数据需求。协议能力仍须通过模拟器和实车分阶段验收。

建议数据库文件为 `runtime/data/iot-remote.sqlite3`，目录权限 `700`，文件权限 `600`。实际服务器路径在部署时确定。

## 2. 状态枚举

### 2.1 车辆状态

| 字段 | 可选值 |
| --- | --- |
| `connection_state` | `online`、`silent`、`offline` |
| `lock_state` | `unknown`、`unlocked`、`locked` |
| `wheel_lock_state` | `unknown`、`unlocked`、`locked`、`timeout` |
| `security_state` | `disarmed`、`grace_period`、`armed`、`alarm_active` |

### 2.2 命令状态

`accepted`、`prechecking`、`awaiting_r0`、`awaiting_result`、`succeeded`、`failed`、`unknown`、`noop`、`rejected`。

`succeeded`、`failed`、`unknown`、`noop`、`rejected` 为终态。任何终态都不能再次变回执行中状态。

### 2.3 告警状态

`active`、`acknowledged`、`cleared`。`acknowledged` 表示用户已确认并解除提醒；`cleared` 表示设备明确上报条件消失，或授权开锁触发自动解除。布防和等待期属于车辆安全状态，不伪造为告警记录。

## 3. 核心表

### 3.1 `vehicles`

保存固定设备身份和显示名称。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | TEXT PK | 服务端生成 UUID |
| `display_name` | TEXT | 用户看到的车辆名称 |
| `imei` | TEXT UNIQUE | TCP 路由需要，禁止写日志 |
| `vendor_code` | TEXT | 从有效上行帧确认 |
| `ble_mac` | TEXT | 诊断用，不经公共 API 默认返回 |
| `enabled` | INTEGER | 固定为 0 或 1 |
| `created_at` | INTEGER | UTC 毫秒 |
| `updated_at` | INTEGER | UTC 毫秒 |

### 3.2 `vehicle_state`

每台车辆恰好一行，是首页状态的权威快照。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `vehicle_id` | TEXT PK/FK | 关联车辆 |
| `connection_state` | TEXT | 在线状态 |
| `lock_state` | TEXT | 主锁状态 |
| `wheel_lock_state` | TEXT | 外部车轮锁状态 |
| `security_state` | TEXT | 撤防、等待、布防或告警中 |
| `grace_until` | INTEGER NULL | 5 分钟等待结束时间 |
| `active_trip_id` | TEXT NULL | 当前骑行 |
| `active_alarm_id` | TEXT NULL | 当前未解除告警 |
| `desired_tracking_interval` | INTEGER | 期望 D1 秒数 |
| `confirmed_tracking_interval` | INTEGER NULL | 设备回包确认值 |
| `tracking_confirmed_at` | INTEGER NULL | 最近确认时间 |
| `offline_since` | INTEGER NULL | 连接断开时间 |
| `parked_location_id` | INTEGER NULL | 断网前最后可信停车位置 |
| `battery_percent` | INTEGER NULL | 已验证电量字段 |
| `motor_rpm` | INTEGER NULL | 关锁预检候选字段 |
| `telemetry_at` | INTEGER NULL | S6 采集时间 |
| `last_valid_position_id` | TEXT NULL | 最后有效定位 |
| `last_frame_at` | INTEGER NULL | 最后有效协议帧 |
| `last_q0_at` | INTEGER NULL | 最近签到 |
| `last_h0_at` | INTEGER NULL | 最近心跳 |
| `updated_at` | INTEGER | 快照更新时间 |

只有设备明确回包才能更新 `lock_state` 和 `confirmed_tracking_interval`。发出命令只更新期望值，不提前修改确认值。逻辑 L1 或 H0 关锁只能更新锁状态，车辆仍为撤防时保持原定位频率；现场确认仪表、动力和轮毂锁三个物理结果并进入 `grace_period` 后，才能把 D1 期望值切换为 3600 秒。

Build 11 已在当前 `vehicle_state` 表落地 `desired_tracking_interval`、`confirmed_tracking_interval` 和 `tracking_confirmed_at`。旧数据库启动时原位补列，不伪造历史确认值。

### 3.3 `device_sessions`

记录连接生命周期，不保存完整公网地址。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | TEXT PK | 会话 UUID |
| `vehicle_id` | TEXT FK | 车辆 |
| `peer_fingerprint` | TEXT | 对端地址摘要 |
| `connected_at` | INTEGER | 建连时间 |
| `disconnected_at` | INTEGER NULL | 断连时间 |
| `disconnect_reason` | TEXT NULL | EOF、超时、替换等 |
| `rx_count` | INTEGER | 有效收包数 |
| `tx_count` | INTEGER | 发包数 |
| `parse_error_count` | INTEGER | 解析失败数 |
| `last_rx_at` | INTEGER NULL | 最后收包 |
| `last_tx_at` | INTEGER NULL | 最后发包 |

同一车辆只能有一个活动会话。新有效连接替换旧连接时，旧会话记录 `replaced`，旧 writer 立即关闭。

Build 16 已落地 `device_sessions`。服务端只保存每次连接使用随机盐计算的 16 位 `peer_fingerprint`，不保存原始 IP 或端口；同时记录收发计数、解析错误、最后收发、最后 Q0、最后 H0 和断开原因。服务启动时会把崩溃遗留的活动会话关闭为 `service_restarted`。

完成度审计补充了自然断线反例。连接处理必须先把当前 `session_id` 保存到局部变量，再清空内存会话；随后以 `peer_closed`、`receive_timeout` 或 `connection_error` 闭合持久化会话，并把在途命令标记为结果未知。禁止在会话置空后再次通过空对象读取 ID。

## 4. 命令与审计

### 4.1 `commands`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | TEXT PK | 命令 UUID |
| `vehicle_id` | TEXT FK | 车辆 |
| `client_id` | TEXT NULL FK | 用户操作来源，内部策略可为空 |
| `idempotency_key` | TEXT NULL | 同一客户端 24 小时内唯一 |
| `capability_id` | TEXT | 例如 `vehicle.unlock` |
| `channel` | TEXT | `cloud` 或内部策略 |
| `protocol_function` | TEXT NULL | `R0`、`L0`、`D1` 等 |
| `parameters_json` | TEXT | 已校验参数，不含秘密 |
| `state` | TEXT | 命令状态 |
| `phase` | TEXT NULL | 具体协议阶段 |
| `desired_result_json` | TEXT NULL | 目标状态 |
| `confirmed_result_json` | TEXT NULL | 设备确认结果 |
| `failure_code` | TEXT NULL | 稳定错误码 |
| `created_at` | INTEGER | 创建时间 |
| `sent_at` | INTEGER NULL | 首次写入 TCP 时间 |
| `finished_at` | INTEGER NULL | 进入终态时间 |
| `expires_at` | INTEGER | 等待截止时间 |

唯一索引：`(client_id, idempotency_key)`，其中键非空。部分唯一索引确保同一车辆最多一条执行中命令。

设备处于 `silent` 或 `offline` 时，所有需要下行的请求直接写成 `rejected` 终态，不进入在途命令索引，不产生待发送队列。重连后的协调使用新的命令 ID。

### 4.2 `command_events`

命令的追加式时间线，用于解释为什么成功、失败或未知。

字段包括 `id`、`command_id`、`event_type`、`protocol_function`、`safe_payload_json`、`created_at`。敏感指令只保存字段数量、摘要和验证结论。

### 4.3 `ble_events`

保存 App 对已经发生的 BLE 开关锁结果的同步，用于去重和恢复业务状态，不用于再次控制设备。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | TEXT PK | App 生成的事件 UUID |
| `vehicle_id` | TEXT FK | 车辆 |
| `client_id` | TEXT FK | 上报手机 |
| `action` | TEXT | `unlock` 或 `lock` |
| `ble_result` | TEXT | `succeeded`、`failed`、`unknown` |
| `readback_lock_state` | TEXT | 回读后的主锁状态 |
| `device_operation_at` | INTEGER | BLE 命令携带或返回的时间 |
| `received_at` | INTEGER | 服务端首次收到时间 |
| `state_effect_applied` | INTEGER | 是否允许改变当前业务状态 |
| `ignored_reason` | TEXT NULL | 过期、冲突或无效原因 |

事件 UUID 全局唯一。超过 24 小时才上传的事件只保留审计，`state_effect_applied` 固定为 0。后续 H0、L0、L1 与 BLE 事件冲突时，使用时间更新且由设备网络回包确认的状态，并记录冲突。

Build 10 实现精简的 `ble_observations` 表，用于同步 BLE 主锁只读回读。字段包括观察 UUID、车辆、客户端、`lock_state`、观察时间、接收时间和是否应用。它不代表一次开关锁动作，也不会触发车辆控制。Build 15 已实现上表 `ble_events`，事件与锁、安全、骑行状态在同一 SQLite 事务中写入。

### 4.4 `audit_logs`

记录配对、读取敏感状态、控制、设置修改、告警解除、保留策略修改和清理任务。字段包括操作者、动作、对象类型、对象 ID、结果、请求 ID 和时间。禁止保存私钥、签名、nonce 原文和设备 KEY。

Build 16 已落地 `audit_logs`，并覆盖成功配对、命令创建与状态、定位接收、骑行起止、告警事件、BLE 观察与操作事件、设置修改、设备会话和每日清理。完成度审计进一步覆盖位置历史、单次轨迹、统一审计和设备会话四类敏感明细读取。读取审计只保存客户端、对象、查询上限、可选起始时间或点数，不保存令牌、签名、定位原始帧、原始地址或设备数据正文。未认证或参数无效的请求不写入成功读取审计。

## 5. 定位与骑行

### 5.1 `positions` 目标模型与当前 `locations`

有效和无效 `D0` 都保存，但只有有效且通过展示规则的记录进入地图轨迹。

当前 `locations` 表保存单次或追踪来源、设备时间、接收时间、有效性、WGS84 经纬度、卫星数、HDOP、海拔、模式和原始字段。相同设备、设备时间和原始字段使用 SHA-256 指纹去重。质量管线已经补充 `display_eligible`、`rejection_reason`、相邻距离和估算速度，拒绝无效、时间缺失或超前、卫星不足、HDOP 过高、乱序和异常速度点。被拒绝点保留原始记录，但不替换地图可靠位置。Build 13 已补充骑行和告警归属。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | TEXT PK | 定位 UUID |
| `vehicle_id` | TEXT FK | 车辆 |
| `trip_id` | TEXT NULL FK | 所属骑行 |
| `alarm_id` | TEXT NULL FK | 关联告警 |
| `source` | TEXT | `scheduled`、`manual`、`alarm`、`reconnect_check` |
| `tracking_marker` | INTEGER | 协议中的单次或追踪标记 |
| `validity` | TEXT | `A` 或 `V` |
| `raw_latitude` | TEXT NULL | 原始度分格式 |
| `raw_latitude_hemisphere` | TEXT NULL | N 或 S |
| `raw_longitude` | TEXT NULL | 原始度分格式 |
| `raw_longitude_hemisphere` | TEXT NULL | E 或 W |
| `latitude_wgs84` | REAL NULL | 标准纬度 |
| `longitude_wgs84` | REAL NULL | 标准经度 |
| `satellites` | INTEGER NULL | 卫星数 |
| `hdop` | REAL NULL | 精度指标 |
| `altitude_m` | REAL NULL | 海拔 |
| `device_time` | INTEGER NULL | 设备 UTC 时间 |
| `received_at` | INTEGER | 服务端收包时间 |
| `display_eligible` | INTEGER | 是否用于地图连线 |
| `rejection_reason` | TEXT NULL | 无效、漂移、乱序等 |

索引：`(vehicle_id, received_at DESC)`、`(trip_id, received_at)`、`(alarm_id, received_at)`。

当前默认展示阈值为至少 4 颗卫星、HDOP 不高于 8、相邻可靠点估算速度不高于 25 米每秒，设备时间最多允许超前 300 秒。前三项由服务启动参数和部署环境集中配置，户外样本验证后可以调整。被过滤点仍保留原始记录。

### 5.2 `trips`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | TEXT PK | 骑行 UUID |
| `vehicle_id` | TEXT FK | 车辆 |
| `started_at` | INTEGER | 确认开锁时间 |
| `ended_at` | INTEGER NULL | 确认关锁时间 |
| `start_command_id` | TEXT NULL FK | 开锁命令 |
| `end_command_id` | TEXT NULL FK | 关锁命令 |
| `status` | TEXT | `active`、`completed`、`abandoned` |
| `recovered_after_restart` | INTEGER | 是否由服务重启后的状态恢复创建 |
| `point_count` | INTEGER | 可展示点数 |
| `distance_m` | REAL | 过滤后估算距离 |
| `updated_at` | INTEGER | 汇总更新时间 |

距离只累计相邻、有效、可展示的点。轨迹出现长时间缺口时地图断线显示，不跨越缺口绘制直线。服务重启后若车辆已开锁但没有活动骑行，可建立活动骑行，将 `recovered_after_restart` 设为 1，并记录恢复原因。

Build 13 已落地 `trips`、`vehicle_state.active_trip_id`、`locations.trip_id`、`settings` 和 `cleanup_events`。确认开锁创建骑行，确认关锁结束骑行，可信 H0 会在重连时校正遗漏的开始或结束。只累计 10 分钟内相邻可靠点距离，历史详情按同一阈值断线。7 天扩为 30 天立即生效，30 天缩为 7 天在确认后的下一次清理生效；已结束骑行按结束时间整段清理，活动骑行不参与清理。

## 6. 告警

### 6.1 `alarms`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | TEXT PK | 告警 UUID |
| `vehicle_id` | TEXT FK | 车辆 |
| `type` | TEXT | `illegal_movement`、`suspected_offline_movement`、`fall`、`tamper`、`low_battery` |
| `state` | TEXT | `active`、`acknowledged`、`cleared` |
| `inferred` | INTEGER | 是否为重连后推断告警 |
| `first_triggered_at` | INTEGER | 首次触发 |
| `last_triggered_at` | INTEGER | 最近触发 |
| `trigger_count` | INTEGER | 合并次数 |
| `acknowledged_at` | INTEGER NULL | 用户确认时间 |
| `cleared_at` | INTEGER NULL | 解除时间 |
| `acknowledged_by` | TEXT NULL FK | 客户端 |
| `position_command_id` | TEXT NULL FK | 立即定位命令 |
| `note` | TEXT NULL | 用户备注，不存秘密 |
| `offline_started_at` | INTEGER NULL | 推断所用断连时间 |
| `baseline_location_id` | INTEGER NULL | 断网前停车基线 |
| `reconnect_location_one_id` | INTEGER NULL | 第一次重连定位 |
| `reconnect_location_two_id` | INTEGER NULL | 第二次重连定位 |
| `baseline_distance_one_m` | REAL NULL | 第一次定位相对基线距离 |
| `baseline_distance_two_m` | REAL NULL | 第二次定位相对基线距离 |
| `sample_distance_m` | REAL NULL | 两次重连定位间距 |
| `movement_threshold_m` | REAL NULL | 当次使用的位移阈值 |
| `sample_max_separation_m` | REAL NULL | 当次使用的样本一致性阈值 |

同类活动告警在 60 秒窗口内增加 `trigger_count`，不重复创建。活动异常移动告警通过部分唯一索引限制为一条。

`suspected_offline_movement` 必须满足：断网前存在可信停车位置、重连时仍确认关锁、两次重连定位均有效且通过漂移过滤。定位阈值由户外验收配置，告警详情必须展示“推断”标签和用于比较的位置时间。

关锁门禁在流程层和数据库层各执行一次。双定位期间收到任何 H0 开锁会清除待检查基线并终止流程；最终距离评估还会重新读取当前锁状态，即使位置满足阈值，评估时不是关锁也不得创建推断告警。

Build 12 已落地 `alarms`、`alarm_events`、`vehicle_state.grace_until`、`vehicle_state.active_alarm_id` 和 `locations.alarm_id`。Build 14 增加 `vehicle_state.offline_since`、`parked_location_id` 和告警比较字段，持久化断连基线、两次重连定位、比较距离及当次阈值。等待期抑制、活动告警、用户确认、授权开锁解除和离线推断均在 SQLite 事务中处理。

### 6.2 `alarm_events`

追加保存设备触发、等待期抑制、合并、立即定位、D1 切换、用户确认、授权开锁解除等事件。等待期内收到的 `W0` 只写 `alarm_events`，并标记 `suppressed_by_grace_period`。

## 7. 设置与客户端

### 7.1 `settings`

采用强类型固定键：

| key | 允许值 | 默认值 |
| --- | --- | --- |
| `location_history_days` | 7、30 | 7 |
| `lock_grace_seconds` | 固定 300 | 300 |
| `tracking_unlocked_seconds` | 固定 60 | 60 |
| `tracking_locked_seconds` | 固定 3600 | 3600 |
| `tracking_alarm_seconds` | 固定 300 | 300 |
| `find_sound_cooldown_seconds` | 固定 10 | 10 |
| `connection_silent_seconds` | 固定 420 | 420 |
| `connection_offline_seconds` | 固定 720 | 720 |

首版只有 `location_history_days` 可由 App 修改，其余值作为服务端受控配置展示。

### 7.2 `clients` 与 `request_nonces`

`clients` 保存 `client_id`、显示名称、只读公钥、控制公钥、权限、创建时间、最后使用时间和撤销时间。`request_nonces` 保存 nonce 摘要、客户端和失效时间，定时删除。撤销客户端后立即拒绝所有新请求，不物理删除历史审计归属。

## 8. 事务边界

- 开锁成功：更新命令终态、锁状态、安全状态、活动告警、创建骑行和 D1 期望值，置于同一事务。
- 关锁成功：更新命令终态、锁状态、`grace_until`、结束骑行和 D1 期望值，置于同一事务。
- W0 触发：写告警事件、创建或合并告警、更新安全状态，并创建一个包含 D1、D0 阶段的内部复合命令，置于同一事务。两个协议步骤串行执行，不形成两个并发在途命令。
- 用户解除：更新告警、车辆安全状态、审计和新的 D1 期望值，置于同一事务。
- BLE 事件：插入或命中事件 UUID，判断 24 小时有效期，再原子更新锁、安全、骑行和审计。IoT 离线时不创建 D1 命令。
- IoT 重连：收到新的 H0 后更新确认状态，再创建全新的策略协调或离线移动检查命令。不得恢复旧的 `rejected` 命令。

TCP 写入发生在事务提交之后。发送前服务端再次确认命令仍为可发送状态，避免数据库回滚后设备已执行。

## 9. 保留、清理与恢复

- 完成的骑行及其位置按 `location_history_days` 保留。以骑行结束时间计算，避免只留下半条轨迹。
- 不属于骑行的普通定位按接收时间保留 7 或 30 天。
- 活动骑行、活动告警及其完整事件链、当前车辆快照不参与清理。
- 已结束告警、命令、命令事件和审计记录首版保留 30 天。
- BLE 事件保留 30 天，超过 24 小时只影响其业务生效资格，不影响审计保留期。
- 会话明细保留 7 天，只在车辆快照保留最后通信摘要。
- nonce 到期即删除。

Build 16 的每日事务已同时清理 30 天前的 BLE 事件与观察、终态命令及事件、结束告警及事件和审计，以及 7 天前已经结束的设备会话。

清理任务每天 `03:30` 按 `Asia/Shanghai` 执行，在单个事务中先记录预计数量，再删除并写审计结果。30 天切换到 7 天时由 App 二次确认，下一次清理生效。7 天切换到 30 天不能恢复已删除记录。

每日清理后使用 SQLite 在线备份生成一个加密恢复副本，并替换上一份。因此刚到期的数据最多可能在恢复副本中多存在 24 小时。恢复操作只能人工执行，并在恢复后立即重新运行清理任务。

恢复副本实现使用 systemd 每天在 03:45 触发，晚于 03:30 的清理任务。在线快照归档只允许 `iot.sqlite3` 和带数据库大小、SHA-256、创建时间的 `manifest.json`，再以 CMS AES-256-CBC 和专用 RSA 接收者证书加密。服务器只保存公钥证书和 `latest.cms`、`latest.json`，恢复私钥只保存在管理员 Mac 登录钥匙串。人工解密后必须验证归档成员、大小、摘要和 `PRAGMA integrity_check`，校验工具不覆盖已有目标数据库。

revision `469f154` 已重新验证每日 timer 和当前线上密文。部署验收从服务器下载该密文，在持有恢复身份的 Mac 上完成钥匙串解密、归档校验、18 张表和 SQLite 完整性检查，未替换线上数据库，全部临时密文随后清理。

## 10. 数据校验

- 所有枚举使用 `CHECK` 约束。
- 经纬度范围、间隔允许值和百分比范围使用 `CHECK` 约束。
- 启用 `PRAGMA foreign_keys=ON`、`journal_mode=WAL`、`busy_timeout`。
- 迁移具有递增版本并在事务中执行，失败时服务拒绝启动，不带着半迁移结构运行。
- 测试覆盖终态不可逆、离线请求全部拒绝、重连不重放、单一在途命令、BLE 事件 24 小时去重、D1 期望与确认分离、推断告警、告警合并、跨清理边界骑行和客户端撤销。

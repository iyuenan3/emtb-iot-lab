# IoT TCP 临时调试服务

本目录用于单台已授权 IoT 设备的独立 TCP 调试。默认模式只接收目标 IMEI 的上行报文，也可以通过明确参数执行一次性的 `D1`、`S5` 配置计划。服务不依赖数据库、Redis、消息队列或现有业务服务。

## 安全边界

- 首个有效报文的 IMEI 不匹配时立即断开。
- 仅接受设备上行头 `*SCOR` 和 `*CMDR`。
- `K0` 密钥报文自动脱敏，不把密钥写入日志。
- 单帧最大 4096 字节，最多同时保留 4 个连接。
- 日志目录权限为 `700`，日志文件权限为 `600`。
- 日志最多保留约 30 MB。
- 下行配置默认禁用，启用后仅按 `D1` 回包成功再发送 `S5`，不自动重试。
- 命令计划完成后保持采集模式，后续重连不会重复发送。

一次性实车测试使用白名单参数，例如声音找车：

```bash
python3 server.py \
  --host 0.0.0.0 \
  --port 19680 \
  --target-imei '<目标 IMEI>' \
  --log-dir ./runtime/logs \
  --one-shot-test v0-find
```

允许值为 `d0`、`s5-query`、`s6`、`v0-find`、`l5-wheel-query`、`l0-unlock`、`l1-lock`。普通查询只发送一次并等待匹配回包。开锁和关锁严格执行 `R0` 一次性 KEY 请求、`L0` 或 `L1` 控制、结果校验和服务器确认，不自动重试。

## 本地验证

```bash
cd iot-tcp-lab
python3 -m unittest -v
```

本地启动示例：

```bash
python3 server.py \
  --host 127.0.0.1 \
  --port 19680 \
  --target-imei '<目标 IMEI>' \
  --log-dir ./runtime/logs
```

一次性关闭定位跟踪和解锁状态 S6 定时上报，并把 H0 心跳间隔设为 3600 秒：

```bash
python3 server.py \
  --host 127.0.0.1 \
  --port 19680 \
  --target-imei '<目标 IMEI>' \
  --log-dir ./runtime/logs \
  --disable-location-tracking \
  --disable-unlocked-telemetry \
  --reporting-interval-seconds 3600
```

配置计划会先用全零 `S5` 读取当前值，再依次发送 `D1,0` 和
`S5,0,1,3600,0`。加速度计灵敏度与原 S6 间隔保持不变。任一步回包不匹配时
计划立即失败，不重试，也不继续发送后续写入。

协议没有提供单独的关锁状态 S6 周期间隔字段。关锁时仍可能出现事件触发的 S6 上报。

## 服务器运行约定

正式临时实例应使用独立 TCP 端口。程序和运行日志放在隔离目录中，不修改同机其他项目配置。查看最新事件：

```bash
tail -n 50 runtime/logs/events.jsonl
```

所有下行命令必须通过目标 IMEI、设备回包和最终日志三重核对。密钥轮换使用权限为 `600` 的一次性文件传入 `--rotate-key-file`。程序启动时读取并立即删除该文件，日志只记录脱敏字段和验证结果，不记录密钥。轮换计划不自动重试，也不与报告间隔配置计划混用。

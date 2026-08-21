# IoT 远程调试服务

本目录提供单车专用的 IoT TCP 接入和 iPhone HTTP API。服务不接入原业务数据库，也不依赖第三方 Python 包。

## 当前能力

- 校验目标 IMEI，拒绝其他设备。
- 保存在线状态、锁状态、电量、设备信息、定位、指令和状态时间线。
- 支持声音找车、设备信息刷新、单次定位、远程开锁和人工确认后的远程关锁。
- 接收 App 签名的 BLE 主锁观察，只更新服务器状态，不创建车辆命令。
- 使用一次性配对码、读取令牌和 Secure Enclave P-256 请求签名。
- 420 秒未收到有效设备报文时进入通信静默，720 秒时判定离线并禁用控制。
- `/healthz` 返回部署版本、设备连接状态和最后有效报文年龄，部署后可独立读回版本。
- `SIGINT` 与 `SIGTERM` 会先停止接收新连接，再关闭活动设备会话和监听，把执行中命令标为结果未知，最后干净退出。
- 定位原始点完整留存，地图只使用通过设备时间、卫星数、HDOP、顺序和速度检查的点。
- 锁状态变化后协调 D1 定位策略，分别保存期望值和设备确认值，超时不自动重发。
- 物理关锁确认后进入 5 分钟等待，支持独立手动布防、W0 事件抑制或告警、60 秒合并、告警解除，以及 D1 300 秒后串行 D0。
- 确认开锁与关锁维护骑行生命周期，可靠定位点形成估算轨迹；提供骑行历史、7 天或 30 天保留设置和每日 03:30 整段清理。

## 本地运行

```bash
cd iot-remote
python3 -m iot_remote pairing-code --db var/iot.sqlite3
python3 -m iot_remote serve \
  --db var/iot.sqlite3 \
  --target-imei '<目标 IMEI>' \
  --tcp-port 19680 \
  --http-port 18081 \
  --location-min-satellites 4 \
  --location-max-hdop 8.0 \
  --location-max-speed-mps 25.0
```

HTTP 默认只监听 `127.0.0.1:18081`，部署时应由反向代理提供 HTTPS。不要直接把 HTTP 端口暴露到公网。TCP 端口供 IoT 设备连接，同一时刻只能有一个服务监听。

## 测试

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

## 部署

将 `.env.example` 复制为部署机上的 `.env`，填写真实设备和监听参数。定位质量阈值也由该文件集中配置，默认至少 4 颗卫星、HDOP 不高于 8、相邻可靠点估算速度不高于 25 米每秒。发布时把 `EMTB_IOT_REVISION` 设置为当前 Git SHA。数据库目录权限应为 `700`，数据库文件与环境文件权限应为 `600`。部署前确认 TCP 端口的唯一监听者、反向代理路由和健康检查，切换时保留可恢复备份。切换时还要确认旧服务在 `TimeoutStopSec` 内以 `Result=success` 停止，不能把 systemd 强制杀死当成正常退出。部署完成必须从公网 `/iot/healthz` 读回相同 revision，不能只相信服务重启结果。

2026 年 8 月 22 日部署基线为 Git revision `dae2fc8`。`emtb-iot-remote.service` 已通过远端 Python 3.12 的 49 项测试、内部 readiness、公网 revision、未认证 API 401、主页 200、源码哈希、告警数据库迁移与权限检查。设备在新版本上自动重连，真实活动 IoT 长连接下完成 `Result=success` 停止并再次恢复在线。旧源码、unit 和 SQLite 在线备份均保留为回滚材料。真实 W0、D1 回包与告警定位链仍待实车验收。

不得提交真实 IMEI、配对码、令牌、控制私钥、数据库、日志或服务器现场记录。

# IoT 远程调试服务

本目录提供单车专用的 IoT TCP 接入和 iPhone HTTP API。服务不接入原业务数据库，也不依赖第三方 Python 包。

## 当前能力

- 校验目标 IMEI，拒绝其他设备。
- 保存在线状态、锁状态、电量、设备信息、定位、指令和状态时间线。
- 支持声音找车、设备信息刷新、单次定位、远程开锁和人工确认后的远程关锁。
- 接收 App 签名的 BLE 主锁观察，只更新服务器状态，不创建车辆命令。
- 使用一次性配对码、读取令牌和 Secure Enclave P-256 请求签名。

## 本地运行

```bash
cd iot-remote
python3 -m iot_remote pairing-code --db var/iot.sqlite3
python3 -m iot_remote serve \
  --db var/iot.sqlite3 \
  --target-imei '<目标 IMEI>' \
  --tcp-port 19680 \
  --http-port 18081
```

HTTP 默认只监听 `127.0.0.1:18081`，部署时应由反向代理提供 HTTPS。不要直接把 HTTP 端口暴露到公网。TCP 端口供 IoT 设备连接，同一时刻只能有一个服务监听。

## 测试

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

## 部署

将 `.env.example` 复制为部署机上的 `.env`，填写真实设备和监听参数。数据库目录权限应为 `700`，数据库文件与环境文件权限应为 `600`。部署前确认 TCP 端口的唯一监听者、反向代理路由和健康检查，切换时保留可恢复备份。

不得提交真实 IMEI、配对码、令牌、控制私钥、数据库、日志或服务器现场记录。

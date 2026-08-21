import SwiftUI

struct RemoteControlView: View {
    @EnvironmentObject private var remote: RemoteControlManager
    @EnvironmentObject private var device: BLEDeviceManager
    @State private var pairingCode = ""

    var body: some View {
        Form {
            if remote.isPaired {
                vehicleSection
                telemetrySection
                actionSection
                commandSection
                configurationSection
            } else {
                pairingSection
            }
            if remote.isBusy || !remote.message.isEmpty {
                Section("状态") {
                    HStack {
                        if remote.isBusy { ProgressView() }
                        Text(remote.message)
                    }
                }
            }
        }
        .navigationTitle("远程控制")
        .toolbar {
            if remote.isPaired {
                Button("刷新") { Task { await remote.refresh() } }.disabled(remote.isBusy)
            }
        }
        .task { if remote.isPaired { await remote.refresh() } }
    }

    private var pairingSection: some View {
        Section("连接远程服务") {
            TextField("https://你的服务域名/iot", text: $remote.serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("一次性配对码", text: $pairingCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("完成配对") { Task { await remote.pair(code: pairingCode) } }
                .disabled(remote.isBusy || pairingCode.isEmpty || remote.serverURL.isEmpty)
            Text("控制私钥由 iPhone 安全隔区生成，设备蓝牙密钥不会上传到服务器。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var vehicleSection: some View {
        Section("车辆") {
            LabeledContent("设备", value: remote.vehicle?.displayName ?? "未读取")
            LabeledContent("网络", value: connectivityText)
            LabeledContent("服务器锁状态", value: lockText)
            LabeledContent("状态来源", value: lockSourceText)
            if device.isReady, let isLocked = device.snapshot.isLocked {
                LabeledContent("BLE 近场状态", value: isLocked ? "已关锁" : "已开锁")
                if let serverLocked, serverLocked != isLocked {
                    Label("两端状态不一致，当前界面优先采用 BLE，并正在同步服务器。", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            LabeledContent("电量", value: remote.vehicle?.batteryPercent.map { "\($0)%" } ?? "未读取")
            LabeledContent("布防", value: securityText)
            if let graceUntil = remote.vehicle?.graceUntil {
                LabeledContent(
                    "自动布防时间",
                    value: Date(timeIntervalSince1970: TimeInterval(graceUntil))
                        .formatted(date: .abbreviated, time: .standard)
                )
            }
            LabeledContent("定位策略", value: trackingPolicyText)
            LabeledContent("最后通信", value: lastSeenText)
        }
    }

    private var connectivityText: String {
        switch remote.vehicle?.connectionState {
        case "online": return "IoT 在线"
        case "silent": return "通信静默"
        default: return "IoT 离线"
        }
    }

    private var actionSection: some View {
        Section("远程操作") {
            LongPressActionButton(
                title: "长按远程开锁", icon: "lock.open", color: .orange,
                enabled: capability("vehicle.unlock") && !remote.isBusy
            ) { Task { await remote.send("vehicle.unlock", requiresOwnerPresence: true) } }
            LongPressActionButton(
                title: "长按远程关锁", icon: "lock", color: .blue,
                enabled: capability("vehicle.lock") && !remote.isBusy
            ) {
                Task {
                    await remote.send(
                        "vehicle.lock",
                        requiresOwnerPresence: true,
                        parameters: ["stationary_confirmed": true]
                    )
                }
            }
            Button("声音找车", systemImage: "speaker.wave.2") {
                Task { await remote.send("vehicle.find_sound") }
            }
            .disabled(!capability("vehicle.find_sound") || remote.isBusy)
            Button("读取最新设备信息", systemImage: "arrow.clockwise") {
                Task { await remote.send("telemetry.refresh") }
            }
            .disabled(!capability("telemetry.refresh") || remote.isBusy)
            Button("请求单次定位", systemImage: "location") {
                Task { await remote.send("location.once") }
            }
            .disabled(!capability("location.once") || remote.isBusy)
            Text("远程关锁前请确认车辆完全停稳且无人骑行。IoT 成功回包后，仍需现场确认仪表熄灭、车辆动力断开、轮毂不能转动。")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    private var telemetrySection: some View {
        Section("最新设备信息（S6）") {
            if let fields = remote.vehicle?.telemetryFields, !fields.isEmpty {
                LabeledContent("当前电量", value: "\(fields[0])%")
                LabeledContent("回包时间", value: telemetryTimeText)
                ForEach(Array(fields.dropFirst().enumerated()), id: \.offset) { index, value in
                    LabeledContent("原始字段 \(index + 2)", value: value)
                }
                Text("厂商协议只确认第 1 个字段为车端电量，其余字段包含预留项，当前按原始值展示，不推测含义。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("尚未读取。点击下方“读取最新设备信息”后显示设备回包。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var commandSection: some View {
        Section("最近指令") {
            if remote.commands.isEmpty {
                Text("暂无远程指令")
            } else {
                ForEach(remote.commands.prefix(10)) { command in
                    LabeledContent(commandName(command.commandType), value: statusName(command.status))
                }
            }
        }
    }

    private var configurationSection: some View {
        Section("远程服务") {
            LabeledContent("地址", value: remote.serverURL)
            Button("清除远程配对", role: .destructive) { remote.clearPairing() }
        }
    }

    private var lockText: String {
        switch remote.vehicle?.lockState {
        case "locked": return "已关锁"
        case "unlocked": return "已开锁"
        default: return "未知"
        }
    }

    private var securityText: String {
        switch remote.vehicle?.securityState {
        case "disarmed": return "已撤防"
        case "grace_period": return "等待布防"
        case "armed": return "已布防"
        case "alarm_active": return "告警中"
        default: return "未读取"
        }
    }

    private var serverLocked: Bool? {
        switch remote.vehicle?.lockState {
        case "locked": return true
        case "unlocked": return false
        default: return nil
        }
    }

    private var lastSeenText: String {
        guard let timestamp = remote.vehicle?.lastSeenAt else { return "未读取" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(date: .abbreviated, time: .standard)
    }

    private var lockSourceText: String {
        switch remote.vehicle?.lockStateSource {
        case "ble": return "BLE 回读"
        case "iot_h0": return "IoT H0"
        case "remote_command": return "远程命令回包"
        default: return "旧状态或未知"
        }
    }

    private var telemetryTimeText: String {
        guard let timestamp = remote.vehicle?.telemetryUpdatedAt else { return "未读取" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(date: .abbreviated, time: .standard)
    }

    private var trackingPolicyText: String {
        guard let desired = remote.vehicle?.desiredTrackingInterval else { return "未配置" }
        guard remote.vehicle?.confirmedTrackingInterval == desired else {
            let confirmed = remote.vehicle?.confirmedTrackingInterval.map { "\($0) 秒" } ?? "无"
            return "目标 \(desired) 秒，设备确认 \(confirmed)"
        }
        return "已确认 \(desired) 秒"
    }

    private func capability(_ name: String) -> Bool {
        remote.capabilities[name]?.enabled == true
    }

    private func commandName(_ value: String) -> String {
        ["vehicle.unlock": "开锁", "vehicle.lock": "关锁", "vehicle.find_sound": "声音找车",
         "telemetry.refresh": "读取设备信息", "location.once": "单次定位",
         "tracking.set_policy": "定位策略", "security.confirm_locked": "确认物理关锁",
         "security.arm": "手动布防", "alarm.acknowledge": "解除告警"][value] ?? value
    }

    private func statusName(_ value: String) -> String {
        ["accepted": "已受理", "prechecking": "检查中", "awaiting_r0": "正在鉴权",
         "awaiting_result": "等待设备", "succeeded": "成功", "failed": "失败",
         "unknown": "结果未知", "noop": "状态已满足", "rejected": "已拒绝"][value] ?? value
    }
}

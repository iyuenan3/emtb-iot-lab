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
            if remote.pendingBLEEventCount > 0 {
                Section("BLE 事件队列") {
                    LabeledContent("待补报", value: "\(remote.pendingBLEEventCount) 条")
                    if remote.isPaired {
                        Button("立即补报", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await remote.flushPendingBLEEvents() }
                        }
                        .disabled(remote.isBusy)
                    } else {
                        Text("完成远程配对后将自动补报，请勿卸载 App。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
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
        case "ble_event": return "BLE 操作事件"
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

struct CommandCenterView: View {
    @EnvironmentObject private var remote: RemoteControlManager

    private let groupOrder = [
        "常用控制", "状态与诊断", "外部锁", "车辆设置", "事件",
        "安全状态", "密钥与升级", "内部流程", "归档扩展", "其他"
    ]

    var body: some View {
        List {
            Section {
                Text("目录由服务端审核清单与 App 内置 BLE 清单合并生成。这里不提供原始协议输入，也不会把未验证、内部流程或危险维护能力转换成执行按钮。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(groupedCatalog, id: \.0) { group, items in
                Section(group) {
                    ForEach(items) { item in
                        capabilityRow(item)
                    }
                }
            }
        }
        .navigationTitle("指令中心")
        .toolbar {
            if remote.isPaired {
                Button("刷新") { Task { await remote.refresh() } }
                    .disabled(remote.isBusy)
            }
        }
        .task { if remote.isPaired { await remote.refresh() } }
    }

    private var groupedCatalog: [(String, [CapabilityDisplayItem])] {
        let grouped = Dictionary(grouping: remote.capabilityCatalog, by: \.group)
        return grouped.keys.sorted { lhs, rhs in
            (groupOrder.firstIndex(of: lhs) ?? groupOrder.count)
                < (groupOrder.firstIndex(of: rhs) ?? groupOrder.count)
        }.map { group in
            (group, grouped[group, default: []].sorted {
                if $0.channel == $1.channel { return $0.protocolName < $1.protocolName }
                return $0.channel < $1.channel
            })
        }
    }

    private func capabilityRow(_ item: CapabilityDisplayItem) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("通道", value: item.channel)
                LabeledContent("用途", value: item.purpose)
                LabeledContent("参数", value: item.parametersSchema)
                LabeledContent("持久化", value: item.persistence)
                LabeledContent("风险", value: item.risk)
                LabeledContent("执行入口", value: executionText(item))
                if let reason = item.disabledReason, !item.enabled {
                    LabeledContent("禁用原因", value: reasonText(reason))
                }
                if let latest = item.latestResult {
                    Divider()
                    LabeledContent("最后结果", value: statusText(latest.status))
                    LabeledContent("执行时间", value: date(latest.completedAt ?? latest.createdAt))
                    if let error = latest.errorCode {
                        LabeledContent("错误", value: error)
                    }
                    if !latest.rawResponseSummary.isEmpty {
                        Text("安全回包摘要")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(latest.rawResponseSummary)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } else {
                    Text("暂无执行记录")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.vertical, 6)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(item.protocolName).font(.caption.monospaced())
                }
                HStack(spacing: 6) {
                    Text(item.channel)
                    Text(item.supportStatus)
                        .foregroundStyle(statusColor(item.supportStatus))
                }
                .font(.caption)
            }
        }
    }

    private func executionText(_ item: CapabilityDisplayItem) -> String {
        if item.supportStatus != "实车已验证" {
            return "未完成实车验收"
        }
        if item.channel == "近场 BLE", item.executable {
            return "车辆首页固定入口"
        }
        if item.enabled, item.executable {
            return "现有固定入口可执行"
        }
        return "仅展示"
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "实车已验证": return .green
        case "只读上报", "内部流程": return .blue
        case "危险维护": return .red
        case "不适用": return .secondary
        default: return .orange
        }
    }

    private func statusText(_ status: String) -> String {
        ["accepted": "已受理", "prechecking": "检查中", "awaiting_r0": "正在鉴权",
         "awaiting_result": "等待设备", "succeeded": "成功", "failed": "失败",
         "unknown": "结果未知，可能延迟执行", "noop": "状态已满足",
         "rejected": "已拒绝"][status] ?? status
    }

    private func reasonText(_ reason: String) -> String {
        ["device_offline": "IoT 设备离线", "device_silent": "IoT 通信静默",
         "unsupported_hardware": "当前车辆硬件无回包", "catalog_only": "目录只展示",
         "physical_lock_not_confirmed": "尚未确认物理关锁",
         "no_active_alarm": "当前没有活动告警"][reason] ?? reason
    }

    private func date(_ timestamp: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(date: .abbreviated, time: .standard)
    }
}

struct RemoteAuditView: View {
    @EnvironmentObject private var remote: RemoteControlManager

    var body: some View {
        List {
            if !remote.isPaired {
                ContentUnavailableView(
                    "尚未连接远程服务",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("完成配对后可查看审计记录和设备会话。")
                )
            } else {
                sessionSection
                auditSection
            }
        }
        .navigationTitle("审计与会话")
        .toolbar {
            if remote.isPaired {
                Button("刷新") { Task { await remote.refresh() } }
                    .disabled(remote.isBusy)
            }
        }
        .task { if remote.isPaired { await remote.refresh() } }
    }

    private var sessionSection: some View {
        Section("设备会话") {
            if remote.deviceSessions.isEmpty {
                Text("暂无设备会话")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(remote.deviceSessions.prefix(20)) { session in
                    DisclosureGroup {
                        LabeledContent("连接时间", value: date(session.connectedAt))
                        LabeledContent("地址摘要", value: session.peerFingerprint)
                        LabeledContent("接收帧", value: "\(session.rxCount)")
                        LabeledContent("发送帧", value: "\(session.txCount)")
                        LabeledContent("解析错误", value: "\(session.parseErrorCount)")
                        LabeledContent("最后接收", value: optionalDate(session.lastRxAt))
                        LabeledContent("最后发送", value: optionalDate(session.lastTxAt))
                        LabeledContent("最后 Q0", value: optionalDate(session.lastQ0At))
                        LabeledContent("最后 H0", value: optionalDate(session.lastH0At))
                        if let seconds = session.silenceSeconds {
                            LabeledContent("当前静默", value: "\(seconds) 秒")
                        }
                        if let reason = session.offlineReason {
                            LabeledContent("结束原因", value: sessionReason(reason))
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(session.current ? "当前会话" : "历史会话")
                            Text("\(connectivityText(session.connectivityState)) · \(shortID(session.id))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("对端网络地址只保存带随机盐的 16 位摘要，无法从页面还原。会话详情保留 7 天。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var auditSection: some View {
        Section("最近审计") {
            if remote.auditLogs.isEmpty {
                Text("暂无审计记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(remote.auditLogs.prefix(100)) { item in
                    DisclosureGroup {
                        LabeledContent("操作者", value: actorText(item.actor))
                        LabeledContent("对象", value: "\(item.objectType) \(shortID(item.objectID))")
                        LabeledContent("结果", value: item.result)
                        LabeledContent("时间", value: date(item.createdAt))
                        if let requestID = item.requestID {
                            LabeledContent("请求", value: shortID(requestID))
                        }
                        if !item.detailSummary.isEmpty {
                            Text(item.detailSummary)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(actionText(item.action))
                            Text("\(item.result) · \(date(item.createdAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("审计不保存设备密钥、读取令牌、签名、nonce 或原始网络地址。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func actorText(_ actor: String) -> String {
        if actor == "system" { return "服务端系统" }
        if actor == "iot_device" { return "IoT 设备" }
        return "已配对 iPhone"
    }

    private func actionText(_ action: String) -> String {
        ["pairing.complete": "完成客户端配对", "command.created": "创建指令",
         "command.status": "指令状态变化", "trip.started": "骑行开始",
         "trip.completed": "骑行结束", "location.received": "接收定位",
         "settings.location_history.updated": "修改轨迹保留设置",
         "ble_event.received": "接收 BLE 操作事件",
         "ble_observation.received": "接收 BLE 状态回读",
         "device_session.connected": "设备会话建立",
         "device_session.closed": "设备会话结束",
         "retention.cleanup": "执行保留清理"][action] ?? action
    }

    private func connectivityText(_ value: String) -> String {
        ["online": "在线", "silent": "通信静默", "offline": "离线"][value] ?? value
    }

    private func sessionReason(_ value: String) -> String {
        ["replaced": "被新会话替换", "service_stopped": "服务停止",
         "receive_timeout": "接收超时", "connection_error": "连接错误",
         "peer_closed": "设备主动断开", "not_current": "非当前会话"][value] ?? value
    }

    private func shortID(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "无" }
        return String(value.prefix(8))
    }

    private func optionalDate(_ timestamp: Int?) -> String {
        timestamp.map(date) ?? "无"
    }

    private func date(_ timestamp: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(date: .abbreviated, time: .standard)
    }
}

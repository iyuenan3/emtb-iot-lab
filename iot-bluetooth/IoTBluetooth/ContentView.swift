import SwiftUI
import UniformTypeIdentifiers
import MapKit

struct ContentView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @EnvironmentObject private var remote: RemoteControlManager

    var body: some View {
        TabView {
            NavigationStack { VehicleHomeView() }
                .tabItem { Label("车辆", systemImage: "bicycle") }
            NavigationStack { VehicleMapView() }
                .tabItem { Label("地图", systemImage: "map") }
            NavigationStack { ActivityView() }
                .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
            NavigationStack { MoreView() }
                .tabItem { Label("更多", systemImage: "ellipsis.circle") }
        }
        .tint(.indigo)
        .onChange(of: device.lockStateUpdatedAt) { _, updatedAt in
            guard let updatedAt, let isLocked = device.snapshot.isLocked, remote.isPaired else { return }
            Task { await remote.syncBLELockState(isLocked: isLocked, observedAt: updatedAt) }
        }
        .onChange(of: device.completedLockEvent) { _, event in
            guard let event else { return }
            remote.enqueueBLEEvent(event)
        }
    }
}

private enum ControlChannel: String, CaseIterable, Identifiable {
    case remote = "远程"
    case bluetooth = "附近蓝牙"

    var id: String { rawValue }
}

private struct VehicleHomeView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @EnvironmentObject private var remote: RemoteControlManager
    @State private var channel = ControlChannel.remote

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                vehicleHero
                if let activeAlarm { alarmCard(activeAlarm) }
                controlCard
                if let lockConflictText { lockConflictBanner(lockConflictText) }
                statusGrid
                securityControlCard
                if !statusMessage.isEmpty { operationBanner }
                safetyNote
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("我的山地车")
        .refreshable { await refreshSelectedChannel() }
        .task {
            if remote.isPaired { await remote.refresh() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await remote.poll()
            }
        }
    }

    private var vehicleHero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.indigo, .blue.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "bicycle")
                .font(.system(size: 112, weight: .thin))
                .foregroundStyle(.white.opacity(0.14))
                .offset(x: 205, y: 8)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(channelStatusText, systemImage: channelStatusIcon)
                        .font(.caption.bold())
                    Spacer()
                    Text("电量 \(batteryText)").font(.caption.bold())
                }
                .foregroundStyle(.white.opacity(0.82))
                Spacer(minLength: 22)
                Image(systemName: lockIcon).font(.system(size: 36, weight: .semibold))
                Text(lockText).font(.system(size: 32, weight: .bold, design: .rounded))
                Label(lockSourceText, systemImage: lockSourceIcon)
                    .font(.caption.bold()).foregroundStyle(.white.opacity(0.82))
                Text("设备 \(IoTDeviceProfile.imei)")
                    .font(.caption.monospaced()).foregroundStyle(.white.opacity(0.72))
            }
            .padding(22)
        }
        .frame(height: 228)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .indigo.opacity(0.18), radius: 18, y: 10)
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("车辆控制").font(.headline)
                Spacer()
                Text("明确选择通道").font(.caption).foregroundStyle(.secondary)
            }
            Picker("控制通道", selection: $channel) {
                ForEach(ControlChannel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if channel == .remote { remoteControls } else { bluetoothControls }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder private var remoteControls: some View {
        if remote.isPaired {
            HStack(spacing: 12) {
                LongPressActionButton(title: "长按开锁", icon: "lock.open", color: .orange,
                                      enabled: remote.capabilities["vehicle.unlock"]?.enabled == true &&
                                          selectedLocked != false && !remote.isBusy) {
                    Task { await remote.send("vehicle.unlock", requiresOwnerPresence: true) }
                }
                LongPressActionButton(title: "长按关锁", icon: "lock", color: .indigo,
                                      enabled: remote.capabilities["vehicle.lock"]?.enabled == true &&
                                          selectedLocked != true && !remote.isBusy) {
                    Task {
                        await remote.send("vehicle.lock", requiresOwnerPresence: true,
                                          parameters: ["stationary_confirmed": true])
                    }
                }
            }
            HStack(spacing: 12) {
                Button {
                    Task { await remote.send("vehicle.find_sound") }
                } label: {
                    Label("声音找车", systemImage: "speaker.wave.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(remote.capabilities["vehicle.find_sound"]?.enabled != true || remote.isBusy)
                Button {
                    Task { await remote.send("location.once") }
                } label: {
                    Label("定位找车", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(remote.capabilities["location.once"]?.enabled != true || remote.isBusy)
            }
            .buttonStyle(.bordered)
        } else {
            ContentUnavailableView {
                Label("尚未连接远程服务", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text("先在更多页面完成一次性配对。")
            } actions: {
                NavigationLink("前往远程配对") { RemoteControlView() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private var bluetoothControls: some View {
        if device.isReady {
            HStack(spacing: 12) {
                LongPressActionButton(title: "长按开锁", icon: "lock.open", color: .orange,
                                      enabled: !device.isBusy && device.snapshot.isLocked != false) {
                    Task { await device.unlockWithOwnerAuthentication() }
                }
                LongPressActionButton(title: "长按关锁", icon: "lock", color: .indigo,
                                      enabled: !device.isBusy && device.snapshot.isLocked != true) {
                    Task { await device.lockWithOwnerAuthentication() }
                }
            }
            HStack {
                Button("刷新", systemImage: "arrow.clockwise") { device.refreshAll() }
                Spacer()
                Button("断开", systemImage: "xmark.circle") { device.disconnect() }
            }
            .buttonStyle(.bordered)
        } else {
            Button("扫描并连接车辆", systemImage: "antenna.radiowaves.left.and.right") { device.scanAndConnect() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(!device.deviceKeyStored)
            if !device.deviceKeyStored {
                Label("请先在更多页面保存 8 字节设备密钥", systemImage: "key")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricCard(title: "IoT 网络", value: networkText)
            MetricCard(title: "BLE", value: device.phase.rawValue)
            MetricCard(title: "车端电量", value: batteryText)
            MetricCard(title: "安全状态", value: securityText)
            MetricCard(title: "定位策略", value: trackingPolicyText)
        }
    }

    @ViewBuilder private var securityControlCard: some View {
        if remote.isPaired {
            VStack(alignment: .leading, spacing: 12) {
                Label("车辆布防", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                if let graceUntil = remote.vehicle?.graceUntil,
                   remote.vehicle?.securityState == "grace_period" {
                    Text("自动布防倒计时")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(
                        timerInterval: Date()...max(
                            Date(), Date(timeIntervalSince1970: TimeInterval(graceUntil))
                        ),
                        countsDown: true
                    )
                    .font(.title2.monospacedDigit().bold())
                } else if remote.vehicle?.securityState == "disarmed" {
                    if selectedLocked == true {
                        Text("现场确认仪表熄灭、动力断开、轮毂不能转动后，再启动 5 分钟等待。")
                            .font(.footnote).foregroundStyle(.orange)
                        LongPressActionButton(
                            title: "长按确认物理关锁", icon: "checkmark.shield", color: .indigo,
                            enabled: remote.capabilities["security.confirm_locked"]?.enabled == true
                                && !remote.isBusy
                        ) {
                            Task {
                                await remote.send(
                                    "security.confirm_locked", requiresOwnerPresence: true,
                                    parameters: ["physical_lock_confirmed": true]
                                )
                            }
                        }
                    }
                    Text("手动布防不会改变机械锁。车辆仍开锁时也可使用，但必须明确承担误触风险。")
                        .font(.footnote).foregroundStyle(.secondary)
                    LongPressActionButton(
                        title: "长按手动布防", icon: "shield.fill", color: .orange,
                        enabled: remote.capabilities["security.arm"]?.enabled == true
                            && !remote.isBusy
                    ) {
                        Task {
                            await remote.send(
                                "security.arm", requiresOwnerPresence: true,
                                parameters: ["unlocked_warning_confirmed": true]
                            )
                        }
                    }
                } else {
                    Text(securityText).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
        }
    }

    private func alarmCard(_ alarm: RemoteAlarm) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(alarm.inferred ? "疑似离线期间移动" : "车辆异常移动", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.bold())
            Text("触发 \(alarm.triggerCount) 次，最近一次 \(Date(timeIntervalSince1970: TimeInterval(alarm.lastTriggeredAt)).formatted(date: .abbreviated, time: .standard))")
                .font(.callout)
            if alarm.inferred {
                Text("服务端根据两次重连定位推断，不是实时 W0。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let baseline = alarm.baselineCapturedAt,
                   let reconnect = alarm.reconnectCapturedAt {
                    Text("停车位置 \(Date(timeIntervalSince1970: TimeInterval(baseline)).formatted(date: .abbreviated, time: .standard))，重连定位 \(Date(timeIntervalSince1970: TimeInterval(reconnect)).formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("确认并解除", systemImage: "checkmark.shield.fill") {
                    Task {
                        await remote.send("alarm.acknowledge", requiresOwnerPresence: true)
                    }
                }
                .disabled(remote.capabilities["alarm.acknowledge"]?.enabled != true || remote.isBusy)
                Button("声音找车", systemImage: "speaker.wave.2.fill") {
                    Task { await remote.send("vehicle.find_sound") }
                }
                .disabled(remote.capabilities["vehicle.find_sound"]?.enabled != true || remote.isBusy)
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.red)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 22))
    }

    private var operationBanner: some View {
        HStack(spacing: 12) {
            if isBusy { ProgressView() }
            Image(systemName: isBusy ? "hourglass" : "info.circle")
                .foregroundStyle(.indigo)
            Text(statusMessage).font(.callout)
            Spacer()
        }
        .padding()
        .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func lockConflictBanner(_ message: String) -> some View {
        Label(message, systemImage: "arrow.triangle.2.circlepath.circle.fill")
            .font(.callout).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }

    private var safetyNote: some View {
        Label("开关锁必须长按 1.2 秒。远程关锁前请确认车辆停稳，系统不会在通道之间自动补发。", systemImage: "checkmark.shield")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private var selectedLocked: Bool? {
        bleLocked ?? remoteLocked
    }

    private var bleLocked: Bool? {
        device.isReady ? device.snapshot.isLocked : nil
    }

    private var remoteLocked: Bool? {
        switch remote.vehicle?.lockState {
        case "locked": return true
        case "unlocked": return false
        default: return nil
        }
    }

    private var lockSourceText: String {
        if bleLocked != nil { return "近场 BLE 实时回读" }
        if remoteLocked != nil { return "服务器最近状态" }
        return "尚无可信状态来源"
    }

    private var lockSourceIcon: String {
        bleLocked != nil ? "antenna.radiowaves.left.and.right" : "cloud"
    }

    private var lockConflictText: String? {
        guard let bleLocked, let remoteLocked, bleLocked != remoteLocked else { return nil }
        let bleText = bleLocked ? "已关锁" : "已开锁"
        let remoteText = remoteLocked ? "已关锁" : "已开锁"
        return "状态冲突：BLE 为\(bleText)，服务器为\(remoteText)。当前采用 BLE，并正在同步。"
    }

    private var lockText: String {
        switch selectedLocked { case true: return "车辆已关锁"; case false: return "车辆已开锁"; case nil: return "锁状态未知" }
    }

    private var lockIcon: String {
        switch selectedLocked { case true: return "lock.fill"; case false: return "lock.open.fill"; case nil: return "questionmark.circle" }
    }

    private var networkText: String {
        guard remote.isPaired else { return "未配对" }
        switch remote.vehicle?.connectionState {
        case "online": return "IoT 在线"
        case "silent": return "通信静默"
        default: return "IoT 离线"
        }
    }

    private var channelStatusText: String {
        channel == .remote ? networkText : device.phase.rawValue
    }

    private var channelStatusIcon: String {
        if channel == .bluetooth {
            return device.isReady ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
        }
        switch remote.vehicle?.connectionState {
        case "online": return "dot.radiowaves.left.and.right"
        case "silent": return "exclamationmark.arrow.triangle.2.circlepath"
        default: return "wifi.slash"
        }
    }

    private var batteryText: String {
        let value = channel == .remote ? remote.vehicle?.batteryPercent : device.snapshot.scooterBatteryPercent
        return value.map { "\($0)%" } ?? "未读取"
    }

    private var securityText: String {
        switch remote.vehicle?.securityState {
        case "armed": return "已布防"
        case "disarmed": return "已撤防"
        case "grace_period": return "等待布防"
        case "alarm_active": return "告警中"
        default: return "未读取"
        }
    }

    private var activeAlarm: RemoteAlarm? {
        remote.alarms.first(where: { $0.state == "active" })
    }

    private var trackingPolicyText: String {
        guard let desired = remote.vehicle?.desiredTrackingInterval else { return "未配置" }
        guard remote.vehicle?.confirmedTrackingInterval == desired else {
            return "目标 \(desired) 秒，未确认"
        }
        return "\(desired) 秒"
    }

    private var statusMessage: String { channel == .remote ? remote.message : device.operationMessage }
    private var isBusy: Bool { channel == .remote ? remote.isBusy : device.isBusy }

    private func refreshSelectedChannel() async {
        if channel == .remote, remote.isPaired { await remote.refresh() }
        if channel == .bluetooth, device.isReady { device.refreshAll() }
    }
}

private struct VehicleMapView: View {
    @EnvironmentObject private var remote: RemoteControlManager
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                mapCard
                if let latest = remote.latestLocation { locationDetails(latest) }
                if remote.lastLocationReport?.displayEligible == false { invalidLocationNotice }

                Button("定位找车", systemImage: "location.fill") {
                    Task { await remote.send("location.once") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(remote.capabilities["location.once"]?.enabled != true || remote.isBusy)

                Label("定位来自车辆 IoT 的 D0，不读取手机 GPS。轨迹按设备 UTC 时间连接，无效点不会覆盖车辆标记。", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("车辆位置")
        .task {
            if remote.isPaired { await remote.refresh() }
            focusLatestLocation()
        }
        .onChange(of: remote.latestLocation?.id) { _, _ in focusLatestLocation() }
    }

    @ViewBuilder private var mapCard: some View {
        if let coordinate = latestCoordinate {
            Map(position: $camera) {
                ForEach(Array(routeSegments.enumerated()), id: \.offset) { _, coordinates in
                    if coordinates.count > 1 {
                        MapPolyline(coordinates: coordinates)
                            .stroke(.indigo, lineWidth: 4)
                    }
                }
                Marker("我的山地车", systemImage: "bicycle", coordinate: coordinate)
                    .tint(.indigo)
            }
            .mapStyle(.standard(elevation: .realistic))
            .frame(height: 390)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            ZStack {
                LinearGradient(colors: [.cyan.opacity(0.18), .indigo.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 14) {
                    Image(systemName: "map.fill").font(.system(size: 54)).foregroundStyle(.indigo)
                    Text("还没有有效车辆位置").font(.title3.bold())
                    Text("点击“定位找车”请求一次 D0。设备返回有效 GPS 后，车辆标记会显示在这里。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(28)
            }
            .frame(height: 310)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    private func locationDetails(_ location: RemoteLocation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("最后有效位置", systemImage: "location.circle.fill").font(.headline)
                Spacer()
                Text(locationTime(location), style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            LabeledContent("采集时间", value: locationTime(location).formatted(date: .abbreviated, time: .standard))
            LabeledContent("卫星数", value: location.satellites.map(String.init) ?? "未提供")
            LabeledContent("HDOP", value: location.hdop.map { String(format: "%.2f", $0) } ?? "未提供")
            if let altitude = location.altitudeM {
                LabeledContent("海拔", value: String(format: "%.1f 米", altitude))
            }
            LabeledContent("来源", value: location.source == "once" ? "单次定位" : "追踪上报")
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var invalidLocationNotice: some View {
        Label(locationRejectionText, systemImage: "location.slash.fill")
            .font(.callout).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }

    private var locationRejectionText: String {
        guard let report = remote.lastLocationReport else { return "最近定位不可用于地图。" }
        if !report.valid {
            return "最近一次 D0 已返回，但 GPS 状态为无效。地图继续保留上一个可靠位置。"
        }
        let reason = [
            "timestamp_missing": "设备时间缺失",
            "timestamp_future": "设备时间超前",
            "insufficient_satellites": "卫星数不足",
            "poor_hdop": "定位精度不足",
            "out_of_order": "定位点乱序",
            "excessive_speed": "瞬时位移或速度异常",
        ][report.rejectionReason ?? ""] ?? "定位质量检查未通过"
        return "最近一次 D0 因\(reason)未进入地图，继续保留上一个可靠位置。"
    }

    private var latestCoordinate: CLLocationCoordinate2D? {
        guard let location = remote.latestLocation,
              let latitude = location.latitude, let longitude = location.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var routeSegments: [[CLLocationCoordinate2D]] {
        var result: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []
        var previousTime: Int?
        for location in remote.locations {
            guard let latitude = location.latitude, let longitude = location.longitude else { continue }
            let timestamp = location.deviceTimestamp ?? location.receivedAt
            if let previousTime, timestamp - previousTime > 600, !current.isEmpty {
                result.append(current)
                current = []
            }
            current.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            previousTime = timestamp
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func locationTime(_ location: RemoteLocation) -> Date {
        Date(timeIntervalSince1970: TimeInterval(location.deviceTimestamp ?? location.receivedAt))
    }

    private func focusLatestLocation() {
        guard let coordinate = latestCoordinate else { return }
        camera = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        ))
    }
}

private struct ActivityView: View {
    @EnvironmentObject private var remote: RemoteControlManager

    var body: some View {
        List {
            Section("最近指令") {
                if remote.commands.isEmpty {
                    ContentUnavailableView("暂无指令记录", systemImage: "clock")
                } else {
                    ForEach(remote.commands) { command in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(commandName(command.commandType), systemImage: commandIcon(command.commandType))
                                Spacer()
                                Text(statusName(command.status)).font(.caption.bold()).foregroundStyle(statusColor(command.status))
                            }
                            Text(Date(timeIntervalSince1970: TimeInterval(command.createdAt)), style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            Section("骑行记录") {
                if remote.trips.isEmpty {
                    Label("暂无骑行记录", systemImage: "bicycle")
                } else {
                    ForEach(remote.trips) { trip in
                        NavigationLink { TripDetailView(trip: trip) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Label(
                                        trip.status == "active" ? "当前骑行" : "历史骑行",
                                        systemImage: trip.status == "active" ? "bicycle.circle.fill" : "point.topleft.down.to.point.bottomright.curvepath"
                                    )
                                    Spacer()
                                    Text(String(format: "%.2f 公里", trip.distanceM / 1000))
                                        .font(.caption.bold())
                                }
                                Text(Date(timeIntervalSince1970: TimeInterval(trip.startedAt)).formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("可靠定位点 \(trip.pointCount) 个")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            Section("告警记录") {
                if remote.alarms.isEmpty {
                    Label("暂无告警记录", systemImage: "checkmark.shield")
                } else {
                    ForEach(remote.alarms) { alarm in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(
                                    alarm.inferred ? "疑似离线移动" : "异常移动",
                                    systemImage: "exclamationmark.triangle"
                                )
                                Spacer()
                                Text(alarmStateName(alarm.state)).font(.caption.bold())
                            }
                            Text("触发 \(alarm.triggerCount) 次")
                                .font(.caption).foregroundStyle(.secondary)
                            if alarm.inferred,
                               let baseline = alarm.baselineCapturedAt,
                               let reconnect = alarm.reconnectCapturedAt {
                                Text("停车 \(Date(timeIntervalSince1970: TimeInterval(baseline)).formatted(date: .numeric, time: .shortened))，重连 \(Date(timeIntervalSince1970: TimeInterval(reconnect)).formatted(date: .numeric, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(
                                Date(timeIntervalSince1970: TimeInterval(alarm.lastTriggeredAt)),
                                style: .relative
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("活动记录")
        .refreshable { if remote.isPaired { await remote.refresh() } }
    }

    private func commandName(_ value: String) -> String {
        ["vehicle.unlock": "远程开锁", "vehicle.lock": "远程关锁", "vehicle.find_sound": "声音找车",
         "telemetry.refresh": "读取设备信息", "location.once": "单次定位",
         "tracking.set_policy": "定位策略", "security.confirm_locked": "确认物理关锁",
         "security.arm": "手动布防", "alarm.acknowledge": "解除告警"][value] ?? value
    }

    private func commandIcon(_ value: String) -> String {
        ["vehicle.unlock": "lock.open", "vehicle.lock": "lock", "vehicle.find_sound": "speaker.wave.2",
         "telemetry.refresh": "arrow.clockwise", "location.once": "location"][value] ?? "terminal"
    }

    private func statusName(_ value: String) -> String {
        ["accepted": "已受理", "prechecking": "检查中", "awaiting_r0": "正在鉴权", "awaiting_result": "等待设备",
         "succeeded": "成功", "failed": "失败", "unknown": "结果未知", "noop": "无需操作", "rejected": "已拒绝"][value] ?? value
    }

    private func statusColor(_ value: String) -> Color {
        switch value { case "succeeded", "noop": return .green; case "failed", "rejected": return .red; case "unknown": return .orange; default: return .secondary }
    }

    private func alarmStateName(_ value: String) -> String {
        ["active": "活动", "acknowledged": "已确认", "cleared": "已解除"][value] ?? value
    }
}

private struct TripDetailView: View {
    @EnvironmentObject private var remote: RemoteControlManager
    let trip: RemoteTrip
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if points.isEmpty {
                    ContentUnavailableView(
                        "没有可靠轨迹点", systemImage: "location.slash",
                        description: Text("无效点和被漂移规则过滤的点不会连线。")
                    )
                    .frame(minHeight: 260)
                } else {
                    Map(position: $camera) {
                        ForEach(Array(routeSegments.enumerated()), id: \.offset) { _, segment in
                            if segment.count > 1 {
                                MapPolyline(coordinates: segment)
                                    .stroke(.indigo, lineWidth: 4)
                            }
                        }
                        if let first = coordinates.first {
                            Marker("起点", systemImage: "flag.fill", coordinate: first).tint(.green)
                        }
                        if let last = coordinates.last {
                            Marker("终点", systemImage: "flag.checkered", coordinate: last).tint(.indigo)
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .frame(height: 390)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("开始", value: date(trip.startedAt))
                    LabeledContent("结束", value: trip.endedAt.map(date) ?? "进行中")
                    LabeledContent("估算距离", value: String(format: "%.2f 公里", trip.distanceM / 1000))
                    LabeledContent("可靠定位点", value: "\(trip.pointCount)")
                    if trip.recoveredAfterRestart {
                        Label("服务重启后依据开锁状态恢复，开始时间为恢复时间", systemImage: "arrow.clockwise")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text("轨迹只使用车辆 IoT 定位。相邻可靠点超过 10 分钟时断线显示，不跨缺口估算距离。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("骑行详情")
        .task {
            await remote.loadTrip(trip.id)
            focusRoute()
        }
        .onChange(of: remote.selectedTripPoints.count) { _, _ in focusRoute() }
    }

    private var points: [RemoteLocation] {
        remote.selectedTrip?.id == trip.id ? remote.selectedTripPoints : []
    }

    private var coordinates: [CLLocationCoordinate2D] {
        points.compactMap { point in
            guard let latitude = point.latitude, let longitude = point.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private var routeSegments: [[CLLocationCoordinate2D]] {
        var segments: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []
        var previousTime: Int?
        for point in points {
            guard let latitude = point.latitude, let longitude = point.longitude else { continue }
            let timestamp = point.deviceTimestamp ?? point.receivedAt
            if let previousTime, timestamp - previousTime > 600, !current.isEmpty {
                segments.append(current)
                current = []
            }
            current.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            previousTime = timestamp
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private func focusRoute() {
        guard let first = coordinates.first else { return }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLatitude = latitudes.min() ?? first.latitude
        let maxLatitude = latitudes.max() ?? first.latitude
        let minLongitude = longitudes.min() ?? first.longitude
        let maxLongitude = longitudes.max() ?? first.longitude
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.008, (maxLatitude - minLatitude) * 1.4),
                longitudeDelta: max(0.008, (maxLongitude - minLongitude) * 1.4)
            )
        ))
    }

    private func date(_ timestamp: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct MoreView: View {
    var body: some View {
        List {
            Section("连接与诊断") {
                NavigationLink { RemoteControlView() } label: { MoreRow("远程服务", icon: "antenna.radiowaves.left.and.right", color: .indigo) }
                NavigationLink { CommandCenterView() } label: { MoreRow("指令中心", icon: "square.grid.2x2.fill", color: .purple) }
                NavigationLink { RemoteAuditView() } label: { MoreRow("审计与会话", icon: "list.clipboard.fill", color: .cyan) }
                NavigationLink { DeviceInfoView() } label: { MoreRow("设备信息", icon: "info.circle.fill", color: .blue) }
                NavigationLink { SecurityAndLogView() } label: { MoreRow("密钥与日志", icon: "lock.shield.fill", color: .green) }
            }
            Section("高级工具") {
                NavigationLink { DataRetentionView() } label: { MoreRow("服务设置", icon: "gearshape.fill", color: .teal) }
                NavigationLink { ControlsView() } label: { MoreRow("设备控制", icon: "slider.horizontal.3", color: .orange) }
                NavigationLink { MaintenanceView() } label: { MoreRow("设备维护", icon: "wrench.and.screwdriver.fill", color: .red) }
            }
            Section("关于") {
                LabeledContent("App 版本", value: appVersion)
                LabeledContent("目标设备", value: IoTDeviceProfile.imei)
                Text("个人实车调试版本。所有维护能力默认收纳在二级页面，避免户外操作时误触。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("更多")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version) (\(build))"
    }
}

private struct DataRetentionView: View {
    @EnvironmentObject private var remote: RemoteControlManager
    @State private var showShortenConfirmation = false

    var body: some View {
        Form {
            Section("轨迹保留") {
                LabeledContent("当前策略", value: "\(remote.settings?.locationHistoryDays ?? 7) 天")
                if remote.settings?.pendingLocationHistoryDays == 7 {
                    Label("已确认改为 7 天，将在下一次 03:30 清理时生效", systemImage: "clock.badge.checkmark")
                        .foregroundStyle(.orange)
                }
                Button("保留 7 天") {
                    if remote.settings?.locationHistoryDays == 30 {
                        showShortenConfirmation = true
                    }
                }
                .disabled(remote.isBusy || remote.settings?.locationHistoryDays == 7)
                Button("保留 30 天") {
                    Task { await remote.setLocationHistoryDays(30, confirmShortening: false) }
                }
                .disabled(remote.isBusy || remote.settings?.locationHistoryDays == 30
                          && remote.settings?.pendingLocationHistoryDays == nil)
            }
            Section("清理规则") {
                Text("已结束骑行按结束时间整体清理，避免留下半条轨迹。当前骑行不参与清理。")
                Text("从 7 天改为 30 天立即生效，但不能恢复已经删除的数据。从 30 天改为 7 天需要确认，并在下一次清理时生效。")
            }
            Section("服务端控制参数") {
                LabeledContent("指令超时", value: seconds(remote.settings?.commandTimeoutSeconds))
                LabeledContent("通信静默", value: seconds(remote.settings?.silenceWindowSeconds))
                LabeledContent("判定离线", value: seconds(remote.settings?.offlineWindowSeconds))
                LabeledContent("布防等待", value: seconds(remote.settings?.lockGraceSeconds))
                LabeledContent("最少卫星", value: remote.settings?.locationMinSatellites.map { "\($0) 颗" } ?? "未读取")
                LabeledContent("最大 HDOP", value: number(remote.settings?.locationMaxHdop))
                LabeledContent("最大定位速度", value: metersPerSecond(remote.settings?.locationMaxSpeedMps))
                LabeledContent("离线移动阈值", value: meters(remote.settings?.offlineMovementThresholdM))
                LabeledContent("双样本间距", value: meters(remote.settings?.offlineSampleMaxSeparationM))
                Text("这些参数由服务部署配置控制，App 只读展示。当前唯一可修改项是轨迹保留天数。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("事件保留") {
                LabeledContent("命令、告警与审计", value: days(remote.settings?.eventRetentionDays))
                LabeledContent("设备会话详情", value: days(remote.settings?.deviceSessionRetentionDays))
            }
            if !remote.message.isEmpty {
                Section { Text(remote.message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("服务设置")
        .task { if remote.isPaired { await remote.refresh() } }
        .alert("改为保留 7 天？", isPresented: $showShortenConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确认缩短", role: .destructive) {
                Task { await remote.setLocationHistoryDays(7, confirmShortening: true) }
            }
        } message: {
            Text("下一次清理会删除超过 7 天的已结束骑行和普通定位，已删除数据无法恢复。")
        }
    }

    private func seconds(_ value: Int?) -> String {
        value.map { "\($0) 秒" } ?? "未读取"
    }

    private func days(_ value: Int?) -> String {
        value.map { "\($0) 天" } ?? "未读取"
    }

    private func number(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "未读取"
    }

    private func meters(_ value: Double?) -> String {
        value.map { String(format: "%.0f 米", $0) } ?? "未读取"
    }

    private func metersPerSecond(_ value: Double?) -> String {
        value.map { String(format: "%.0f 米/秒", $0) } ?? "未读取"
    }
}

private struct MoreRow: View {
    let title: String
    let icon: String
    let color: Color

    init(_ title: String, icon: String, color: Color) {
        self.title = title
        self.icon = icon
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct DeviceInfoView: View {
    @EnvironmentObject private var device: BLEDeviceManager

    var body: some View {
        List {
            Section("固定设备") {
                LabeledContent("车辆编号", value: IoTDeviceProfile.bikeNumber)
                LabeledContent("IMEI", value: IoTDeviceProfile.imei)
                LabeledContent("BLE MAC", value: IoTDeviceProfile.bleMAC)
            }
            Section("服务器隔离") {
                LabeledContent("地址", value: device.snapshot.systemInfo["IP"] ?? "未读取")
                LabeledContent("端口", value: device.snapshot.systemInfo["PORT"] ?? "未读取")
                LabeledContent("LINK", value: device.snapshot.systemInfo["LINK"] ?? "未读取")
                Text("设备当前指向隔离地址时无法把数据送达原服务器。BLE 已验证的系统信息接口不包含当前心跳和定位上报间隔。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("系统信息") {
                if device.snapshot.systemInfo.isEmpty {
                    Text("连接后点击刷新读取")
                } else {
                    ForEach(device.snapshot.systemInfo.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: device.snapshot.systemInfo[key] ?? "")
                    }
                }
            }
        }
        .navigationTitle("设备信息")
        .toolbar { Button("刷新") { device.refreshAll() }.disabled(!device.isReady) }
    }
}

private struct ControlsView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @State private var setting = ScooterSetting.lightOn
    @State private var externalLock = ExternalLockOperation.queryBattery
    @State private var pendingPower: Bool?
    @State private var showClearConfirmation = false
    @State private var persistSettings = false
    @State private var cruise = 1
    @State private var startMode = 1
    @State private var lowSpeed = 15
    @State private var mediumSpeed = 20
    @State private var highSpeed = 25

    var body: some View {
        Form {
            Section("常用设置") {
                Picker("操作", selection: $setting) {
                    ForEach(ScooterSetting.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("发送设置") {
                    Task { await device.applyWithOwnerAuthentication(setting) }
                }
                .disabled(!device.isReady || device.isBusy)
            }
            Section("滑板车电源") {
                Button("开机") { pendingPower = true }.disabled(!device.isReady || device.isBusy)
                Button("关机", role: .destructive) { pendingPower = false }.disabled(!device.isReady || device.isBusy)
            }
            Section("外部锁兼容性诊断") {
                Label("因果未确认，危险诊断禁用", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("L5 与 BLE 0x81 实测无回包，且曾出现无法归因的延迟关锁。在隔离变量验证完成前不允许发送任何外部锁命令。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("操作", selection: $externalLock) {
                    ForEach(ExternalLockOperation.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(true)
                Button("外部锁命令已禁用") { }
                    .disabled(true)
            }
            Section("高级滑板车参数") {
                Toggle("写入后持久保存", isOn: $persistSettings)
                Picker("定速巡航", selection: $cruise) { Text("关闭").tag(1); Text("开启").tag(2) }
                Picker("启动方式", selection: $startMode) { Text("零启动").tag(1); Text("非零启动").tag(2) }
                Stepper("低速：\(lowSpeed)", value: $lowSpeed, in: 1...100)
                Stepper("中速：\(mediumSpeed)", value: $mediumSpeed, in: 1...100)
                Stepper("高速：\(highSpeed)", value: $highSpeed, in: 1...100)
                Button("发送高级参数") {
                    Task {
                        await device.applySettings2WithOwnerAuthentication(
                            persist: persistSettings, cruise: cruise, startMode: startMode,
                            low: lowSpeed, medium: mediumSpeed, high: highSpeed
                        )
                    }
                }
                .disabled(!device.isReady || device.isBusy)
            }
            Section("RFID 与旧数据") {
                Button("登记 RFID 卡") {
                    Task { await device.startRFIDRegistrationWithOwnerAuthentication() }
                }
                .disabled(!device.isReady || device.isBusy)
                Button("读取未上传骑行数据") { device.requestOldRideData() }.disabled(!device.isReady)
                if !device.oldRideDataHex.isEmpty {
                    Text(device.oldRideDataHex).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("清除未上传骑行数据", role: .destructive) { showClearConfirmation = true }
                    .disabled(!device.isReady || device.isBusy)
            }
            if !device.operationMessage.isEmpty {
                Section("状态") { Text(device.operationMessage).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("设备控制")
        .alert("确认滑板车电源操作", isPresented: Binding(get: { pendingPower != nil }, set: { if !$0 { pendingPower = nil } })) {
            Button("取消", role: .cancel) { pendingPower = nil }
            Button("确认", role: pendingPower == false ? .destructive : nil) {
                if let pendingPower {
                    Task { await device.setScooterPowerWithOwnerAuthentication(on: pendingPower) }
                }
                pendingPower = nil
            }
        }
        .alert("清除旧骑行数据？", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) { }
            Button("永久清除", role: .destructive) {
                Task { await device.clearOldRideDataWithOwnerAuthentication() }
            }
        } message: { Text("此操作无法撤销，请先读取并确认数据。") }
    }
}

private struct MaintenanceView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @State private var serverIP = ""
    @State private var serverPort = "9680"
    @State private var apn = "CMIOT"
    @State private var apnUser = ""
    @State private var apnPassword = ""
    @State private var pendingAction: PendingMaintenance?
    @State private var alertMessage = ""
    @State private var showError = false
    @State private var importingFirmware = false
    @State private var firmwareData: Data?
    @State private var firmwareName = ""

    private enum PendingMaintenance { case server, apn, ota }

    var body: some View {
        Form {
            Section("服务器配置") {
                TextField("IPv4 或域名", text: $serverIP).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("端口", text: $serverPort).keyboardType(.numberPad)
                Button("修改服务器") { pendingAction = .server }
                    .disabled(!device.isReady || !device.maintenanceKeyStored || serverIP.isEmpty)
                Text("仅支持原固件已验证的 IP、PORT、IPMODE 字段。修改后设备可能断连。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("APN 配置") {
                TextField("APN", text: $apn).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("用户名", text: $apnUser).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $apnPassword)
                Button("修改 APN") { pendingAction = .apn }
                    .disabled(!device.isReady || !device.maintenanceKeyStored || apn.isEmpty)
            }
            Section("固件与日志") {
                Button("选择固件文件") { importingFirmware = true }
                    .disabled(!device.isReady || !device.maintenanceKeyStored)
                if !firmwareName.isEmpty { LabeledContent("已选择", value: firmwareName) }
                Button("开始 OTA", role: .destructive) { pendingAction = .ota }
                    .disabled(firmwareData == nil || !device.isReady || !device.maintenanceKeyStored)
                Button("读取设备诊断日志") { device.startDeviceLog() }.disabled(!device.isReady)
                Text("诊断日志开启后建议完成采集并手动断开，再重新连接。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !device.maintenanceKeyStored {
                Section { Label("先在“安全”页保存 4 字节维护密钥", systemImage: "key") }
            }
            if !device.operationMessage.isEmpty {
                Section("状态") { Text(device.operationMessage).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("维护")
        .onAppear {
            if serverIP.isEmpty { serverIP = device.snapshot.systemInfo["IP"] ?? "192.0.2.1" }
            serverPort = device.snapshot.systemInfo["PORT"] ?? serverPort
        }
        .fileImporter(isPresented: $importingFirmware, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                firmwareData = try Data(contentsOf: url)
                firmwareName = url.lastPathComponent
            } catch { report(error) }
        }
        .alert("确认维护操作", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("确认执行", role: .destructive) { executePendingAction() }
        } message: { Text(confirmationText) }
        .alert("操作失败", isPresented: $showError) { Button("好") { } } message: { Text(alertMessage) }
    }

    private var confirmationText: String {
        switch pendingAction {
        case .server: return "将服务器修改为 \(serverIP):\(serverPort)。此操作写入设备配置。"
        case .apn: return "将 APN 修改为 \(apn)。用户名和密码不会写入 App 日志。"
        case .ota: return "将传输固件 \(firmwareName)。请确保电量充足并保持设备在附近。"
        case nil: return ""
        }
    }

    private func executePendingAction() {
        let action = pendingAction
        pendingAction = nil
        Task {
            switch action {
            case .server:
                await device.modifyServerWithOwnerAuthentication(ip: serverIP, port: serverPort)
            case .apn:
                await device.modifyAPNWithOwnerAuthentication(
                    apn: apn, user: apnUser, password: apnPassword
                )
            case .ota:
                guard let firmwareData else { return }
                await device.startOTAWithOwnerAuthentication(fileData: firmwareData)
            case nil: break
            }
        }
    }

    private func report(_ error: Error) {
        alertMessage = error.localizedDescription
        showError = true
    }
}

private struct SecurityAndLogView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @State private var deviceKey = ""
    @State private var maintenanceKey = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    var body: some View {
        List {
            Section("设备密钥") {
                SecureField("8 个 ASCII 字节", text: $deviceKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(device.deviceKeyStored ? "更新设备密钥" : "保存设备密钥") { saveDeviceKey() }
                if device.deviceKeyStored {
                    Label("已保存在仅限本机的 iOS Keychain", systemImage: "checkmark.shield")
                        .font(.footnote).foregroundStyle(.green)
                    Button("删除设备密钥", role: .destructive) {
                        Task { await device.deleteDeviceKeyWithOwnerAuthentication() }
                    }
                }
            }
            Section("维护密钥") {
                SecureField("4 个 ASCII 字节", text: $maintenanceKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(device.maintenanceKeyStored ? "更新维护密钥" : "保存维护密钥") { saveMaintenanceKey() }
                if device.maintenanceKeyStored {
                    Button("删除维护密钥", role: .destructive) {
                        Task { await device.deleteMaintenanceKeyWithOwnerAuthentication() }
                    }
                }
            }
            Section("现场日志") {
                if let url = device.exportLogURL {
                    ShareLink(item: url) { Label("导出脱敏 JSON 日志", systemImage: "square.and.arrow.up") }
                }
                ForEach(device.events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(event.category).font(.caption.bold()); Spacer(); Text(event.timestamp, style: .time).font(.caption) }
                        Text(event.message).font(.callout)
                    }
                }
            }
            if !device.operationMessage.isEmpty {
                Section("状态") { Text(device.operationMessage).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("安全与日志")
        .alert("无法保存", isPresented: $showAlert) { Button("好") { } } message: { Text(alertMessage) }
    }

    private func saveDeviceKey() {
        let value = deviceKey
        Task {
            if await device.saveDeviceKeyWithOwnerAuthentication(value) {
                deviceKey = ""
            }
        }
    }

    private func saveMaintenanceKey() {
        let value = maintenanceKey
        Task {
            if await device.saveMaintenanceKeyWithOwnerAuthentication(value) {
                maintenanceKey = ""
            }
        }
    }

    private func report(_ error: Error) {
        alertMessage = error.localizedDescription
        showAlert = true
    }
}

private struct MetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct LongPressActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(.white)
            .background(enabled ? color : Color.gray, in: RoundedRectangle(cornerRadius: 14))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 1.2, maximumDistance: 35) {
                guard enabled else { return }
                action()
            }
            .allowsHitTesting(enabled)
            .accessibilityHint("按住 1.2 秒执行")
    }
}

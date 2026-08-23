import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            KeyControlView()
                .tabItem {
                    Label("钥匙", systemImage: "key.horizontal.fill")
                }

            VehicleToolsView()
                .tabItem {
                    Label("状态", systemImage: "gauge.with.dots.needle.67percent")
                }

            BLEDataToolsView()
                .tabItem {
                    Label("记录", systemImage: "list.bullet.clipboard.fill")
                }
        }
        .tint(AppTheme.brand)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

private struct KeyControlView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @State private var showKeySettings = false
    @State private var keyInput = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    connectionHero
                    controlCard
                    outcomeCard
                    physicalSafetyCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background { AppTheme.pageBackground }
            .navigationTitle("蓝牙车钥匙")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        keyInput = ""
                        showKeySettings = true
                    } label: {
                        Label("设备密钥", systemImage: "key.fill")
                    }
                    .tint(AppTheme.brand)
                }
            }
            .sheet(isPresented: $showKeySettings) {
                keySettings
            }
        }
    }

    private var connectionHero: some View {
        VStack(spacing: 16) {
            HStack {
                AppStatusBadge(
                    text: "本地蓝牙",
                    icon: "iphone.radiowaves.left.and.right",
                    color: AppTheme.brand
                )
                Spacer()
                if let rssi = device.rssi, device.isReady {
                    Label("\(rssi) dBm", systemImage: "wave.3.right")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [connectionColor.opacity(0.2), connectionColor.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 106, height: 106)
                Circle()
                    .stroke(connectionColor.opacity(0.16), lineWidth: 1)
                    .frame(width: 120, height: 120)
                Image(systemName: connectionSymbol)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(connectionColor)
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    if isTransitioning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(connectionColor)
                    }
                    Text(device.phase.rawValue)
                        .font(.title2.bold())
                }
                Text(device.operationMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if device.isReady {
                AppStatusBadge(
                    text: device.lockState.rawValue,
                    icon: lockStateSymbol,
                    color: lockStateColor
                )

                if let updatedAt = device.lockSnapshot.capturedAt {
                    Text("状态回读于 \(updatedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            connectionButtons

            if !device.deviceKeyStored {
                Label("首次使用请先保存设备密钥", systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .appCard(tint: connectionColor)
    }

    @ViewBuilder private var connectionButtons: some View {
        if device.isReady || isTransitioning {
            HStack(spacing: 12) {
                if device.isReady {
                    Button {
                        device.refreshDeviceState()
                    } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.brand)
                    .disabled(!device.canRunProtocolCommand)
                }

                Button {
                    device.disconnect()
                } label: {
                    Label("断开", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(device.isOperating)
            }
            .controlSize(.large)
        } else {
            Button {
                device.scanAndConnect()
            } label: {
                Label("连接车辆", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.brand)
            .controlSize(.large)
            .disabled(!device.deviceKeyStored || device.isOperating)
        }
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                AppSectionHeader("车辆控制", subtitle: "每次只发送一条指令", icon: "key.horizontal.fill")
                AppStatusBadge(text: "长按 1.2 秒", icon: "hand.tap.fill", color: AppTheme.accent)
            }

            HStack(spacing: 12) {
                HoldControlButton(
                    title: "开锁",
                    detail: "解除锁定",
                    icon: "lock.open.fill",
                    color: AppTheme.accent,
                    enabled: device.canUnlock
                ) {
                    device.unlock()
                }
                HoldControlButton(
                    title: "关锁",
                    detail: "关闭动力",
                    icon: "lock.fill",
                    color: AppTheme.brand,
                    enabled: device.canLock
                ) {
                    device.lock()
                }
            }

            Label(
                "结果一致后蓝牙保持连接，可以继续执行下一项操作",
                systemImage: "link"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .appCard()
    }

    @ViewBuilder private var outcomeCard: some View {
        switch device.lastOutcome {
        case .none:
            EmptyView()
        case .sending(let action):
            resultCard(
                title: "正在执行\(action.rawValue)",
                message: "请等待设备回包、必要回执和状态回读完成。",
                color: AppTheme.brand,
                icon: "hourglass"
            )
        case .accepted(let action):
            resultCard(
                title: "设备回包与锁态回读一致",
                message: physicalCheckMessage(action),
                color: AppTheme.success,
                icon: "checkmark.circle.fill"
            )
        case .rejected(let action):
            resultCard(
                title: "设备未完成\(action.rawValue)",
                message: "蓝牙仍保持连接。请先检查车辆实际状态，再决定是否操作。",
                color: AppTheme.warning,
                icon: "exclamationmark.triangle.fill"
            )
        case .unknown(let action):
            resultCard(
                title: "\(action.rawValue)结果未知",
                message: "蓝牙已安全断开。请以仪表、动力和轮毂锁的实际状态为准，不要立即重试。",
                color: .red,
                icon: "questionmark.circle.fill"
            )
        }
    }

    private func resultCard(title: String, message: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .appCard(tint: color)
        .accessibilityElement(children: .combine)
    }

    private var physicalSafetyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppSectionHeader("物理结果优先", subtitle: "关锁后同时确认两项", icon: "checkmark.shield.fill")
            AppInfoRow(
                title: "仪表必须熄灭",
                detail: "本车仪表与动力绑定，仪表灭才表示车辆断电",
                icon: "bolt.slash.fill",
                color: AppTheme.brand
            )
            AppInfoRow(
                title: "轮毂锁必须锁住",
                detail: "协议锁态不能代替真实机械状态",
                icon: "lock.shield.fill",
                color: AppTheme.success
            )
            Text("App 不访问网络，也不会自动重连或重试。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .appCard(tint: AppTheme.success)
    }

    private var keySettings: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "key.viewfinder")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(AppTheme.brand)
                            .frame(width: 72, height: 72)
                            .background(AppTheme.brand.opacity(0.1), in: Circle())
                        Text("密钥只保存在此 iPhone")
                            .font(.headline)
                        Text("不上传网络，不写入诊断记录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("设备密钥") {
                    SecureField("8 字节 ASCII 密钥", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Text("长度")
                        Spacer()
                        Text("\(keyInput.utf8.count) / 8")
                            .monospacedDigit()
                            .foregroundStyle(keyInput.utf8.count == 8 ? AppTheme.success : .secondary)
                    }

                    Button(device.deviceKeyStored ? "更新设备密钥" : "保存设备密钥") {
                        if device.saveDeviceKey(keyInput) {
                            keyInput = ""
                            showKeySettings = false
                        }
                    }
                    .disabled(keyInput.utf8.count != 8 || device.isOperating)
                }

                if device.deviceKeyStored {
                    Section("本机数据") {
                        Button("删除本机设备密钥", role: .destructive) {
                            device.deleteDeviceKey()
                            keyInput = ""
                            showKeySettings = false
                        }
                        .disabled(device.isOperating)
                    }
                }
            }
            .tint(AppTheme.brand)
            .navigationTitle("蓝牙密钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showKeySettings = false }
                }
            }
        }
    }

    private var isTransitioning: Bool {
        switch device.phase {
        case .scanning, .connecting, .discovering, .authenticating, .disconnecting:
            return true
        default:
            return false
        }
    }

    private var connectionSymbol: String {
        switch device.phase {
        case .ready: return "bicycle.circle.fill"
        case .scanning, .connecting, .discovering, .authenticating: return "dot.radiowaves.left.and.right"
        case .bluetoothOff, .failed: return "antenna.radiowaves.left.and.right.slash"
        default: return "bicycle.circle"
        }
    }

    private var connectionColor: Color {
        switch device.phase {
        case .ready: return AppTheme.success
        case .scanning, .connecting, .discovering, .authenticating: return AppTheme.brand
        case .bluetoothOff, .failed: return .red
        default: return AppTheme.brand
        }
    }

    private var lockStateSymbol: String {
        switch device.lockState {
        case .unknown: return "questionmark.circle"
        case .unlocked: return "lock.open.fill"
        case .locked: return "lock.fill"
        }
    }

    private var lockStateColor: Color {
        switch device.lockState {
        case .unknown: return .secondary
        case .unlocked: return AppTheme.accent
        case .locked: return AppTheme.success
        }
    }

    private func physicalCheckMessage(_ action: VehicleControlAction) -> String {
        switch action {
        case .unlock:
            return "蓝牙保持连接。请确认仪表稳定点亮、车辆通电、轮毂锁完全打开。"
        case .lock:
            return "蓝牙保持连接。请确认仪表熄灭、车辆断电、轮毂锁完全闭合。"
        }
    }
}

struct HoldControlButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let detail: String
    let icon: String
    let color: Color
    let enabled: Bool
    let action: () -> Void

    @State private var isPressing = false
    @State private var progress = 0.0

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2.bold())
            VStack(spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .opacity(0.78)
            }

            GeometryReader { proxy in
                Capsule()
                    .fill(Color.white.opacity(enabled ? 0.22 : 0.08))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: proxy.size.width * progress)
                    }
            }
            .frame(height: 4)
        }
        .foregroundStyle(enabled ? Color.white : Color.secondary)
        .frame(maxWidth: .infinity, minHeight: 126)
        .padding(.horizontal, 14)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    enabled
                        ? LinearGradient(
                            colors: [color, color.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [Color(.tertiarySystemFill), Color(.tertiarySystemFill)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(enabled ? Color.white.opacity(0.16) : Color.secondary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: enabled ? color.opacity(0.2) : .clear, radius: 10, y: 5)
        .scaleEffect(isPressing ? 0.97 : 1)
        .animation(.easeOut(duration: 0.16), value: isPressing)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onLongPressGesture(
            minimumDuration: 1.2,
            maximumDistance: 40,
            perform: {
                progress = 0
                action()
            },
            onPressingChanged: { pressing in
                isPressing = enabled && pressing
                if pressing && enabled {
                    progress = 0
                    withAnimation(.linear(duration: reduceMotion ? 0.01 : 1.2)) {
                        progress = 1
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.16)) {
                        progress = 0
                    }
                }
            }
        )
        .disabled(!enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("长按\(title)")
        .accessibilityValue(enabled ? "可用" : "当前不可用")
        .accessibilityHint("持续按住 1.2 秒后发送一次\(title)请求")
        .accessibilityRespondsToUserInteraction(enabled)
    }
}

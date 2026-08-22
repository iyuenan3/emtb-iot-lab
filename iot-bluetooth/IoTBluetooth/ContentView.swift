import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            KeyControlView()
                .tabItem {
                    Label("车钥匙", systemImage: "key.horizontal.fill")
                }

            VehicleToolsView()
                .tabItem {
                    Label("车辆", systemImage: "scooter")
                }

            BLEDataToolsView()
                .tabItem {
                    Label("工具", systemImage: "wrench.and.screwdriver.fill")
                }
        }
    }
}

private struct KeyControlView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @State private var showKeySettings = false
    @State private var keyInput = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    connectionCard
                    controlCard
                    outcomeCard
                    safetyCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("蓝牙车钥匙")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("密钥", systemImage: "key.fill") {
                        keyInput = ""
                        showKeySettings = true
                    }
                }
            }
            .sheet(isPresented: $showKeySettings) {
                keySettings
            }
        }
    }

    private var connectionCard: some View {
        VStack(spacing: 14) {
            Image(systemName: connectionSymbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(connectionColor)
                .frame(width: 82, height: 82)
                .background(connectionColor.opacity(0.12), in: Circle())

            Text(device.phase.rawValue)
                .font(.title2.bold())
            Text(device.operationMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let rssi = device.rssi, device.isReady {
                Label("信号 \(rssi) dBm", systemImage: "wave.3.right")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if device.isReady {
                Label(device.lockState.rawValue, systemImage: lockStateSymbol)
                    .font(.headline)
                    .foregroundStyle(lockStateColor)
                if let updatedAt = device.lockSnapshot.capturedAt {
                    Text("蓝牙回读于 \(updatedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            connectionButtons

            if !device.deviceKeyStored {
                Label("首次使用请先保存设备密钥", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private var connectionButtons: some View {
        if device.isReady || device.phase == .scanning || device.phase == .connecting
            || device.phase == .discovering || device.phase == .authenticating {
            HStack {
                if device.isReady {
                    Button("刷新状态", systemImage: "arrow.clockwise") {
                        device.refreshDeviceState()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!device.canRunProtocolCommand)
                }
                Button("断开蓝牙", systemImage: "xmark.circle") {
                    device.disconnect()
                }
                .buttonStyle(.bordered)
                .disabled(device.isOperating)
            }
        } else {
            Button("连接车辆", systemImage: "antenna.radiowaves.left.and.right") {
                device.scanAndConnect()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!device.deviceKeyStored || device.isOperating)
        }
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("车辆控制", systemImage: "key.horizontal.fill")
                    .font(.headline)
                Spacer()
                Text("长按 1.2 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                HoldControlButton(
                    title: "开锁",
                    icon: "lock.open.fill",
                    color: .orange,
                    enabled: device.canUnlock
                ) {
                    device.unlock()
                }
                HoldControlButton(
                    title: "关锁",
                    icon: "lock.fill",
                    color: .indigo,
                    enabled: device.canLock
                ) {
                    device.lock()
                }
            }

            Text("设备回包后 App 会发送必要回执，再回读锁态和车辆状态。结果一致时蓝牙保持连接，可以继续执行下一项操作。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private var outcomeCard: some View {
        switch device.lastOutcome {
        case .none:
            EmptyView()
        case .sending(let action):
            resultCard(
                title: "正在执行\(action.rawValue)",
                message: "请等待设备回包、必要回执和状态回读完成。",
                color: .blue,
                icon: "hourglass"
            )
        case .accepted(let action):
            resultCard(
                title: "设备回包与锁态回读一致",
                message: physicalCheckMessage(action),
                color: .green,
                icon: "checkmark.circle.fill"
            )
        case .rejected(let action):
            resultCard(
                title: "设备未完成\(action.rawValue)",
                message: "蓝牙仍保持连接。请先检查车辆实际状态，再决定是否操作。",
                color: .orange,
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("物理结果优先", systemImage: "shield.lefthalf.filled")
                .font(.headline)
            Text("App 只使用文档内的本地蓝牙协议，不访问网络，也不会自动重连或重试。关锁前确保车辆完全静止，操作后仍要确认仪表、动力和轮毂锁。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var keySettings: some View {
        NavigationStack {
            Form {
                Section("设备密钥") {
                    SecureField("8 字节 ASCII 密钥", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(device.deviceKeyStored ? "更新设备密钥" : "保存设备密钥") {
                        if device.saveDeviceKey(keyInput) {
                            keyInput = ""
                            showKeySettings = false
                        }
                    }
                    .disabled(keyInput.utf8.count != 8 || device.isOperating)
                }
                if device.deviceKeyStored {
                    Section {
                        Button("删除本机设备密钥", role: .destructive) {
                            device.deleteDeviceKey()
                            keyInput = ""
                            showKeySettings = false
                        }
                        .disabled(device.isOperating)
                    }
                }
                Section {
                    Text("密钥只保存在此 iPhone 的 Keychain，不上传网络，也不写入诊断记录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("蓝牙密钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { showKeySettings = false }
                }
            }
        }
    }

    private var connectionSymbol: String {
        switch device.phase {
        case .ready: return "antenna.radiowaves.left.and.right.circle.fill"
        case .scanning, .connecting, .discovering, .authenticating: return "dot.radiowaves.left.and.right"
        case .bluetoothOff, .failed: return "antenna.radiowaves.left.and.right.slash"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private var connectionColor: Color {
        switch device.phase {
        case .ready: return .green
        case .scanning, .connecting, .discovering, .authenticating: return .blue
        case .bluetoothOff, .failed: return .red
        default: return .secondary
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
        case .unlocked: return .orange
        case .locked: return .green
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
    let title: String
    let icon: String
    let color: Color
    let enabled: Bool
    let action: () -> Void

    @State private var isPressing = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.title2)
            Text("长按\(title)").font(.headline)
        }
        .foregroundStyle(enabled ? Color.white : Color.secondary)
        .frame(maxWidth: .infinity, minHeight: 108)
        .background(
            enabled ? color : Color(.tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .scaleEffect(isPressing ? 0.97 : 1)
        .animation(.easeOut(duration: 0.15), value: isPressing)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onLongPressGesture(
            minimumDuration: 1.2,
            maximumDistance: 40,
            perform: action,
            onPressingChanged: { pressing in
                isPressing = enabled && pressing
            }
        )
        .allowsHitTesting(enabled)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("长按\(title)")
        .accessibilityHint("持续按住 1.2 秒后发送一次\(title)请求")
    }
}

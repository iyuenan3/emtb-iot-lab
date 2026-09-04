import SwiftUI

struct BikeKeyView: View {
    @EnvironmentObject private var controller: BluetoothKeyController
    @State private var showingKeyEditor = false
    @State private var keyInput = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 12)
                status
                controls
                result
                safetyNote
                Spacer()
            }
            .padding(22)
            .navigationTitle("蓝牙车钥匙")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("密钥", systemImage: "key.fill") {
                        keyInput = ""
                        showingKeyEditor = true
                    }
                }
            }
            .sheet(isPresented: $showingKeyEditor) {
                keyEditor
            }
            .onAppear {
                if !controller.keyStored {
                    showingKeyEditor = true
                }
            }
        }
    }

    private var status: some View {
        VStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 104, height: 104)
                .background(statusColor.opacity(0.12), in: Circle())
            Text(controller.phase.rawValue)
                .font(.title2.bold())
            Text(controller.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            LongPressActionButton(
                title: "开锁",
                icon: "lock.open.fill",
                color: .orange,
                enabled: controller.canOperate,
                action: controller.unlock
            )
            LongPressActionButton(
                title: "关锁",
                icon: "lock.fill",
                color: .blue,
                enabled: controller.canOperate,
                action: controller.lock
            )
        }
    }

    @ViewBuilder private var result: some View {
        switch controller.outcome {
        case .none:
            EmptyView()
        case .running(let action):
            resultRow("正在执行\(action.rawValue)", "请等待自动断开", .blue)
        case .accepted(let action):
            resultRow("设备已接收\(action.rawValue)", physicalCheck(for: action), .green)
        case .rejected(let action):
            resultRow("设备未完成\(action.rawValue)", "请检查车辆实际状态，不要立即重试", .orange)
        case .unknown(let action):
            resultRow("\(action.rawValue)结果未知", "指令可能已经发送，请检查车辆，不要立即重试", .red)
        case .notSent(let action):
            resultRow("\(action.rawValue)未发送", "连接在控制前停止，可以排除车辆动作", .red)
        }
    }

    private func resultRow(_ title: String, _ detail: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(color)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }

    private var safetyNote: some View {
        Text("每次长按只执行一条指令。开锁后应当仪表稳定常亮且晃动无蜂鸣；关锁后应当仪表熄灭且晃动有蜂鸣。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keyEditor: some View {
        NavigationStack {
            Form {
                Section("蓝牙密钥") {
                    SecureField("8 字节 ASCII 密钥", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("\(keyInput.utf8.count) / 8")
                        .foregroundStyle(.secondary)
                    Button(controller.keyStored ? "更新密钥" : "保存密钥") {
                        if controller.saveKey(keyInput) {
                            keyInput = ""
                            showingKeyEditor = false
                        }
                    }
                    .disabled(keyInput.utf8.count != 8)
                }
                if controller.keyStored {
                    Section {
                        Button("删除本机密钥", role: .destructive) {
                            controller.deleteKey()
                            keyInput = ""
                        }
                    }
                }
            }
            .navigationTitle("设备密钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingKeyEditor = false }
                }
            }
        }
    }

    private var statusIcon: String {
        controller.bluetoothReady ? "bicycle.circle.fill" : "antenna.radiowaves.left.and.right.slash"
    }

    private var statusColor: Color {
        switch controller.phase {
        case .failed, .bluetoothUnavailable: return .red
        case .controlling: return .orange
        case .idle, .disconnected: return .green
        default: return .blue
        }
    }

    private func physicalCheck(for action: BikeAction) -> String {
        switch action {
        case .unlock:
            return "确认仪表稳定常亮且晃动无蜂鸣"
        case .lock:
            return "确认仪表熄灭且晃动有蜂鸣"
        }
    }
}

private struct LongPressActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let enabled: Bool
    let action: () -> Void

    @State private var pressing = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.title.bold())
            Text(title).font(.title3.bold())
            Text("按住 1.2 秒").font(.caption)
        }
        .foregroundStyle(enabled ? .white : .secondary)
        .frame(maxWidth: .infinity, minHeight: 142)
        .background(
            enabled ? color : Color(.tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .scaleEffect(pressing ? 0.96 : 1)
        .animation(.easeOut(duration: 0.15), value: pressing)
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onLongPressGesture(
            minimumDuration: 1.2,
            maximumDistance: 35,
            perform: {
                guard enabled else { return }
                action()
            },
            onPressingChanged: { pressing = enabled && $0 }
        )
        .allowsHitTesting(enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("长按\(title)")
        .accessibilityHint("持续按住 1.2 秒，只发送一次\(title)指令")
    }
}

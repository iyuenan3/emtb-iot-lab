import SwiftUI

struct BLEDataToolsView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @State private var confirmClearOldData = false
    @State private var pendingExternalOperation: ExternalDeviceOperation?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    connectionNotice
                    oldRideDataCard
                    externalLocksCard
                    diagnosticsCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("蓝牙工具")
            .alert("清除旧骑行数据？", isPresented: $confirmClearOldData) {
                Button("取消", role: .cancel) {}
                Button("确认清除", role: .destructive) {
                    device.clearOldRideData()
                }
            } message: {
                Text("请先分享或记录已读取的数据。设备确认清除后，App 无法替你恢复。")
            }
            .alert("确认外部锁操作", isPresented: externalConfirmationPresented) {
                Button("取消", role: .cancel) {
                    pendingExternalOperation = nil
                }
                Button("确认发送", role: .destructive) {
                    if let pendingExternalOperation {
                        device.operateExternalDevice(pendingExternalOperation)
                    }
                    pendingExternalOperation = nil
                }
            } message: {
                Text(externalConfirmationMessage)
            }
        }
    }

    private var connectionNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isReady ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(device.isReady ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.isReady ? "蓝牙已连接" : "请先在车钥匙页连接车辆")
                    .font(.headline)
                Text(device.operationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var oldRideDataCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("旧骑行数据", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if device.lockSnapshot.hasOldRideData {
                    Text("设备有记录")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }

            if let data = device.oldRideData {
                dataRow("开锁时间", data.unlockDate.formatted(date: .numeric, time: .standard))
                dataRow("使用时长", duration(data.durationSeconds))
                dataRow("用户 ID", String(data.userID))
            } else {
                Text("读取后可以先分享保存，再决定是否清除。用户 ID 不会进入脱敏诊断。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("读取", systemImage: "arrow.down.doc") {
                    device.requestOldRideData()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!device.canRunProtocolCommand)

                if let report = device.oldRideDataReport {
                    ShareLink(item: report) {
                        Label("保存", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }

                Button("清除", systemImage: "trash", role: .destructive) {
                    confirmClearOldData = true
                }
                .buttonStyle(.bordered)
                .disabled(!device.canRunProtocolCommand || device.oldRideData == nil)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var externalLocksCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("外部锁设备 0x81", systemImage: "lock.square.stack.fill")
                .font(.headline)

            ForEach(ExternalDeviceKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(kind.rawValue).font(.subheadline.bold())
                        Spacer()
                        Text(device.externalState(for: kind).rawValue)
                            .font(.caption.bold())
                            .foregroundStyle(externalStateColor(device.externalState(for: kind)))
                    }
                    HStack {
                        Button("查询") {
                            device.operateExternalDevice(.query(kind))
                        }
                        .buttonStyle(.bordered)
                        Button("解锁", role: .destructive) {
                            pendingExternalOperation = .unlock(kind)
                        }
                        .buttonStyle(.bordered)
                        Button("上锁") {
                            pendingExternalOperation = .lock(kind)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(!device.canRunProtocolCommand)
                }
                if kind != ExternalDeviceKind.allCases.last {
                    Divider()
                }
            }

            Text("协议文档定义了电池锁、车轮锁和钢缆锁。控制后 App 会查询状态；结果不一致或超时会断开蓝牙，不会自动重试。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var diagnosticsCard: some View {
        DisclosureGroup("诊断记录") {
            ShareLink(item: device.diagnosticReport) {
                Label("分享脱敏诊断", systemImage: "square.and.arrow.up")
            }
            .disabled(device.events.isEmpty)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            if device.events.isEmpty {
                Text("暂无记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(device.events.prefix(30)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.category).font(.caption.bold())
                                Spacer()
                                Text(event.timestamp, style: .time)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var externalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingExternalOperation != nil },
            set: { presented in
                if !presented { pendingExternalOperation = nil }
            }
        )
    }

    private var externalConfirmationMessage: String {
        guard let operation = pendingExternalOperation else { return "" }
        return "将发送“\(operation.title)”指令。请确认车辆静止，并在操作后检查真实机械状态。"
    }

    private func dataRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func duration(_ seconds: UInt32) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return "\(hours)时 \(minutes)分 \(remainingSeconds)秒"
    }

    private func externalStateColor(_ state: ExternalDeviceState) -> Color {
        switch state {
        case .unknown: return .secondary
        case .locked: return .green
        case .unlocked: return .orange
        }
    }
}

import SwiftUI

struct BLEDataToolsView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @State private var confirmClearOldData = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    connectionNotice
                    oldRideDataCard
                    disabledExternalDevicesCard
                    diagnosticsCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("数据与诊断")
            .alert("清除旧骑行数据？", isPresented: $confirmClearOldData) {
                Button("取消", role: .cancel) {}
                Button("确认清除", role: .destructive) {
                    device.clearOldRideData()
                }
            } message: {
                Text("请先分享或记录已读取的数据。设备确认清除后，App 无法替你恢复。")
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

    private var disabledExternalDevicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("外部锁功能已停用", systemImage: "lock.slash.fill")
                .font(.headline)
            Text("本车对电池锁、车轮锁和钢缆锁的 0x81 查询均无回包。App 不再提供查询、解锁或上锁入口，轮毂锁只随已验证的主锁流程联动。")
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
}

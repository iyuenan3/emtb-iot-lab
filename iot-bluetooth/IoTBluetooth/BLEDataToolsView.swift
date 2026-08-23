import SwiftUI

struct BLEDataToolsView: View {
    @EnvironmentObject private var device: BLEDeviceManager
    @State private var confirmClearOldData = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ConnectionStatusBanner()
                    oldRideDataCard
                    disabledExternalDevicesCard
                    diagnosticsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background { AppTheme.pageBackground }
            .navigationTitle("数据与记录")
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

    private var oldRideDataCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppSectionHeader("旧骑行数据", subtitle: "设备内仅保留最近记录", icon: "clock.arrow.circlepath")
                rideDataBadge
            }

            if let data = device.oldRideData {
                VStack(spacing: 0) {
                    dataRow("开锁时间", data.unlockDate.formatted(date: .numeric, time: .standard))
                    Divider().padding(.leading, 34)
                    dataRow("使用时长", duration(data.durationSeconds))
                    Divider().padding(.leading, 34)
                    dataRow("用户 ID", String(data.userID))
                }
                .padding(.horizontal, 14)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(AppTheme.brand)
                        .frame(width: 64, height: 64)
                        .background(AppTheme.brand.opacity(0.1), in: Circle())
                    Text("尚未读取数据")
                        .font(.subheadline.bold())
                    Text("读取后可以先分享保存，再决定是否清除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            HStack(spacing: 10) {
                Button {
                    device.requestOldRideData()
                } label: {
                    Label("读取", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.brand)
                .disabled(!device.canRunProtocolCommand)

                if let report = device.oldRideDataReport {
                    ShareLink(item: report) {
                        Label("保存", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    confirmClearOldData = true
                } label: {
                    Label("清除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!device.canRunProtocolCommand || device.oldRideData == nil)
            }
            .controlSize(.large)

            Text("用户 ID 只显示在当前页面和主动保存的数据中，不会进入脱敏诊断。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .appCard()
    }

    @ViewBuilder private var rideDataBadge: some View {
        if device.oldRideData != nil {
            AppStatusBadge(text: "已读取", icon: "checkmark.circle.fill", color: AppTheme.success)
        } else if device.lockSnapshot.hasOldRideData {
            AppStatusBadge(text: "有记录", icon: "exclamationmark.circle.fill", color: AppTheme.accent)
        } else {
            AppStatusBadge(text: "无记录", icon: "minus.circle", color: .secondary)
        }
    }

    private var disabledExternalDevicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader("外部锁功能已停用", subtitle: "本车未取得可靠回包", icon: "lock.slash.fill")
            Text("界面不提供外部锁的查询、解锁或上锁入口。轮毂锁只随已验证的主锁流程联动。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .appCard(tint: AppTheme.warning, compact: true)
    }

    private var diagnosticsCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ShareLink(item: device.diagnosticReport) {
                    Label("分享脱敏诊断", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.brand)
                .disabled(device.events.isEmpty)

                if device.events.isEmpty {
                    ContentUnavailableView(
                        "暂无诊断记录",
                        systemImage: "waveform.path.ecg",
                        description: Text("连接或操作车辆后会在此生成脱敏记录。")
                    )
                    .frame(minHeight: 150)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(device.events.prefix(30)) { event in
                            eventRow(event)
                            if event.id != device.events.prefix(30).last?.id {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.top, 14)
        } label: {
            AppSectionHeader("诊断记录", subtitle: "默认折叠，仅用户主动分享", icon: "waveform.path.ecg")
        }
        .tint(AppTheme.brand)
        .appCard()
    }

    private func eventRow(_ event: FieldLogEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(event.category)
                .font(.caption2.bold())
                .foregroundStyle(AppTheme.brand)
                .frame(width: 28, height: 28)
                .background(AppTheme.brand.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.message)
                        .font(.caption)
                    Spacer(minLength: 8)
                    Text(event.timestamp, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private func dataRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: rowIcon(title))
                .foregroundStyle(AppTheme.brand)
                .frame(width: 20)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 12)
    }

    private func rowIcon(_ title: String) -> String {
        switch title {
        case "开锁时间": return "calendar"
        case "使用时长": return "timer"
        default: return "person.crop.circle"
        }
    }

    private func duration(_ seconds: UInt32) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return "\(hours)时 \(minutes)分 \(remainingSeconds)秒"
    }
}

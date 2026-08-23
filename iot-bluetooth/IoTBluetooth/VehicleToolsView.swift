import SwiftUI

struct VehicleToolsView: View {
    @EnvironmentObject private var device: BLEDeviceManager

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ConnectionStatusBanner()
                    statusCard
                    acceptanceBoundaryCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background { AppTheme.pageBackground }
            .navigationTitle("车辆状态")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppSectionHeader("车辆信息", subtitle: "数据来自当前蓝牙连接", icon: "gauge.with.dots.needle.67percent")

                Button {
                    device.refreshDeviceState()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(AppTheme.brand)
                .disabled(!device.canRunProtocolCommand)
                .accessibilityLabel("刷新车辆状态")
            }

            HStack {
                AppStatusBadge(
                    text: device.lockState.rawValue,
                    icon: lockStateIcon,
                    color: lockStateColor
                )
                Spacer()
                if let capturedAt = latestCapturedAt {
                    Text(capturedAt, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: columns, spacing: 12) {
                AppMetricTile(
                    title: "电量",
                    value: percent(device.scooterSnapshot.batteryPercent),
                    icon: "battery.75percent",
                    color: AppTheme.success
                )
                AppMetricTile(
                    title: "当前速度",
                    value: speed(device.scooterSnapshot.speedKPH),
                    icon: "speedometer",
                    color: AppTheme.brand
                )
                AppMetricTile(
                    title: "骑行模式",
                    value: device.scooterSnapshot.rideMode?.title ?? "未知",
                    icon: "slider.horizontal.3",
                    color: AppTheme.accent
                )
                AppMetricTile(
                    title: "本次里程",
                    value: distance(device.scooterSnapshot.tripDistanceMeters),
                    icon: "point.bottomleft.forward.to.point.topright.scurvepath",
                    color: .purple
                )
                AppMetricTile(
                    title: "剩余里程",
                    value: distance(device.scooterSnapshot.remainingDistanceMeters),
                    icon: "map.fill",
                    color: .teal
                )
                AppMetricTile(
                    title: "锁电压",
                    value: voltage(device.lockSnapshot.voltageMillivolts),
                    icon: "bolt.fill",
                    color: AppTheme.warning
                )
            }

            if let firmware = device.lockSnapshot.firmwareVersion {
                Label("锁固件 \(firmware)", systemImage: "cpu")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .appCard()
    }

    private var acceptanceBoundaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppSectionHeader("只保留稳定功能", subtitle: "实车结果决定功能边界", icon: "checkmark.shield.fill")
            AppInfoRow(
                title: "当前可用",
                detail: "锁态、电量、速度、里程和固件信息读取",
                icon: "checkmark.circle.fill",
                color: AppTheme.success
            )
            AppInfoRow(
                title: "不可用",
                detail: "车辆设置和外部锁控制已停用，界面中没有隐藏入口",
                icon: "nosign",
                color: AppTheme.warning
            )
        }
        .appCard(tint: AppTheme.warning)
    }

    private var latestCapturedAt: Date? {
        [device.lockSnapshot.capturedAt, device.scooterSnapshot.capturedAt]
            .compactMap { $0 }
            .max()
    }

    private var lockStateIcon: String {
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

    private func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "未知"
    }

    private func speed(_ value: Double?) -> String {
        value.map { String(format: "%.1f km/h", $0) } ?? "未知"
    }

    private func distance(_ meters: Int?) -> String {
        guard let meters else { return "未知" }
        return meters >= 1_000
            ? String(format: "%.1f km", Double(meters) / 1_000)
            : "\(meters) m"
    }

    private func voltage(_ millivolts: Int?) -> String {
        guard let millivolts else { return "未知" }
        return String(format: "%.1f V", Double(millivolts) / 1_000)
    }
}

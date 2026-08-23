import SwiftUI

struct VehicleToolsView: View {
    @EnvironmentObject private var device: BLEDeviceManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    connectionNotice
                    statusCard
                    acceptanceBoundaryCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("车辆状态")
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

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("实时车辆信息", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.headline)
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") {
                    device.refreshDeviceState()
                }
                .disabled(!device.canRunProtocolCommand)
            }

            HStack(spacing: 12) {
                metric(title: "电量", value: percent(device.scooterSnapshot.batteryPercent))
                metric(title: "模式", value: device.scooterSnapshot.rideMode?.title ?? "未知")
                metric(title: "速度", value: speed(device.scooterSnapshot.speedKPH))
            }
            HStack(spacing: 12) {
                metric(title: "本次里程", value: distance(device.scooterSnapshot.tripDistanceMeters))
                metric(title: "剩余里程", value: distance(device.scooterSnapshot.remainingDistanceMeters))
                metric(title: "锁电压", value: voltage(device.lockSnapshot.voltageMillivolts))
            }

            if let firmware = device.lockSnapshot.firmwareVersion {
                Text("锁固件版本 \(firmware)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var acceptanceBoundaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("实车验收边界", systemImage: "checkmark.shield.fill")
                .font(.headline)
            Text("当前只开放已验证稳定的状态读取。协议中的 0x61、0x62 设置在本车上没有得到可靠生效证据，已经停用，避免出现仪表供电与逻辑锁态不一致。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "未知"
    }

    private func speed(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "未知"
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

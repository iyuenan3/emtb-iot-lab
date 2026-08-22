import SwiftUI

struct VehicleToolsView: View {
    @EnvironmentObject private var device: BLEDeviceManager

    @State private var light: SettingChoice = .unchanged
    @State private var rideMode: RideModeChoice = .unchanged
    @State private var accelerator: SettingChoice = .unchanged
    @State private var tailLight: SettingChoice = .unchanged
    @State private var persistAdvancedSettings = false
    @State private var cruise: SettingChoice = .unchanged
    @State private var startMode: StartModeChoice = .unchanged
    @State private var lowLimit = 0
    @State private var mediumLimit = 0
    @State private var highLimit = 0
    @State private var confirmation: SettingsConfirmation?

    private enum SettingsConfirmation: String, Identifiable {
        case basic
        case advanced

        var id: String { rawValue }
    }

    private var basicSettings: ScooterBasicSettings {
        ScooterBasicSettings(
            light: light,
            rideMode: rideMode,
            accelerator: accelerator,
            tailLight: tailLight
        )
    }

    private var advancedSettings: ScooterAdvancedSettings {
        ScooterAdvancedSettings(
            persist: persistAdvancedSettings,
            cruise: cruise,
            startMode: startMode,
            lowSpeedLimit: lowLimit,
            mediumSpeedLimit: mediumLimit,
            highSpeedLimit: highLimit
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    connectionNotice
                    statusCard
                    basicSettingsCard
                    advancedSettingsCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("车辆设置")
            .alert(item: $confirmation) { selection in
                switch selection {
                case .basic:
                    Alert(
                        title: Text("确认修改基础设置"),
                        message: Text("设备会立即应用所选项目。未选择的项目保持不变。"),
                        primaryButton: .default(Text("确认发送")) {
                            device.applyBasicSettings(basicSettings)
                        },
                        secondaryButton: .cancel(Text("取消"))
                    )
                case .advanced:
                    Alert(
                        title: Text("确认修改高级设置"),
                        message: Text(advancedConfirmationMessage),
                        primaryButton: .destructive(Text("确认发送")) {
                            device.applyAdvancedSettings(advancedSettings)
                        },
                        secondaryButton: .cancel(Text("取消"))
                    )
                }
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

    private var basicSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("基础设置 0x61", systemImage: "slider.horizontal.3")
                .font(.headline)
            Picker("前灯", selection: $light) {
                ForEach(SettingChoice.allCases) { Text($0.title).tag($0) }
            }
            Picker("骑行模式", selection: $rideMode) {
                ForEach(RideModeChoice.allCases) { Text($0.title).tag($0) }
            }
            Picker("油门", selection: $accelerator) {
                ForEach(SettingChoice.allCases) { Text($0.title).tag($0) }
            }
            Picker("尾灯", selection: $tailLight) {
                ForEach(SettingChoice.allCases) { Text($0.title).tag($0) }
            }
            Button("检查并发送基础设置", systemImage: "paperplane.fill") {
                confirmation = .basic
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(!device.canRunProtocolCommand || basicSettings.isNoOp)
            Text("“不修改”会保留设备当前值。App 不会在连接中断后自动重发。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .pickerStyle(.menu)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var advancedSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("高级设置 0x62", systemImage: "gearshape.2.fill")
                .font(.headline)
            Toggle("写入设备存储", isOn: $persistAdvancedSettings)
            Picker("定速巡航", selection: $cruise) {
                ForEach(SettingChoice.allCases) { Text($0.title).tag($0) }
            }
            Picker("启动方式", selection: $startMode) {
                ForEach(StartModeChoice.allCases) { Text($0.title).tag($0) }
            }
            speedLimitPicker("低速档限速", selection: $lowLimit)
            speedLimitPicker("中速档限速", selection: $mediumLimit)
            speedLimitPicker("高速档限速", selection: $highLimit)
            Button("检查并发送高级设置", systemImage: "exclamationmark.shield.fill") {
                confirmation = .advanced
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .frame(maxWidth: .infinity)
            .disabled(!device.canRunProtocolCommand || !advancedSettingsAreValid)
            Text("限速 0 表示不修改，其他有效值为 6 到 25 km/h。开启写入设备存储后，设置可能在断电后继续生效。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .pickerStyle(.menu)
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

    private func speedLimitPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            Text("不修改").tag(0)
            ForEach(6...25, id: \.self) { value in
                Text("\(value) km/h").tag(value)
            }
        }
    }

    private var advancedSettingsAreValid: Bool {
        cruise != .unchanged || startMode != .unchanged
            || [lowLimit, mediumLimit, highLimit].contains(where: { $0 != 0 })
    }

    private var advancedConfirmationMessage: String {
        persistAdvancedSettings
            ? "设备会立即应用所选项目，并写入设备存储。请确认车辆静止且限速值正确。"
            : "设备会立即应用所选项目，但不要求写入设备存储。请确认车辆静止且限速值正确。"
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

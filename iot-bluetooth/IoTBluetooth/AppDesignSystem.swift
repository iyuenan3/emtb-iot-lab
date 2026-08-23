import SwiftUI

enum AppTheme {
    static let brand = Color(red: 0.04, green: 0.29, blue: 0.82)
    static let brandDeep = Color(red: 0.02, green: 0.14, blue: 0.48)
    static let accent = Color(red: 0.94, green: 0.35, blue: 0.05)
    static let success = Color(red: 0.08, green: 0.62, blue: 0.36)
    static let warning = Color(red: 0.93, green: 0.55, blue: 0.08)

    static var pageBackground: some View {
        LinearGradient(
            colors: [
                brand.opacity(0.13),
                Color(.systemGroupedBackground),
                Color(.systemGroupedBackground)
            ],
            startPoint: .topLeading,
            endPoint: UnitPoint(x: 0.7, y: 0.42)
        )
        .ignoresSafeArea()
    }
}

struct AppSectionHeader: View {
    let title: String
    let subtitle: String?
    let icon: String

    init(_ title: String, subtitle: String? = nil, icon: String) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(AppTheme.brand)
                .frame(width: 36, height: 36)
                .background(AppTheme.brand.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)
        }
    }
}

struct ConnectionStatusBanner: View {
    @EnvironmentObject private var device: BLEDeviceManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(device.isReady ? "车辆已连接" : "车辆未连接")
                    .font(.subheadline.bold())
                Text(device.isReady ? device.lockState.rawValue : "请先前往车钥匙页连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let rssi = device.rssi, device.isReady {
                Label("\(rssi)", systemImage: "wave.3.right")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(device.phase.rawValue)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(color.opacity(0.1), in: Capsule())
            }
        }
        .appCard(compact: true)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if device.isReady { return AppTheme.success }
        switch device.phase {
        case .scanning, .connecting, .discovering, .authenticating:
            return AppTheme.brand
        case .failed, .bluetoothOff:
            return .red
        default:
            return .secondary
        }
    }

    private var icon: String {
        if device.isReady { return "antenna.radiowaves.left.and.right.circle.fill" }
        switch device.phase {
        case .scanning, .connecting, .discovering, .authenticating:
            return "dot.radiowaves.left.and.right"
        case .failed, .bluetoothOff:
            return "antenna.radiowaves.left.and.right.slash"
        default:
            return "antenna.radiowaves.left.and.right"
        }
    }
}

struct AppStatusBadge: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.11), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct AppMetricTile: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.subheadline.bold())
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.12), in: Circle())
                Spacer()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title3.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .padding(14)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct AppInfoRow: View {
    let title: String
    let detail: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.bold())
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AppCardModifier: ViewModifier {
    let tint: Color?
    let compact: Bool

    func body(content: Content) -> some View {
        content
            .padding(compact ? 14 : 18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: compact ? 18 : 22))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 18 : 22)
                    .stroke(tint?.opacity(0.24) ?? AppTheme.brand.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.04), radius: 14, y: 7)
    }
}

extension View {
    func appCard(tint: Color? = nil, compact: Bool = false) -> some View {
        modifier(AppCardModifier(tint: tint, compact: compact))
    }
}

import Foundation

enum ConnectionPhase: String {
    case bluetoothOff = "蓝牙不可用"
    case needsDeviceKey = "需要设备密钥"
    case idle = "未连接"
    case scanning = "正在扫描"
    case connecting = "正在连接"
    case discovering = "正在发现服务"
    case authenticating = "正在认证"
    case ready = "蓝牙已就绪"
    case disconnecting = "正在断开"
    case disconnected = "已断开"
    case failed = "连接失败"
}

enum VehicleControlAction: String, Equatable {
    case unlock = "开锁"
    case lock = "关锁"

    var command: OmniCommand {
        switch self {
        case .unlock: return .unlock
        case .lock: return .lock
        }
    }
}

enum VehicleLockState: String, Equatable {
    case unknown = "锁态未知"
    case unlocked = "车辆已开锁"
    case locked = "车辆已关锁"

    func matches(_ action: VehicleControlAction) -> Bool {
        switch action {
        case .unlock: return self == .unlocked
        case .lock: return self == .locked
        }
    }
}

struct BLEControlSession {
    private(set) var isAuthenticated = false
    private(set) var pendingAction: VehicleControlAction?
    private(set) var resultAccepted: Bool?
    private(set) var writeCompletionCount = 0

    var canStartAction: Bool {
        isAuthenticated && pendingAction == nil
    }

    mutating func acceptAuthentication() {
        isAuthenticated = true
    }

    mutating func noteWriteCompleted() {
        writeCompletionCount += 1
    }

    mutating func begin(_ action: VehicleControlAction) -> Bool {
        guard canStartAction else { return false }
        pendingAction = action
        resultAccepted = nil
        return true
    }

    mutating func recordResult(command: UInt8, value: UInt8) -> Bool? {
        guard let action = pendingAction,
              action.command.rawValue == command,
              resultAccepted == nil else {
            return nil
        }
        let accepted = value == 1
        resultAccepted = accepted
        return accepted
    }

    mutating func finishAction() {
        pendingAction = nil
        resultAccepted = nil
    }

    mutating func reset() {
        self = BLEControlSession()
    }
}

enum ControlOutcome: Equatable {
    case none
    case sending(VehicleControlAction)
    case accepted(VehicleControlAction)
    case rejected(VehicleControlAction)
    case unknown(VehicleControlAction)
}

struct LockSnapshot: Equatable {
    var voltageMillivolts: Int?
    var firmwareVersion: String?
    var hasOldRideData = false
    var capturedAt: Date?
}

enum ScooterRideMode: Int, CaseIterable, Identifiable {
    case low = 1
    case medium = 2
    case high = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low: return "低速"
        case .medium: return "中速"
        case .high: return "高速"
        }
    }
}

struct ScooterSnapshot: Equatable {
    var batteryPercent: Int?
    var rideMode: ScooterRideMode?
    var speedKPH: Double?
    var tripDistanceMeters: Int?
    var remainingDistanceMeters: Int?
    var capturedAt: Date?
}

struct OldRideData: Equatable {
    let unlockTimestamp: UInt32
    let durationSeconds: UInt32
    let userID: UInt32

    var unlockDate: Date {
        Date(timeIntervalSince1970: TimeInterval(unlockTimestamp))
    }
}

enum SettingChoice: UInt8, CaseIterable, Identifiable {
    case unchanged = 0
    case disabled = 1
    case enabled = 2

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .unchanged: return "不修改"
        case .disabled: return "关闭"
        case .enabled: return "开启"
        }
    }
}

enum RideModeChoice: UInt8, CaseIterable, Identifiable {
    case unchanged = 0
    case low = 1
    case medium = 2
    case high = 3

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .unchanged: return "不修改"
        case .low: return "低速"
        case .medium: return "中速"
        case .high: return "高速"
        }
    }
}

enum StartModeChoice: UInt8, CaseIterable, Identifiable {
    case unchanged = 0
    case nonZero = 1
    case zero = 2

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .unchanged: return "不修改"
        case .nonZero: return "非零启动"
        case .zero: return "零启动"
        }
    }
}

struct ScooterBasicSettings: Equatable {
    let light: SettingChoice
    let rideMode: RideModeChoice
    let accelerator: SettingChoice
    let tailLight: SettingChoice

    var payload: [UInt8] {
        [light.rawValue, rideMode.rawValue, accelerator.rawValue, tailLight.rawValue]
    }

    var isNoOp: Bool {
        payload.allSatisfy { $0 == 0 }
    }
}

enum ScooterSettingsError: LocalizedError {
    case noChanges
    case invalidSpeedLimit

    var errorDescription: String? {
        switch self {
        case .noChanges: return "至少选择一项需要修改的设置"
        case .invalidSpeedLimit: return "限速值必须为 0 或 6 到 25 km/h"
        }
    }
}

struct ScooterAdvancedSettings: Equatable {
    let persist: Bool
    let cruise: SettingChoice
    let startMode: StartModeChoice
    let lowSpeedLimit: Int
    let mediumSpeedLimit: Int
    let highSpeedLimit: Int

    var payload: [UInt8] {
        [
            persist ? 1 : 0,
            cruise.rawValue,
            startMode.rawValue,
            UInt8(lowSpeedLimit),
            UInt8(mediumSpeedLimit),
            UInt8(highSpeedLimit)
        ]
    }

    func validate() throws {
        let limits = [lowSpeedLimit, mediumSpeedLimit, highSpeedLimit]
        guard limits.allSatisfy({ $0 == 0 || (6...25).contains($0) }) else {
            throw ScooterSettingsError.invalidSpeedLimit
        }
        guard cruise != .unchanged || startMode != .unchanged || limits.contains(where: { $0 != 0 }) else {
            throw ScooterSettingsError.noChanges
        }
    }
}

enum ExternalDeviceKind: String, CaseIterable, Identifiable, Hashable {
    case battery = "电池锁"
    case wheel = "车轮锁"
    case cable = "钢缆锁"

    var id: String { rawValue }

    fileprivate var baseCode: UInt8 {
        switch self {
        case .battery: return 0x01
        case .wheel: return 0x02
        case .cable: return 0x03
        }
    }
}

enum ExternalDeviceState: String, Equatable {
    case unknown = "状态未知"
    case locked = "已上锁"
    case unlocked = "已解锁"
}

enum ExternalDeviceOperation: Equatable {
    case unlock(ExternalDeviceKind)
    case lock(ExternalDeviceKind)
    case query(ExternalDeviceKind)

    var kind: ExternalDeviceKind {
        switch self {
        case .unlock(let kind), .lock(let kind), .query(let kind): return kind
        }
    }

    var code: UInt8 {
        switch self {
        case .unlock(let kind): return kind.baseCode
        case .lock(let kind): return kind.baseCode + 0x10
        case .query(let kind): return kind.baseCode + 0x20
        }
    }

    var isMutation: Bool {
        if case .query = self { return false }
        return true
    }

    var title: String {
        switch self {
        case .unlock(let kind): return "解锁\(kind.rawValue)"
        case .lock(let kind): return "上锁\(kind.rawValue)"
        case .query(let kind): return "查询\(kind.rawValue)"
        }
    }
}

struct IoTDeviceProfile {
    private static func configuredValue(_ key: String, fallback: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return fallback
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return fallback
        }
        return trimmed
    }

    static let imei = configuredValue("IoTDeviceIMEI", fallback: "000000000000000")
    static let bleMAC = configuredValue("IoTDeviceBLEMAC", fallback: "00:00:00:00:00:00")
    static let manufacturerData: Data = {
        let compactMAC = bleMAC.replacingOccurrences(of: ":", with: "")
        let hex = "FFFF" + compactMAC
        guard hex.count.isMultiple(of: 2) else { return Data() }
        return Data(stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        })
    }()

    static let serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let writeUUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    static let notifyUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
}

struct FieldLogEvent: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let category: String
    let message: String
}

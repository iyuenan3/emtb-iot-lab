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
    private(set) var actionAttempted = false
    private(set) var pendingAction: VehicleControlAction?
    private(set) var resultAccepted: Bool?
    private(set) var writeCompletionCount = 0

    var canStartAction: Bool {
        isAuthenticated && !actionAttempted && pendingAction == nil
    }

    mutating func acceptAuthentication() {
        isAuthenticated = true
    }

    mutating func noteWriteCompleted() {
        writeCompletionCount += 1
    }

    mutating func begin(_ action: VehicleControlAction) -> Bool {
        guard canStartAction else { return false }
        actionAttempted = true
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

import Foundation

enum ConnectionPhase: String {
    case bluetoothOff = "蓝牙不可用"
    case needsDeviceKey = "需要设备密钥"
    case idle = "未连接"
    case scanning = "正在扫描"
    case connecting = "正在连接"
    case discovering = "正在发现服务"
    case authenticating = "正在认证"
    case ready = "已连接"
    case disconnected = "连接已断开"
    case failed = "连接失败"
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

    static let bikeNumber = configuredValue("IoTDeviceBikeNumber", fallback: "000000000000000")
    static let imei = configuredValue("IoTDeviceIMEI", fallback: "000000000000000")
    static let bleMAC = configuredValue("IoTDeviceBLEMAC", fallback: "00:00:00:00:00:00")
    static let advertisedName = "Scooter"
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

struct DeviceSnapshot: Codable {
    var capturedAt = Date()
    var bikeNumber = IoTDeviceProfile.bikeNumber
    var imei = IoTDeviceProfile.imei
    var bleMAC = IoTDeviceProfile.bleMAC
    var rssi: Int?
    var isLocked: Bool?
    var powerRaw: Int?
    var scooterBatteryPercent: Int?
    var rideMode: Int?
    var systemInfo: [String: String] = [:]
}

struct FieldLogEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let category: String
    let message: String

    init(category: String, message: String) {
        id = UUID()
        timestamp = Date()
        self.category = category
        self.message = message
    }
}

enum ScooterSetting: String, CaseIterable, Identifiable {
    case lightOff = "关闭大灯"
    case lightOn = "开启大灯"
    case lowSpeed = "低速模式"
    case mediumSpeed = "中速模式"
    case highSpeed = "高速模式"
    case acceleratorOff = "关闭油门"
    case acceleratorOn = "开启油门"
    case tailLightOff = "关闭尾灯"
    case tailLightOn = "开启尾灯"

    var id: String { rawValue }

    var payload: [UInt8] {
        switch self {
        case .lightOff: return [0x01, 0, 0, 0]
        case .lightOn: return [0x02, 0, 0, 0]
        case .lowSpeed: return [0, 0x01, 0, 0]
        case .mediumSpeed: return [0, 0x02, 0, 0]
        case .highSpeed: return [0, 0x03, 0, 0]
        case .acceleratorOff: return [0, 0, 0x01, 0]
        case .acceleratorOn: return [0, 0, 0x02, 0]
        case .tailLightOff: return [0, 0, 0, 0x01]
        case .tailLightOn: return [0, 0, 0, 0x02]
        }
    }

    func matches(rideMode: Int?) -> Bool {
        switch self {
        case .lowSpeed: return rideMode == 1
        case .mediumSpeed: return rideMode == 2
        case .highSpeed: return rideMode == 3
        default: return false
        }
    }
}

enum ExternalLockOperation: String, CaseIterable, Identifiable {
    case openBattery = "打开电池锁"
    case closeBattery = "关闭电池锁"
    case queryBattery = "查询电池锁"
    case openWheel = "打开车轮锁"
    case closeWheel = "关闭车轮锁"
    case queryWheel = "查询车轮锁"
    case openCable = "打开钢缆锁"
    case closeCable = "关闭钢缆锁"
    case queryCable = "查询钢缆锁"
    case openHub = "打开轮毂锁"
    case closeHub = "关闭轮毂锁"

    var id: String { rawValue }

    var code: UInt8 {
        switch self {
        case .openBattery: return 0x01
        case .closeBattery: return 0x11
        case .queryBattery: return 0x21
        case .openWheel: return 0x02
        case .closeWheel: return 0x12
        case .queryWheel: return 0x22
        case .openCable: return 0x03
        case .closeCable: return 0x13
        case .queryCable: return 0x23
        case .openHub: return 0x04
        case .closeHub: return 0x14
        }
    }
}

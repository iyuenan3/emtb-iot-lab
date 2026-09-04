import Foundation

enum BikeAction: String, Equatable {
    case unlock = "开锁"
    case lock = "关锁"

    var command: UInt8 {
        switch self {
        case .unlock: return 0x05
        case .lock: return 0x15
        }
    }
}

enum BikeRequest: Equatable {
    case authentication
    case lockInformation
    case vehicleInformation
    case control(BikeAction)
    case receipt(BikeAction)

    var command: UInt8 {
        switch self {
        case .authentication: return 0x01
        case .lockInformation: return 0x31
        case .vehicleInformation: return 0x60
        case .control(let action), .receipt(let action): return action.command
        }
    }

    func payload(deviceKey: String, timestamp: UInt32) throws -> [UInt8] {
        switch self {
        case .authentication:
            let bytes = Array(deviceKey.utf8)
            guard bytes.count == 8, bytes.allSatisfy({ $0 < 0x80 }) else {
                throw BikeWireError.invalidDeviceKey
            }
            return bytes
        case .lockInformation, .vehicleInformation:
            return [0x01]
        case .control(.unlock):
            return [0x01]
                + BikeWireProtocol.bigEndianBytes(1)
                + BikeWireProtocol.bigEndianBytes(timestamp)
                + [0x00]
        case .control(.lock):
            return [0x01]
        case .receipt:
            return [0x02]
        }
    }
}

enum BikeWait: Equatable {
    case beforeAuthentication
    case beforeControl
    case beforeDisconnect

    var seconds: TimeInterval {
        switch self {
        case .beforeAuthentication: return 0.6
        case .beforeControl: return 1.0
        case .beforeDisconnect: return 0.8
        }
    }
}

enum BikeDirective: Equatable {
    case wait(BikeWait)
    case send(BikeRequest)
    case finish(accepted: Bool)
}

enum BikeEngineError: LocalizedError {
    case invalidTransition
    case authenticationRejected
    case malformedResponse
    case deviceError(UInt8?)

    var errorDescription: String? {
        switch self {
        case .invalidTransition:
            return "蓝牙控制步骤顺序异常"
        case .authenticationRejected:
            return "设备拒绝蓝牙密钥"
        case .malformedResponse:
            return "设备返回内容不完整"
        case .deviceError(let code):
            return "设备返回协议错误 \(code.map(String.init) ?? "未知")"
        }
    }
}

struct BikeControlEngine {
    private enum Stage: Equatable {
        case waitingForNotification
        case waiting(BikeWait)
        case request(BikeRequest)
        case finished
    }

    let action: BikeAction
    private(set) var connectionKey: UInt8 = 0
    private(set) var controlWasSent = false
    private var stage: Stage = .waitingForNotification
    private var writeCompleted = false
    private var response: BikeFrame?
    private var controlAccepted = false

    init(action: BikeAction) {
        self.action = action
    }

    mutating func notificationReady() throws -> BikeDirective {
        guard stage == .waitingForNotification else {
            throw BikeEngineError.invalidTransition
        }
        stage = .waiting(.beforeAuthentication)
        return .wait(.beforeAuthentication)
    }

    mutating func timerElapsed(_ wait: BikeWait) throws -> BikeDirective {
        guard stage == .waiting(wait) else {
            throw BikeEngineError.invalidTransition
        }
        switch wait {
        case .beforeAuthentication:
            return begin(.authentication)
        case .beforeControl:
            controlWasSent = true
            return begin(.control(action))
        case .beforeDisconnect:
            stage = .finished
            return .finish(accepted: controlAccepted)
        }
    }

    mutating func writeSucceeded() throws -> BikeDirective? {
        guard case .request(let request) = stage else {
            throw BikeEngineError.invalidTransition
        }
        if case .receipt = request {
            stage = .waiting(.beforeDisconnect)
            return .wait(.beforeDisconnect)
        }
        writeCompleted = true
        return try advanceIfComplete(request)
    }

    mutating func receive(_ frame: BikeFrame) throws -> BikeDirective? {
        if frame.command == 0x10 {
            throw BikeEngineError.deviceError(frame.payload.first)
        }
        guard case .request(let request) = stage else { return nil }
        guard frame.command == request.command else { return nil }
        guard !isReceipt(request) else { return nil }
        response = frame
        return try advanceIfComplete(request)
    }

    private mutating func begin(_ request: BikeRequest) -> BikeDirective {
        stage = .request(request)
        writeCompleted = false
        response = nil
        return .send(request)
    }

    private mutating func advanceIfComplete(_ request: BikeRequest) throws -> BikeDirective? {
        guard writeCompleted, let response else { return nil }

        switch request {
        case .authentication:
            guard response.payload.count >= 2 else {
                throw BikeEngineError.malformedResponse
            }
            guard response.payload[0] == 1 else {
                throw BikeEngineError.authenticationRejected
            }
            connectionKey = response.payload[1]
            return begin(.lockInformation)

        case .lockInformation:
            guard response.payload.count >= 7 else {
                throw BikeEngineError.malformedResponse
            }
            return begin(.vehicleInformation)

        case .vehicleInformation:
            guard response.payload.count >= 8 else {
                throw BikeEngineError.malformedResponse
            }
            stage = .waiting(.beforeControl)
            return .wait(.beforeControl)

        case .control:
            let minimumResponseLength = action == .unlock ? 5 : 9
            guard response.payload.count >= minimumResponseLength,
                  let result = response.payload.first,
                  result == 1 || result == 2 else {
                throw BikeEngineError.malformedResponse
            }
            controlAccepted = result == 1
            return begin(.receipt(action))

        case .receipt:
            throw BikeEngineError.invalidTransition
        }
    }

    private func isReceipt(_ request: BikeRequest) -> Bool {
        if case .receipt = request { return true }
        return false
    }
}

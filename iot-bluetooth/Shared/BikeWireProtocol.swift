import Foundation

enum BikeWireError: LocalizedError {
    case invalidDeviceKey
    case invalidFrame
    case invalidChecksum

    var errorDescription: String? {
        switch self {
        case .invalidDeviceKey:
            return "蓝牙密钥必须是 8 个 ASCII 字节"
        case .invalidFrame:
            return "设备返回了无效蓝牙帧"
        case .invalidChecksum:
            return "设备返回帧的 CRC8 校验失败"
        }
    }
}

struct BikeFrame: Equatable {
    let connectionKey: UInt8
    let command: UInt8
    let payload: [UInt8]
}

enum BikeWireProtocol {
    static func authenticationFrame(deviceKey: String, random: UInt8? = nil) throws -> Data {
        let bytes = Array(deviceKey.utf8)
        guard bytes.count == 8, bytes.allSatisfy({ $0 < 0x80 }) else {
            throw BikeWireError.invalidDeviceKey
        }
        return makeFrame(
            command: 0x01,
            payload: bytes,
            connectionKey: 0,
            random: random
        )
    }

    static func makeFrame(
        command: UInt8,
        payload: [UInt8],
        connectionKey: UInt8,
        random: UInt8? = nil
    ) -> Data {
        precondition(payload.count <= 255)
        let clearRandom = random ?? UInt8.random(in: .min ... .max)
        var bytes: [UInt8] = [
            0xA3,
            0xA4,
            UInt8(payload.count),
            clearRandom &+ 0x32,
            connectionKey ^ clearRandom,
            command ^ clearRandom
        ]
        bytes.append(contentsOf: payload.map { $0 ^ clearRandom })
        bytes.append(crc8(bytes))
        return Data(bytes)
    }

    static func decode(_ data: Data) throws -> BikeFrame {
        let bytes = Array(data)
        guard bytes.count >= 7,
              bytes[0] == 0xA3,
              bytes[1] == 0xA4 else {
            throw BikeWireError.invalidFrame
        }
        let payloadLength = Int(bytes[2])
        guard bytes.count == payloadLength + 7 else {
            throw BikeWireError.invalidFrame
        }
        guard crc8(Array(bytes.dropLast())) == bytes.last else {
            throw BikeWireError.invalidChecksum
        }

        let clearRandom = bytes[3] &- 0x32
        let connectionKey = bytes[4] ^ clearRandom
        let command = bytes[5] ^ clearRandom
        let payload = bytes[6..<(6 + payloadLength)].map { $0 ^ clearRandom }
        return BikeFrame(
            connectionKey: connectionKey,
            command: command,
            payload: payload
        )
    }

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            var value = crc ^ byte
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0x8C : value >> 1
            }
            crc = value
        }
        return crc
    }

    static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}

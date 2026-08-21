import Foundation

enum OmniCommand: UInt8 {
    case authenticate = 0x01
    case unlock = 0x05
    case commandError = 0x10
    case lock = 0x15
    case lockDetails = 0x31
    case oldRideData = 0x51
    case clearRideData = 0x52
    case rideInfo = 0x60
    case settings = 0x61
    case settings2 = 0x62
    case externalEquipment = 0x81
    case rfid = 0x85
    case power = 0x91
    case transferStart = 0xFB
    case transferPage = 0xFC
    case log = 0xC7
    case transferEnd = 0xFF
}

struct DecodedOmniFrame {
    let command: UInt8
    let content: [UInt8]
    let decrypted: [UInt8]
}

enum OmniProtocolError: LocalizedError {
    case invalidFrame
    case crcMismatch
    case invalidKeyLength

    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "设备返回了无效数据帧"
        case .crcMismatch: return "设备数据 CRC8 校验失败"
        case .invalidKeyLength: return "设备密钥必须为 8 个 ASCII 字节"
        }
    }
}

enum OmniProtocol {
    private static let crc8Table: [UInt8] = [
        0,94,188,226,97,63,221,131,194,156,126,32,163,253,31,65,
        157,195,33,127,252,162,64,30,95,1,227,189,62,96,130,220,
        35,125,159,193,66,28,254,160,225,191,93,3,128,222,60,98,
        190,224,2,92,223,129,99,61,124,34,192,158,29,67,161,255,
        70,24,250,164,39,121,155,197,132,218,56,102,229,187,89,7,
        219,133,103,57,186,228,6,88,25,71,165,251,120,38,196,154,
        101,59,217,135,4,90,184,230,167,249,27,69,198,152,122,36,
        248,166,68,26,153,199,37,123,58,100,134,216,91,5,231,185,
        140,210,48,110,237,179,81,15,78,16,242,172,47,113,147,205,
        17,79,173,243,112,46,204,146,211,141,111,49,178,236,14,80,
        175,241,19,77,206,144,114,44,109,51,209,143,12,82,176,238,
        50,108,142,208,83,13,239,177,240,174,76,18,145,207,45,115,
        202,148,118,40,171,245,23,73,8,86,180,234,105,55,213,139,
        87,9,235,181,54,104,138,212,149,203,41,119,244,170,72,22,
        233,183,85,11,136,214,52,106,43,117,151,201,74,20,246,168,
        116,42,200,150,21,75,169,247,182,232,10,84,215,137,107,53
    ]

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0) { crc, byte in crc8Table[Int(crc ^ byte)] }
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    static func makeFrame(command: UInt8, payload: [UInt8], connectionKey: UInt8) -> Data {
        let random = UInt8.random(in: 1...255)
        var bytes: [UInt8] = [0xA3, 0xA4, UInt8(payload.count), random &+ 0x32, connectionKey, command]
        bytes.append(contentsOf: payload)
        for index in 4..<bytes.count { bytes[index] ^= random }
        bytes.append(crc8(bytes))
        return Data(bytes)
    }

    static func authenticationFrame(deviceKey: String) throws -> Data {
        let payload = Array(deviceKey.utf8)
        guard payload.count == 8, payload.allSatisfy({ $0 < 0x80 }) else { throw OmniProtocolError.invalidKeyLength }
        return makeFrame(command: OmniCommand.authenticate.rawValue, payload: payload, connectionKey: 0)
    }

    static func decode(_ data: Data) throws -> DecodedOmniFrame {
        let raw = [UInt8](data)
        guard raw.count >= 7, raw[0] == 0xA3, raw[1] == 0xA4 else { throw OmniProtocolError.invalidFrame }
        guard crc8(Array(raw.dropLast())) == raw.last else { throw OmniProtocolError.crcMismatch }
        let random = raw[3] &- 0x32
        var decrypted = raw
        for index in 4..<(decrypted.count - 1) { decrypted[index] ^= random }
        return DecodedOmniFrame(
            command: decrypted[5],
            content: Array(decrypted[6..<(decrypted.count - 1)]),
            decrypted: decrypted
        )
    }

    static func bytes<T: FixedWidthInteger>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    static func rawTransferPage(number: Int, bytes: [UInt8], pageSize: Int) -> Data {
        var body = [UInt8((number >> 8) & 0xFF), UInt8(number & 0xFF)]
        body.append(contentsOf: bytes)
        if bytes.count < pageSize { body.append(contentsOf: repeatElement(0, count: pageSize - bytes.count)) }
        let checksum = crc16(body)
        return Data([UInt8(checksum >> 8), UInt8(checksum & 0xFF)] + body)
    }

    static func parseSystemInfo(_ bytes: [UInt8]) -> [String: String] {
        let clean = bytes.prefix { $0 != 0 }
        let text = String(bytes: clean, encoding: .utf8) ?? String(bytes: clean, encoding: .isoLatin1) ?? ""
        var result: [String: String] = [:]
        for field in text.split(separator: ",", omittingEmptySubsequences: true) {
            let pair = field.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = key.uppercased()
            result[key] = (upper.contains("KEY") || upper.contains("PASS") || upper == "PW") ? "[已脱敏]" : value
        }
        return result
    }
}

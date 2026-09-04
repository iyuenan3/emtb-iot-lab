import CoreBluetooth
import Darwin
import Foundation

enum MacToolError: LocalizedError {
    case invalidArguments
    case missingSetting(String)
    case invalidMac

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "用法：emtb-ble-control <unlock|lock> --physical-ready"
        case .missingSetting(let name):
            return "缺少配置：\(name)"
        case .invalidMac:
            return "DEVICE_BLE_MAC 格式无效"
        }
    }
}

private func readSetting(path: String, name: String) throws -> String {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    for rawLine in text.split(whereSeparator: { $0.isNewline }) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"),
              let separator = line.firstIndex(of: "=") else {
            continue
        }
        let candidateName = line[..<separator].trimmingCharacters(in: .whitespaces)
        guard candidateName == name else { continue }
        var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
        }
        guard !value.isEmpty else { break }
        return value
    }
    throw MacToolError.missingSetting(name)
}

private func manufacturerPrefix(mac: String) throws -> Data {
    let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    guard bytes.count == 6, bytes.contains(where: { $0 != 0 }) else {
        throw MacToolError.invalidMac
    }
    return Data([0xFF, 0xFF] + bytes)
}

final class MacBikeController: NSObject {
    private static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let writeUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let notifyUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    private let deviceKey: String
    private let targetPrefix: Data
    private var engine: BikeControlEngine
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var generation = 0
    private var finished = false

    init(action: BikeAction, deviceKey: String, targetPrefix: Data) {
        self.deviceKey = deviceKey
        self.targetPrefix = targetPrefix
        engine = BikeControlEngine(action: action)
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func start() {
        print("[BLE] 扫描目标设备，动作 \(engine.action.rawValue)")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        scheduleTimeout(seconds: 20, message: "20 秒内没有发现目标设备")
    }

    private func drive(
        _ update: (inout BikeControlEngine) throws -> BikeDirective?
    ) {
        do {
            if let directive = try update(&engine) {
                run(directive)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func run(_ directive: BikeDirective) {
        generation += 1
        let token = generation
        switch directive {
        case .wait(let wait):
            print("[等待] \(waitDescription(wait))")
            DispatchQueue.main.asyncAfter(deadline: .now() + wait.seconds) { [weak self] in
                guard let self, !self.finished, self.generation == token else { return }
                self.drive { try $0.timerElapsed(wait) }
            }

        case .send(let request):
            guard let peripheral, let writeCharacteristic else {
                fail("蓝牙写入条件不完整")
                return
            }
            do {
                let payload = try request.payload(
                    deviceKey: deviceKey,
                    timestamp: UInt32(Date().timeIntervalSince1970)
                )
                let frame = request == .authentication
                    ? try BikeWireProtocol.authenticationFrame(deviceKey: deviceKey)
                    : BikeWireProtocol.makeFrame(
                        command: request.command,
                        payload: payload,
                        connectionKey: engine.connectionKey
                    )
                peripheral.writeValue(frame, for: writeCharacteristic, type: .withResponse)
                print("[发送] \(requestDescription(request))，单次发送")
                scheduleTimeout(seconds: 12, message: "设备未在规定时间内完成当前步骤", token: token)
            } catch {
                fail(error.localizedDescription)
            }

        case .finish(let accepted):
            let message = accepted
                ? "\(engine.action.rawValue)完成并写入必要回执"
                : "设备未完成\(engine.action.rawValue)，必要回执已写入"
            succeed(message)
        }
    }

    private func scheduleTimeout(seconds: TimeInterval, message: String, token: Int? = nil) {
        let expected = token ?? generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.finished, self.generation == expected else { return }
            self.fail(message)
        }
    }

    private func armTransportTimeout(_ message: String) {
        generation += 1
        scheduleTimeout(seconds: 12, message: message, token: generation)
    }

    private func requestDescription(_ request: BikeRequest) -> String {
        switch request {
        case .authentication: return "设备认证"
        case .lockInformation: return "锁信息读取 0x31"
        case .vehicleInformation: return "车辆信息读取 0x60"
        case .control(let action): return "主\(action.rawValue)"
        case .receipt(let action): return "\(action.rawValue)必要回执 0x02"
        }
    }

    private func waitDescription(_ wait: BikeWait) -> String {
        switch wait {
        case .beforeAuthentication: return "通知就绪后稳定 600 毫秒"
        case .beforeControl: return "初始化后静默 1 秒"
        case .beforeDisconnect: return "回执后静默 800 毫秒"
        }
    }

    private func succeed(_ message: String) {
        guard !finished else { return }
        finished = true
        central.stopScan()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        print("[结果] \(message)，已主动断开，请核对物理结果")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        print("[停止] \(message)，未重试")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(1) }
    }
}

extension MacBikeController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            start()
        case .poweredOff, .unauthorized, .unsupported:
            fail("MacBook 蓝牙不可用")
        case .unknown, .resetting:
            break
        @unknown default:
            fail("MacBook 蓝牙状态未知")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturer.starts(with: targetPrefix) else {
            return
        }
        central.stopScan()
        generation += 1
        self.peripheral = peripheral
        peripheral.delegate = self
        print("[BLE] 已发现目标设备，RSSI \(RSSI.intValue) dBm")
        central.connect(peripheral)
        armTransportTimeout("连接设备超时")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[BLE] 已连接，开始发现服务")
        peripheral.discoverServices([Self.serviceUUID])
        armTransportTimeout("发现蓝牙服务超时")
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        fail(error?.localizedDescription ?? "设备连接失败")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        guard !finished else { return }
        fail(error?.localizedDescription ?? "蓝牙提前断开")
    }
}

extension MacBikeController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            fail(error?.localizedDescription ?? "未发现蓝牙服务")
            return
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
        armTransportTimeout("发现蓝牙通道超时")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            fail(error!.localizedDescription)
            return
        }
        let notify = service.characteristics?.first(where: { $0.uuid == Self.notifyUUID })
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.writeUUID })
        guard let notify, writeCharacteristic != nil else {
            fail("蓝牙读写通道不完整")
            return
        }
        peripheral.setNotifyValue(true, for: notify)
        armTransportTimeout("订阅蓝牙通知超时")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, characteristic.isNotifying else {
            fail(error?.localizedDescription ?? "通知订阅失败")
            return
        }
        drive { try $0.notificationReady() }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else {
            fail(error?.localizedDescription ?? "设备返回读取失败")
            return
        }
        do {
            let frame = try BikeWireProtocol.decode(data)
            drive { try $0.receive(frame) }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil else {
            fail(error!.localizedDescription)
            return
        }
        drive { try $0.writeSucceeded() }
    }
}

@main
enum Main {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3,
                  CommandLine.arguments[2] == "--physical-ready" else {
                throw MacToolError.invalidArguments
            }
            let action: BikeAction
            switch CommandLine.arguments[1] {
            case "unlock": action = .unlock
            case "lock": action = .lock
            default: throw MacToolError.invalidArguments
            }

            let root = FileManager.default.currentDirectoryPath
            let key = try readSetting(path: root + "/.env.local", name: "BLE_KEY")
            guard key.utf8.count == 8, key.unicodeScalars.allSatisfy({ $0.isASCII }) else {
                throw BikeWireError.invalidDeviceKey
            }
            let mac = try readSetting(
                path: root + "/iot-bluetooth/Secrets.xcconfig",
                name: "DEVICE_BLE_MAC"
            )
            let prefix = try manufacturerPrefix(mac: mac)
            print("[安全] 已读取本机配置，密钥和设备标识不会输出")
            let controller = MacBikeController(
                action: action,
                deviceKey: key,
                targetPrefix: prefix
            )
            withExtendedLifetime(controller) {
                RunLoop.main.run()
            }
        } catch {
            print("[配置] \(error.localizedDescription)")
            exit(2)
        }
    }
}

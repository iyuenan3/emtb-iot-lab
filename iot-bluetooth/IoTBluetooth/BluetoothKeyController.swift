import CoreBluetooth
import Foundation

enum BikeConnectionPhase: String {
    case idle = "可以操作"
    case needsKey = "需要蓝牙密钥"
    case bluetoothUnavailable = "蓝牙不可用"
    case scanning = "正在寻找车辆"
    case connecting = "正在连接"
    case preparing = "正在准备连接"
    case authenticating = "正在认证"
    case initializing = "正在初始化"
    case controlling = "正在发送指令"
    case disconnecting = "正在断开"
    case disconnected = "已断开"
    case failed = "操作停止"
}

enum BikeOutcome: Equatable {
    case none
    case running(BikeAction)
    case accepted(BikeAction)
    case rejected(BikeAction)
    case unknown(BikeAction)
    case notSent(BikeAction)
}

final class BluetoothKeyController: NSObject, ObservableObject {
    @Published private(set) var phase: BikeConnectionPhase = .idle
    @Published private(set) var message = "长按开锁或关锁"
    @Published private(set) var bluetoothReady = false
    @Published private(set) var keyStored = false
    @Published private(set) var outcome: BikeOutcome = .none

    var canOperate: Bool {
        guard bluetoothReady, keyStored, plannedAction == nil, peripheral == nil else {
            return false
        }
        return phase == .idle || phase == .disconnected || phase == .failed
    }

    private static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let writeUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let notifyUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var plannedAction: BikeAction?
    private var engine: BikeControlEngine?
    private var sessionGeneration = 0
    private var stepGeneration = 0
    private var expectedDisconnect = false
    private var phaseAfterDisconnect: BikeConnectionPhase = .idle
    private var messageAfterDisconnect = "蓝牙已断开"

    override init() {
        super.init()
        refreshKeyState()
        phase = keyStored ? .idle : .needsKey
        message = keyStored ? "长按开锁或关锁" : "请先保存 8 字节蓝牙密钥"
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func saveKey(_ value: String) -> Bool {
        guard plannedAction == nil else {
            message = "操作进行中，不能修改密钥"
            return false
        }
        let bytes = Array(value.utf8)
        guard bytes.count == 8, bytes.allSatisfy({ $0 < 0x80 }) else {
            message = "蓝牙密钥必须是 8 个 ASCII 字节"
            return false
        }
        do {
            try SecureKeyStore.save(value)
            refreshKeyState()
            phase = bluetoothReady ? .idle : .bluetoothUnavailable
            message = "蓝牙密钥已保存"
            return true
        } catch {
            message = "保存蓝牙密钥失败"
            return false
        }
    }

    func deleteKey() {
        guard plannedAction == nil else { return }
        SecureKeyStore.delete()
        refreshKeyState()
        phase = .needsKey
        message = "蓝牙密钥已删除"
    }

    func unlock() {
        begin(.unlock)
    }

    func lock() {
        begin(.lock)
    }

    private func begin(_ action: BikeAction) {
        guard canOperate else {
            updateAvailabilityMessage()
            return
        }
        guard targetManufacturerPrefix() != nil else {
            phase = .failed
            message = "目标车辆蓝牙配置无效"
            return
        }

        sessionGeneration += 1
        stepGeneration += 1
        plannedAction = action
        engine = BikeControlEngine(action: action)
        outcome = .running(action)
        phase = .scanning
        message = "正在寻找车辆并准备\(action.rawValue)"
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        let generation = sessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self,
                  self.sessionGeneration == generation,
                  self.phase == .scanning else {
                return
            }
            self.fail("20 秒内没有发现目标车辆")
        }
    }

    private func drive(
        _ update: (inout BikeControlEngine) throws -> BikeDirective?
    ) {
        guard var current = engine else {
            fail("蓝牙控制状态不存在")
            return
        }
        do {
            let directive = try update(&current)
            engine = current
            if let directive {
                run(directive)
            }
        } catch {
            engine = current
            fail(error.localizedDescription)
        }
    }

    private func run(_ directive: BikeDirective) {
        stepGeneration += 1
        let generation = sessionGeneration
        let step = stepGeneration

        switch directive {
        case .wait(let wait):
            switch wait {
            case .beforeAuthentication:
                phase = .preparing
                message = "通知已就绪，稳定 600 毫秒后认证"
            case .beforeControl:
                phase = .initializing
                message = "初始化完成，稳定 1 秒后自动执行"
            case .beforeDisconnect:
                phase = .controlling
                message = "回执已写入，稳定 800 毫秒后断开"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait.seconds) { [weak self] in
                guard let self,
                      self.sessionGeneration == generation,
                      self.stepGeneration == step else {
                    return
                }
                self.drive { try $0.timerElapsed(wait) }
            }

        case .send(let request):
            send(request, generation: generation, step: step)

        case .finish(let accepted):
            finish(accepted: accepted)
        }
    }

    private func send(_ request: BikeRequest, generation: Int, step: Int) {
        guard let peripheral, let writeCharacteristic,
              let deviceKey = SecureKeyStore.read(),
              let engine else {
            fail("蓝牙写入条件不完整")
            return
        }
        do {
            let timestamp = UInt32(Date().timeIntervalSince1970)
            let payload = try request.payload(deviceKey: deviceKey, timestamp: timestamp)
            let frame: Data
            if request == .authentication {
                phase = .authenticating
                message = "正在验证设备密钥"
                frame = try BikeWireProtocol.authenticationFrame(deviceKey: deviceKey)
            } else {
                phase = request == .lockInformation || request == .vehicleInformation
                    ? .initializing
                    : .controlling
                message = message(for: request)
                frame = BikeWireProtocol.makeFrame(
                    command: request.command,
                    payload: payload,
                    connectionKey: engine.connectionKey
                )
            }
            peripheral.writeValue(frame, for: writeCharacteristic, type: .withResponse)
        } catch {
            fail(error.localizedDescription)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self,
                  self.sessionGeneration == generation,
                  self.stepGeneration == step else {
                return
            }
            self.fail("设备未在规定时间内完成当前步骤")
        }
    }

    private func message(for request: BikeRequest) -> String {
        switch request {
        case .authentication: return "正在验证设备密钥"
        case .lockInformation: return "正在读取锁信息"
        case .vehicleInformation: return "正在读取车辆信息"
        case .control(let action): return "正在发送\(action.rawValue)指令"
        case .receipt(let action): return "正在确认\(action.rawValue)结果"
        }
    }

    private func finish(accepted: Bool) {
        guard let action = plannedAction else {
            fail("控制动作上下文不存在")
            return
        }
        outcome = accepted ? .accepted(action) : .rejected(action)
        let finalMessage = accepted
            ? "设备已接收\(action.rawValue)，请检查车辆实际状态"
            : "设备未完成\(action.rawValue)，请检查车辆实际状态"
        plannedAction = nil
        requestDisconnect(finalPhase: .disconnected, finalMessage: finalMessage)
    }

    private func fail(_ reason: String) {
        central?.stopScan()
        if let action = plannedAction {
            outcome = engine?.controlWasSent == true ? .unknown(action) : .notSent(action)
        }
        plannedAction = nil
        requestDisconnect(finalPhase: .failed, finalMessage: reason)
    }

    private func requestDisconnect(
        finalPhase: BikeConnectionPhase,
        finalMessage: String
    ) {
        sessionGeneration += 1
        stepGeneration += 1
        expectedDisconnect = true
        phaseAfterDisconnect = finalPhase
        messageAfterDisconnect = finalMessage
        phase = .disconnecting
        central.stopScan()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            resetTransport()
            expectedDisconnect = false
            phase = finalPhase
            message = finalMessage
        }
    }

    private func resetTransport() {
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        engine = nil
    }

    private func refreshKeyState() {
        keyStored = SecureKeyStore.read() != nil
    }

    private func updateAvailabilityMessage() {
        if !keyStored {
            phase = .needsKey
            message = "请先保存 8 字节蓝牙密钥"
        } else if !bluetoothReady {
            phase = .bluetoothUnavailable
            message = "请在系统设置中打开蓝牙"
        } else {
            message = "请等待当前操作结束"
        }
    }

    private func armTransportTimeout(_ reason: String) {
        stepGeneration += 1
        let generation = sessionGeneration
        let step = stepGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self,
                  self.sessionGeneration == generation,
                  self.stepGeneration == step,
                  self.plannedAction != nil else {
                return
            }
            self.fail(reason)
        }
    }

    private func targetManufacturerPrefix() -> Data? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "IoTDeviceBLEMAC") as? String else {
            return nil
        }
        let bytes = value.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }) else {
            return nil
        }
        return Data([0xFF, 0xFF] + bytes)
    }
}

extension BluetoothKeyController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothReady = true
            if plannedAction == nil {
                phase = keyStored ? .idle : .needsKey
                message = keyStored ? "长按开锁或关锁" : "请先保存 8 字节蓝牙密钥"
            }
        case .poweredOff, .unauthorized, .unsupported:
            bluetoothReady = false
            if plannedAction != nil {
                fail("系统蓝牙在操作过程中不可用")
            } else {
                phase = .bluetoothUnavailable
                message = "请在系统设置中允许并打开蓝牙"
            }
        default:
            bluetoothReady = false
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard phase == .scanning,
              let expectedPrefix = targetManufacturerPrefix(),
              let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturer.starts(with: expectedPrefix) else {
            return
        }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        phase = .connecting
        message = "已找到车辆，正在连接"
        central.connect(peripheral)
        armTransportTimeout("连接车辆超时")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        phase = .preparing
        message = "正在发现蓝牙服务"
        peripheral.discoverServices([Self.serviceUUID])
        armTransportTimeout("发现蓝牙服务超时")
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        fail(error?.localizedDescription ?? "连接车辆失败")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        let wasExpected = expectedDisconnect
        let finalPhase = phaseAfterDisconnect
        let finalMessage = messageAfterDisconnect
        let interruptedAction = plannedAction
        let controlWasSent = engine?.controlWasSent == true

        resetTransport()
        plannedAction = nil
        expectedDisconnect = false

        if wasExpected {
            phase = finalPhase
            message = finalMessage
        } else {
            if let interruptedAction {
                outcome = controlWasSent ? .unknown(interruptedAction) : .notSent(interruptedAction)
            }
            phase = .failed
            message = error?.localizedDescription ?? "蓝牙提前断开，未自动重试"
        }
    }
}

extension BluetoothKeyController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            fail(error?.localizedDescription ?? "未找到车辆蓝牙服务")
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
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.writeUUID {
                writeCharacteristic = characteristic
            } else if characteristic.uuid == Self.notifyUUID {
                notifyCharacteristic = characteristic
            }
        }
        guard writeCharacteristic != nil, let notifyCharacteristic else {
            fail("车辆蓝牙读写通道不完整")
            return
        }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
        armTransportTimeout("订阅车辆通知超时")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, characteristic.isNotifying else {
            fail(error?.localizedDescription ?? "无法订阅车辆通知")
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
            fail(error?.localizedDescription ?? "读取车辆返回数据失败")
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

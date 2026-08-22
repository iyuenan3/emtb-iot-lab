import Combine
import CoreBluetooth
import Foundation

final class BLEDeviceManager: NSObject, ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var operationMessage = "手动连接后，每次只执行一个动作"
    @Published private(set) var lastOutcome: ControlOutcome = .none
    @Published private(set) var rssi: Int?
    @Published private(set) var deviceKeyStored = false
    @Published private(set) var isOperating = false
    @Published private(set) var events: [FieldLogEvent] = []

    var isReady: Bool {
        phase == .ready && isAuthenticated && writeCharacteristic != nil
    }

    var isOperationBusy: Bool {
        isOperating
    }

    var canStartAction: Bool {
        isReady && !isOperationBusy && !actionAttemptedThisConnection && pendingWrite == nil
    }

    var diagnosticReport: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var lines = [
            "eMTB BLE diagnostic",
            "build=\(build)",
            "phase=\(phase.rawValue)",
            "ready=\(isReady)",
            "operating=\(isOperating)",
            "message=\(operationMessage)"
        ]
        lines.append(contentsOf: events.reversed().map { event in
            "\(Self.diagnosticTimestamp.string(from: event.timestamp)) [\(event.category)] \(event.message)"
        })
        return lines.joined(separator: "\n")
    }

    private static let diagnosticTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private enum WritePurpose {
        case authentication
        case actionRequest
        case actionReceipt
    }

    private let serviceUUID = CBUUID(string: IoTDeviceProfile.serviceUUID)
    private let writeUUID = CBUUID(string: IoTDeviceProfile.writeUUID)
    private let notifyUUID = CBUUID(string: IoTDeviceProfile.notifyUUID)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var connectionKey: UInt8 = 0
    private var isAuthenticated = false
    private var scanRequested = false
    private var actionAttemptedThisConnection = false
    private var pendingAction: VehicleControlAction?
    private var pendingResultAccepted: Bool?
    private var pendingWrite: WritePurpose?
    private var waitingToSendReceipt = false
    private var scanGeneration = 0
    private var operationGeneration = 0

    override init() {
        super.init()
        do {
            try DeviceKeyVault.migrateLegacyKeyIfNeeded()
        } catch {
            appendEvent("安全", "旧设备密钥迁移失败，原密钥仍保留")
        }
        refreshDeviceKeyState()
        phase = deviceKeyStored ? .idle : .needsDeviceKey
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func scanAndConnect() {
        guard !isOperationBusy else {
            appendEvent("安全", "操作进行中，忽略连接请求")
            return
        }
        guard deviceKeyStored else {
            phase = .needsDeviceKey
            operationMessage = "请先保存 8 字节设备密钥"
            return
        }
        guard !IoTDeviceProfile.manufacturerData.isEmpty else {
            failConnection("目标设备配置不完整")
            return
        }

        scanRequested = true
        actionAttemptedThisConnection = false
        resetTransport()
        if central.state == .poweredOn {
            beginScan()
        } else {
            phase = .bluetoothOff
            operationMessage = "请打开系统蓝牙后重新连接"
        }
    }

    func disconnect() {
        scanRequested = false
        central.stopScan()
        operationGeneration += 1
        if isOperating, let action = pendingAction {
            lastOutcome = .unknown(action)
            operationMessage = "连接已手动断开，\(action.rawValue)结果未知"
        } else {
            operationMessage = "蓝牙已手动断开"
        }
        isOperating = false
        pendingAction = nil
        pendingResultAccepted = nil
        waitingToSendReceipt = false
        requestDisconnect()
    }

    func unlock() {
        appendEvent("交互", "用户完成开锁长按")
        startAction(.unlock)
    }

    func lock() {
        appendEvent("交互", "用户完成关锁长按")
        startAction(.lock)
    }

    func saveDeviceKey(_ key: String) -> Bool {
        guard !isOperating else {
            operationMessage = "车辆控制进行中，不能修改设备密钥"
            return false
        }
        do {
            try validateDeviceKey(key)
            try DeviceKeyVault.save(key)
            refreshDeviceKeyState()
            operationMessage = "设备密钥已保存"
            appendEvent("安全", "设备密钥已保存到本机 Keychain")
            return true
        } catch {
            operationMessage = error.localizedDescription
            appendEvent("安全", "设备密钥保存失败")
            return false
        }
    }

    func deleteDeviceKey() {
        guard !isOperating else {
            operationMessage = "车辆控制进行中，不能删除设备密钥"
            return
        }
        DeviceKeyVault.delete()
        refreshDeviceKeyState()
        disconnect()
        phase = .needsDeviceKey
        operationMessage = "设备密钥已删除"
        appendEvent("安全", "设备密钥已从本机删除")
    }

    private func beginScan() {
        guard scanRequested, central.state == .poweredOn else { return }
        scanRequested = false
        scanGeneration += 1
        let generation = scanGeneration
        phase = .scanning
        operationMessage = "正在扫描已配置的车辆 IoT"
        appendEvent("BLE", "开始扫描目标设备")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.phase == .scanning, self.scanGeneration == generation else {
                return
            }
            self.central.stopScan()
            self.failConnection("20 秒内未发现目标设备")
        }
    }

    private func startAction(_ action: VehicleControlAction) {
        guard canStartAction else {
            operationMessage = "当前连接不能再次执行控制，请断开后重新连接"
            appendEvent("安全", "阻止同一连接中的重复或反向控制")
            return
        }

        actionAttemptedThisConnection = true
        isOperating = true
        pendingAction = action
        pendingResultAccepted = nil
        waitingToSendReceipt = false
        lastOutcome = .sending(action)
        operationMessage = "正在发送\(action.rawValue)指令"
        operationGeneration += 1
        let generation = operationGeneration

        let payload: [UInt8]
        switch action {
        case .unlock:
            let userID: UInt32 = 1
            let timestamp = UInt32(Date().timeIntervalSince1970)
            payload = [0x01]
                + OmniProtocol.bytes(of: userID)
                + OmniProtocol.bytes(of: timestamp)
                + [0x00]
        case .lock:
            payload = [0x01]
        }

        appendEvent("控制", "已创建单次\(action.rawValue)请求")
        write(command: action.command, payload: payload, purpose: .actionRequest)

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.isOperating, self.operationGeneration == generation else {
                return
            }
            self.markActionUnknown("设备未在规定时间内完成结果与回执流程")
        }
    }

    private func processFrame(_ frame: DecodedOmniFrame) {
        switch frame.command {
        case OmniCommand.authenticate.rawValue:
            guard frame.content.count >= 2, frame.content[0] == 1 else {
                failConnection("设备密钥认证失败")
                return
            }
            connectionKey = frame.content[1]
            isAuthenticated = true
            phase = .ready
            operationMessage = "蓝牙已认证，请选择一次操作"
            appendEvent("BLE", "设备认证成功，未自动读取任何车辆状态")

        case OmniCommand.unlock.rawValue, OmniCommand.lock.rawValue:
            guard let action = pendingAction, frame.command == action.command.rawValue else {
                appendEvent("协议", "忽略与当前操作无关的控制结果")
                return
            }
            guard pendingResultAccepted == nil else {
                appendEvent("协议", "忽略当前操作的重复结果")
                return
            }
            guard let result = frame.content.first else {
                markActionUnknown("设备控制结果为空")
                return
            }
            pendingResultAccepted = result == 1
            waitingToSendReceipt = true
            operationMessage = result == 1
                ? "设备已确认接收\(action.rawValue)指令，正在回执"
                : "设备拒绝或未完成\(action.rawValue)，正在回执"
            appendEvent("控制", "收到\(action.rawValue)协议结果，准备发送必要回执")
            sendReceiptIfPossible()

        case OmniCommand.commandError.rawValue:
            guard let action = pendingAction else {
                appendEvent("协议", "设备返回协议错误")
                return
            }
            lastOutcome = .rejected(action)
            operationMessage = "设备拒绝\(action.rawValue)指令"
            isOperating = false
            pendingAction = nil
            operationGeneration += 1
            appendEvent("控制", "设备返回协议错误，主动断开")
            requestDisconnect()

        default:
            appendEvent("协议", "忽略非最小协议命令")
        }
    }

    private func sendReceiptIfPossible() {
        guard waitingToSendReceipt,
              pendingWrite == nil,
              let action = pendingAction else {
            return
        }
        waitingToSendReceipt = false
        write(command: action.command, payload: [0x02], purpose: .actionReceipt)
    }

    private func finishActionAfterReceipt() {
        guard let action = pendingAction, let accepted = pendingResultAccepted else {
            markActionUnknown("控制回执状态不完整")
            return
        }
        operationGeneration += 1
        isOperating = false
        pendingAction = nil
        pendingResultAccepted = nil
        lastOutcome = accepted ? .accepted(action) : .rejected(action)
        operationMessage = accepted
            ? "设备已接收\(action.rawValue)指令，蓝牙将断开，请检查车辆"
            : "设备未完成\(action.rawValue)，蓝牙将断开"
        appendEvent("控制", "必要回执已写入，立即主动断开蓝牙")
        requestDisconnect()
    }

    private func markActionUnknown(_ reason: String) {
        guard let action = pendingAction else { return }
        operationGeneration += 1
        lastOutcome = .unknown(action)
        operationMessage = "\(action.rawValue)结果未知，已停止等待并断开蓝牙"
        isOperating = false
        pendingAction = nil
        pendingResultAccepted = nil
        waitingToSendReceipt = false
        appendEvent("控制", reason)
        requestDisconnect()
    }

    private func write(command: OmniCommand, payload: [UInt8], purpose: WritePurpose) {
        guard pendingWrite == nil,
              let peripheral,
              let writeCharacteristic else {
            if isOperating {
                markActionUnknown("蓝牙写入通道不可用")
            } else {
                failConnection("蓝牙写入通道不可用")
            }
            return
        }
        pendingWrite = purpose
        peripheral.writeValue(
            OmniProtocol.makeFrame(
                command: command,
                payload: payload,
                connectionKey: connectionKey
            ),
            for: writeCharacteristic,
            type: .withResponse
        )
    }

    private func authenticate() {
        guard let key = DeviceKeyVault.read() else {
            phase = .needsDeviceKey
            operationMessage = "设备密钥不存在"
            return
        }
        do {
            phase = .authenticating
            guard pendingWrite == nil, let peripheral, let writeCharacteristic else {
                failConnection("认证写入通道不可用")
                return
            }
            pendingWrite = .authentication
            peripheral.writeValue(
                try OmniProtocol.authenticationFrame(deviceKey: key),
                for: writeCharacteristic,
                type: .withResponse
            )
            appendEvent("BLE", "已发送认证请求")
        } catch {
            failConnection(error.localizedDescription)
        }
    }

    private func requestDisconnect() {
        scanRequested = false
        central.stopScan()
        phase = .disconnecting
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            resetTransport()
            phase = .disconnected
        }
    }

    private func resetTransport() {
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        connectionKey = 0
        isAuthenticated = false
        pendingWrite = nil
    }

    private func failConnection(_ message: String) {
        central?.stopScan()
        scanRequested = false
        scanGeneration += 1
        operationGeneration += 1
        isOperating = false
        if let action = pendingAction {
            lastOutcome = .unknown(action)
        }
        pendingAction = nil
        pendingResultAccepted = nil
        waitingToSendReceipt = false
        operationMessage = message
        phase = .failed
        appendEvent("错误", message)
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func validateDeviceKey(_ key: String) throws {
        guard key.utf8.count == 8,
              key.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw OmniProtocolError.invalidKeyLength
        }
    }

    private func refreshDeviceKeyState() {
        deviceKeyStored = DeviceKeyVault.containsKey
    }

    private func appendEvent(_ category: String, _ message: String) {
        events.insert(FieldLogEvent(category: category, message: message), at: 0)
        if events.count > 100 {
            events.removeLast(events.count - 100)
        }
    }
}

extension BLEDeviceManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if scanRequested {
                beginScan()
            } else if phase == .bluetoothOff {
                phase = deviceKeyStored ? .idle : .needsDeviceKey
            }
        case .poweredOff, .unauthorized, .unsupported:
            if isOperating {
                markActionUnknown("系统蓝牙在控制过程中不可用")
            }
            phase = .bluetoothOff
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard phase == .scanning,
              let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturer == IoTDeviceProfile.manufacturerData else {
            return
        }
        central.stopScan()
        scanGeneration += 1
        self.peripheral = peripheral
        rssi = RSSI.intValue
        peripheral.delegate = self
        phase = .connecting
        operationMessage = "已发现目标车辆，正在连接"
        appendEvent("BLE", "发现目标设备，RSSI \(RSSI.intValue) dBm")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        phase = .discovering
        operationMessage = "正在建立加密通信"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        failConnection(error?.localizedDescription ?? "设备连接失败")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        let interruptedAction = isOperating ? pendingAction : nil
        resetTransport()
        if let action = interruptedAction {
            operationGeneration += 1
            isOperating = false
            pendingAction = nil
            pendingResultAccepted = nil
            waitingToSendReceipt = false
            lastOutcome = .unknown(action)
            operationMessage = "连接提前断开，\(action.rawValue)结果未知"
            appendEvent("控制", "控制完成前蓝牙断开，不会自动重连或重试")
        } else if case .sending = lastOutcome {
            operationMessage = "蓝牙已断开，请检查车辆物理状态"
        }
        phase = .disconnected
        appendEvent("BLE", error?.localizedDescription ?? "蓝牙已断开，未自动重连")
    }
}

extension BLEDeviceManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            failConnection(error?.localizedDescription ?? "未发现目标 BLE 服务")
            return
        }
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            failConnection(error!.localizedDescription)
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == writeUUID {
                writeCharacteristic = characteristic
            } else if characteristic.uuid == notifyUUID {
                notifyCharacteristic = characteristic
            }
        }
        guard let notifyCharacteristic, writeCharacteristic != nil else {
            failConnection("目标 BLE 读写特征不完整")
            return
        }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, characteristic.isNotifying else {
            failConnection(error?.localizedDescription ?? "Notify 订阅失败")
            return
        }
        authenticate()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else {
            if isOperating {
                markActionUnknown(error?.localizedDescription ?? "Notify 读取失败")
            } else {
                failConnection(error?.localizedDescription ?? "Notify 读取失败")
            }
            return
        }
        do {
            processFrame(try OmniProtocol.decode(data))
        } catch {
            appendEvent("协议", error.localizedDescription)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let purpose = pendingWrite else { return }
        pendingWrite = nil
        if let error {
            if isOperating {
                markActionUnknown("BLE 写入失败：\(error.localizedDescription)")
            } else {
                failConnection("BLE 写入失败：\(error.localizedDescription)")
            }
            return
        }
        switch purpose {
        case .authentication:
            appendEvent("BLE", "认证请求已写入")
        case .actionRequest:
            appendEvent("控制", "单次控制请求已写入，等待设备结果")
            sendReceiptIfPossible()
        case .actionReceipt:
            finishActionAfterReceipt()
        }
    }
}

import Combine
import CoreBluetooth
import Foundation

final class BLEDeviceManager: NSObject, ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var operationMessage = "手动连接后可使用已验收蓝牙功能"
    @Published private(set) var lastOutcome: ControlOutcome = .none
    @Published private(set) var lockState: VehicleLockState = .unknown
    @Published private(set) var lockSnapshot = LockSnapshot()
    @Published private(set) var scooterSnapshot = ScooterSnapshot()
    @Published private(set) var oldRideData: OldRideData?
    @Published private(set) var rssi: Int?
    @Published private(set) var deviceKeyStored = false
    @Published private(set) var isOperating = false
    @Published private(set) var events: [FieldLogEvent] = []

    var isReady: Bool {
        phase == .ready && controlSession.isAuthenticated && writeCharacteristic != nil
    }

    var canRunProtocolCommand: Bool {
        isReady && !isOperating
    }

    var canUnlock: Bool {
        canRunProtocolCommand && controlSession.canStartAction && lockState == .locked
    }

    var canLock: Bool {
        canRunProtocolCommand && controlSession.canStartAction && lockState == .unlocked
    }

    var diagnosticReport: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var lines = [
            "eMTB BLE diagnostic",
            "build=\(build)",
            "phase=\(phase.rawValue)",
            "ready=\(isReady)",
            "operating=\(isOperating)",
            "lockState=\(lockState.rawValue)",
            "lockVoltageMillivolts=\(lockSnapshot.voltageMillivolts.map(String.init) ?? "unknown")",
            "lockFirmware=\(lockSnapshot.firmwareVersion ?? "unknown")",
            "hasOldRideData=\(lockSnapshot.hasOldRideData)",
            "scooterBatteryPercent=\(scooterSnapshot.batteryPercent.map(String.init) ?? "unknown")",
            "rideMode=\(scooterSnapshot.rideMode?.title ?? "unknown")",
            "message=\(operationMessage)"
        ]
        lines.append(contentsOf: events.reversed().map { event in
            "\(Self.diagnosticTimestamp.string(from: event.timestamp)) [\(event.category)] \(event.message)"
        })
        return lines.joined(separator: "\n")
    }

    var oldRideDataReport: String? {
        guard let oldRideData else { return nil }
        return [
            "eMTB 旧骑行数据",
            "开锁时间：\(oldRideData.unlockDate.formatted(date: .numeric, time: .standard))",
            "使用时长：\(oldRideData.durationSeconds) 秒",
            "用户 ID：\(oldRideData.userID)"
        ].joined(separator: "\n")
    }

    private static let diagnosticTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private enum RefreshContext {
        case initial
        case manual
        case control
    }

    private enum PendingOperation {
        case refresh
        case control(VehicleControlAction)
        case readOldRideData
        case clearOldRideData

        var isMutation: Bool {
            switch self {
            case .refresh, .readOldRideData:
                return false
            case .control, .clearOldRideData:
                return true
            }
        }

        var title: String {
            switch self {
            case .refresh: return "状态刷新"
            case .control(let action): return action.rawValue
            case .readOldRideData: return "旧骑行数据读取"
            case .clearOldRideData: return "旧骑行数据清除"
            }
        }
    }

    private struct WriteTicket {
        let label: String
        let generation: Int
    }

    private let serviceUUID = CBUUID(string: IoTDeviceProfile.serviceUUID)
    private let writeUUID = CBUUID(string: IoTDeviceProfile.writeUUID)
    private let notifyUUID = CBUUID(string: IoTDeviceProfile.notifyUUID)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var connectionKey: UInt8 = 0
    private var controlSession = BLEControlSession()
    private var scanRequested = false
    private var pendingOperation: PendingOperation?
    private var refreshContext: RefreshContext?
    private var pendingWriteTickets: [WriteTicket] = []
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
        guard !isOperating else {
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
        resetTransport()
        resetDeviceState()
        lastOutcome = .none
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
        if let pendingOperation, pendingOperation.isMutation {
            failOperation("用户在\(pendingOperation.title)完成前手动断开蓝牙")
            return
        }
        cancelCurrentOperation()
        operationMessage = "蓝牙已手动断开"
        requestDisconnect()
    }

    func unlock() {
        appendEvent("交互", "用户完成开锁长按")
        startControl(.unlock)
    }

    func lock() {
        appendEvent("交互", "用户完成关锁长按")
        startControl(.lock)
    }

    func refreshDeviceState() {
        guard canRunProtocolCommand else {
            operationMessage = "请等待当前操作完成"
            return
        }
        startRefresh(context: .manual)
    }

    func requestOldRideData() {
        guard beginOperation(.readOldRideData, message: "正在读取旧骑行数据") else { return }
        guard send(.oldRideData, payload: [0x01], label: "旧骑行数据读取") else {
            failOperation("旧骑行数据读取通道不可用")
            return
        }
    }

    func clearOldRideData() {
        guard oldRideData != nil else {
            operationMessage = "请先读取并保存旧骑行数据"
            return
        }
        guard beginOperation(.clearOldRideData, message: "正在清除设备中的旧骑行数据") else { return }
        guard send(.clearRideData, payload: [0x01], label: "旧骑行数据清除") else {
            failOperation("旧骑行数据清除通道不可用")
            return
        }
    }

    func saveDeviceKey(_ key: String) -> Bool {
        guard !isOperating else {
            operationMessage = "设备操作进行中，不能修改设备密钥"
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
            operationMessage = "设备操作进行中，不能删除设备密钥"
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

    private func startControl(_ action: VehicleControlAction) {
        guard canRunProtocolCommand,
              controlSession.canStartAction,
              lockState != .unknown else {
            operationMessage = "请等待锁态读取完成后再操作"
            appendEvent("安全", "锁态未知或已有操作，未发送控制指令")
            return
        }
        guard !lockState.matches(action) else {
            operationMessage = action == .unlock ? "车辆已经开锁" : "车辆已经关锁"
            appendEvent("幂等", "当前锁态与请求一致，未发送控制指令")
            return
        }
        guard controlSession.begin(action) else {
            operationMessage = "已有车辆控制正在进行"
            return
        }
        guard beginOperation(.control(action), message: "正在发送\(action.rawValue)指令", timeout: 12) else {
            controlSession.finishAction()
            return
        }

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

        lastOutcome = .sending(action)
        appendEvent("控制", "已创建单次\(action.rawValue)请求")
        guard send(action.command, payload: payload, label: action.rawValue) else {
            failOperation("蓝牙写入通道不可用")
            return
        }
        appendEvent("控制", "已请求写入\(action.rawValue)指令，等待设备结果")
    }

    @discardableResult
    private func beginOperation(
        _ operation: PendingOperation,
        message: String,
        timeout: TimeInterval = 8
    ) -> Bool {
        guard isReady, !isOperating else {
            operationMessage = isReady ? "请等待当前操作完成" : "请先连接并认证设备"
            return false
        }
        pendingOperation = operation
        isOperating = true
        operationMessage = message
        operationGeneration += 1
        let generation = operationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self,
                  self.isOperating,
                  self.operationGeneration == generation else {
                return
            }
            self.failOperation("\(operation.title)未在规定时间内返回")
        }
        return true
    }

    private func startRefresh(context: RefreshContext) {
        switch context {
        case .initial:
            guard beginOperation(.refresh, message: "设备认证成功，正在读取完整状态") else { return }
        case .manual:
            guard beginOperation(.refresh, message: "正在刷新锁和滑板车状态") else { return }
        case .control:
            guard isOperating,
                  case .control = pendingOperation else {
                failOperation("控制后状态回读上下文已失效")
                return
            }
            operationMessage = "正在回读控制后的锁态"
        }
        refreshContext = context
        appendEvent("状态", "请求锁信息 0x31")
        guard send(.lockDetails, payload: [0x01], label: "锁信息读取") else {
            failOperation("锁信息读取通道不可用")
            return
        }
    }

    private func processFrame(_ frame: DecodedOmniFrame) {
        switch frame.command {
        case OmniCommand.authenticate.rawValue:
            processAuthentication(frame.content)
        case OmniCommand.commandError.rawValue:
            processCommandError(frame.content)
        case OmniCommand.unlock.rawValue, OmniCommand.lock.rawValue:
            processControlResult(frame)
        case OmniCommand.lockDetails.rawValue:
            processLockDetails(frame.content)
        case OmniCommand.oldRideData.rawValue:
            processOldRideData(frame.content)
        case OmniCommand.clearRideData.rawValue:
            processClearOldRideDataResult(frame.content)
        case OmniCommand.rideInfo.rawValue:
            processScooterInfo(frame.content)
        case OmniCommand.settings.rawValue, OmniCommand.settings2.rawValue,
             OmniCommand.externalEquipment.rawValue:
            appendEvent("协议", "忽略已停用功能的设备回包")
        default:
            appendEvent("协议", "忽略文档外 BLE 命令 0x\(String(format: "%02X", frame.command))")
        }
    }

    private func processAuthentication(_ content: [UInt8]) {
        guard !controlSession.isAuthenticated else {
            appendEvent("协议", "忽略重复认证结果")
            return
        }
        guard content.count >= 2, content[0] == 1 else {
            failConnection("设备密钥认证失败")
            return
        }
        connectionKey = content[1]
        controlSession.acceptAuthentication()
        phase = .ready
        appendEvent("BLE", "设备认证成功")
        startRefresh(context: .initial)
    }

    private func processCommandError(_ content: [UInt8]) {
        let message: String
        switch content.first {
        case 1: message = "设备报告 CRC 认证错误"
        case 2: message = "设备报告尚未获取通信 Key"
        case 3: message = "设备报告通信 Key 错误"
        default: message = "设备返回未知协议错误"
        }
        appendEvent("协议", message)
        if let action = controlSession.pendingAction {
            lastOutcome = .unknown(action)
        }
        cancelCurrentOperation()
        operationMessage = message
        requestDisconnect()
    }

    private func processControlResult(_ frame: DecodedOmniFrame) {
        guard case .control(let operationAction) = pendingOperation,
              let action = controlSession.pendingAction,
              action == operationAction,
              frame.command == action.command.rawValue else {
            appendEvent("协议", "忽略与当前操作无关的控制结果")
            return
        }
        guard let result = frame.content.first else {
            failOperation("设备控制结果为空")
            return
        }
        guard let accepted = controlSession.recordResult(command: frame.command, value: result) else {
            appendEvent("协议", "忽略当前操作的重复结果")
            return
        }
        operationMessage = accepted
            ? "设备已接收\(action.rawValue)指令，正在发送回执"
            : "设备拒绝或未完成\(action.rawValue)，正在发送回执"
        appendEvent("控制", "收到\(action.rawValue)协议结果，立即发送必要回执")
        guard send(action.command, payload: [0x02], label: "\(action.rawValue)回执") else {
            failOperation("必要回执写入通道不可用")
            return
        }
        let generation = operationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self,
                  self.isOperating,
                  self.operationGeneration == generation else {
                return
            }
            self.startRefresh(context: .control)
        }
    }

    private func processLockDetails(_ content: [UInt8]) {
        guard let (state, snapshot) = OmniProtocol.lockDetails(from: content) else {
            failOperation("锁信息回包长度不足")
            return
        }
        lockState = state
        lockSnapshot = snapshot
        appendEvent("状态", "锁信息回读：\(lockState.rawValue)，旧数据：\(lockSnapshot.hasOldRideData ? "有" : "无")")

        guard refreshContext != nil else {
            operationMessage = "锁信息已更新"
            return
        }
        operationMessage = "锁信息已更新，正在读取滑板车状态"
        guard send(.rideInfo, payload: [0x01], label: "滑板车信息读取") else {
            failOperation("滑板车信息读取通道不可用")
            return
        }
    }

    private func processScooterInfo(_ content: [UInt8]) {
        guard let snapshot = OmniProtocol.scooterInfo(from: content) else {
            failOperation("滑板车信息回包长度不足")
            return
        }
        scooterSnapshot = snapshot
        appendEvent("状态", "滑板车信息已更新")

        guard let context = refreshContext else {
            operationMessage = "滑板车信息已更新"
            return
        }
        refreshContext = nil
        switch context {
        case .initial, .manual:
            completeOperation("状态已刷新，蓝牙保持连接")
        case .control:
            finishControlAfterReadback()
        }
    }

    private func processOldRideData(_ content: [UInt8]) {
        guard case .readOldRideData = pendingOperation,
              let decoded = OmniProtocol.oldRideData(from: content) else {
            failOperation("旧骑行数据回包格式不完整")
            return
        }
        oldRideData = decoded
        appendEvent("数据", "旧骑行数据已读取，敏感字段未写入诊断")
        completeOperation("旧骑行数据已读取，请保存后再决定是否清除")
    }

    private func processClearOldRideDataResult(_ content: [UInt8]) {
        guard case .clearOldRideData = pendingOperation,
              let result = content.first else {
            appendEvent("协议", "忽略与当前操作无关的结果")
            return
        }
        let accepted = result == 0
        if accepted {
            oldRideData = nil
            lockSnapshot.hasOldRideData = false
            appendEvent("数据", "设备确认旧骑行数据已清除")
            completeOperation("设备返回旧数据清除成功，蓝牙保持连接")
        } else {
            completeOperation("设备返回旧数据清除失败")
        }
    }

    private func finishControlAfterReadback() {
        guard case .control(let operationAction) = pendingOperation,
              let action = controlSession.pendingAction,
              action == operationAction,
              let accepted = controlSession.resultAccepted else {
            failOperation("控制结果与状态回读上下文不完整")
            return
        }
        operationGeneration += 1
        isOperating = false
        pendingOperation = nil
        controlSession.finishAction()

        if !accepted {
            lastOutcome = .rejected(action)
            operationMessage = "设备未完成\(action.rawValue)，当前\(lockState.rawValue)，蓝牙保持连接"
            appendEvent("控制", "设备结果为拒绝，状态回读为\(lockState.rawValue)")
        } else if lockState.matches(action) {
            lastOutcome = .accepted(action)
            operationMessage = "设备回包与状态回读一致，蓝牙保持连接"
            appendEvent("控制", "设备回包与状态回读一致")
        } else {
            lastOutcome = .unknown(action)
            operationMessage = "设备回包与状态回读不一致，结果未知"
            appendEvent("控制", "设备回包与状态回读不一致，主动断开")
            requestDisconnect()
        }
    }

    private func completeOperation(_ message: String) {
        operationGeneration += 1
        isOperating = false
        pendingOperation = nil
        refreshContext = nil
        operationMessage = message
    }

    private func cancelCurrentOperation() {
        operationGeneration += 1
        isOperating = false
        pendingOperation = nil
        refreshContext = nil
        controlSession.finishAction()
    }

    private func failOperation(_ reason: String) {
        guard let operation = pendingOperation else {
            failConnection(reason)
            return
        }
        let isMutation = operation.isMutation
        if let action = controlSession.pendingAction {
            lastOutcome = .unknown(action)
        }
        operationGeneration += 1
        isOperating = false
        pendingOperation = nil
        refreshContext = nil
        controlSession.finishAction()
        operationMessage = isMutation
            ? "\(operation.title)结果未知，蓝牙已停止并断开"
            : reason
        appendEvent(isMutation ? "安全" : "错误", reason)
        if isMutation {
            requestDisconnect()
        }
    }

    @discardableResult
    private func send(_ command: OmniCommand, payload: [UInt8], label: String) -> Bool {
        guard let peripheral, let writeCharacteristic else {
            return false
        }
        pendingWriteTickets.append(WriteTicket(label: label, generation: operationGeneration))
        peripheral.writeValue(
            OmniProtocol.makeFrame(
                command: command,
                payload: payload,
                connectionKey: connectionKey
            ),
            for: writeCharacteristic,
            type: .withResponse
        )
        return true
    }

    private func authenticate() {
        guard let key = DeviceKeyVault.read() else {
            phase = .needsDeviceKey
            operationMessage = "设备密钥不存在"
            return
        }
        do {
            phase = .authenticating
            guard let peripheral, let writeCharacteristic else {
                failConnection("认证写入通道不可用")
                return
            }
            pendingWriteTickets.append(WriteTicket(label: "设备认证", generation: operationGeneration))
            peripheral.writeValue(
                try OmniProtocol.authenticationFrame(deviceKey: key),
                for: writeCharacteristic,
                type: .withResponse
            )
            appendEvent("BLE", "已请求写入认证帧")
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
            phase = deviceKeyStored ? .disconnected : .needsDeviceKey
        }
    }

    private func resetTransport() {
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        connectionKey = 0
        controlSession.reset()
        pendingOperation = nil
        refreshContext = nil
        pendingWriteTickets.removeAll()
        isOperating = false
        operationGeneration += 1
    }

    private func resetDeviceState() {
        lockState = .unknown
        lockSnapshot = LockSnapshot()
        scooterSnapshot = ScooterSnapshot()
        oldRideData = nil
        rssi = nil
    }

    private func failConnection(_ message: String) {
        central?.stopScan()
        scanRequested = false
        scanGeneration += 1
        if let action = controlSession.pendingAction {
            lastOutcome = .unknown(action)
        }
        cancelCurrentOperation()
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
        if events.count > 120 {
            events.removeLast(events.count - 120)
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
            if pendingOperation?.isMutation == true {
                failOperation("系统蓝牙在设备操作过程中不可用")
            } else {
                cancelCurrentOperation()
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
              manufacturer.starts(with: IoTDeviceProfile.manufacturerData) else {
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
        let interruptedOperation = pendingOperation
        let interruptedAction = controlSession.pendingAction
        let wasFailed = phase == .failed
        resetTransport()
        if interruptedOperation?.isMutation == true {
            if let interruptedAction {
                lastOutcome = .unknown(interruptedAction)
            }
            operationMessage = "连接提前断开，\(interruptedOperation?.title ?? "设备操作")结果未知"
            appendEvent("安全", "设备操作完成前蓝牙断开，不会自动重连或重试")
        }
        if !wasFailed {
            phase = deviceKeyStored ? .disconnected : .needsDeviceKey
        }
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
            if pendingOperation?.isMutation == true {
                failOperation(error?.localizedDescription ?? "Notify 读取失败")
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
        let ticket = pendingWriteTickets.isEmpty ? nil : pendingWriteTickets.removeFirst()
        if let error {
            let label = ticket?.label ?? "未知写入"
            if let ticket, ticket.generation != operationGeneration {
                appendEvent("BLE", "忽略已完成操作的迟到写入错误：\(label)")
                return
            }
            if pendingOperation?.isMutation == true {
                failOperation("\(label)写入失败：\(error.localizedDescription)")
            } else {
                failConnection("\(label)写入失败：\(error.localizedDescription)")
            }
            return
        }
        controlSession.noteWriteCompleted()
        appendEvent("BLE", "设备确认收到\(ticket?.label ?? "一次写入")")
    }
}

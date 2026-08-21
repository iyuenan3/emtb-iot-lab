import Foundation
import CoreBluetooth

final class BLEDeviceManager: NSObject, ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var snapshot = DeviceSnapshot()
    @Published private(set) var lockStateUpdatedAt: Date?
    @Published private(set) var completedLockEvent: PendingBLEEvent?
    @Published private(set) var events: [FieldLogEvent] = []
    @Published private(set) var capabilityResults: [String: RemoteCapabilityLatestResult] = [:]
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isBusy = false
    @Published private(set) var operationMessage = ""
    @Published private(set) var oldRideDataHex = ""
    @Published private(set) var deviceKeyStored = false
    @Published private(set) var maintenanceKeyStored = KeychainStore.read(account: "maintenance-key") != nil

    private let serviceUUID = CBUUID(string: IoTDeviceProfile.serviceUUID)
    private let writeUUID = CBUUID(string: IoTDeviceProfile.writeUUID)
    private let notifyUUID = CBUUID(string: IoTDeviceProfile.notifyUUID)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var connectionKey: UInt8 = 0
    private var shouldReconnect = false
    private var scanRequested = false
    private var busyGeneration = 0

    private struct PendingLockMutation {
        let action: String
        let expectedLockState: String
        let deviceOperationAt: Int
        var responseConfirmed = false
    }
    private var pendingLockMutation: PendingLockMutation?

    private var systemReadActive = false
    private var systemTotalPages = 0
    private var systemNextPage = 0
    private var systemDeviceType: UInt8 = 0x42
    private var systemBuffer: [UInt8] = []
    private var systemRawBuffer: [UInt8] = []
    private var deviceLogMode = false

    private enum TransferKind { case configuration, ota }
    private struct TransferJob {
        let kind: TransferKind
        let bytes: [UInt8]
        let pageSize: Int
        let pageCount: Int
    }
    private struct ExportLogEvent: Codable {
        let timestamp: Date
        let category: String
        let message: String
    }
    private var transferJob: TransferJob?

    override init() {
        super.init()
        do {
            try DeviceKeyVault.migrateLegacyKeyIfNeeded()
        } catch {
            appendEvent("安全", "旧设备密钥迁移失败，原密钥仍保留")
        }
        refreshDeviceKeyState()
        central = CBCentralManager(delegate: self, queue: .main)
        saveSnapshot()
        appendEvent("APP", "离线 Field Lab 已启动")
    }

    var isReady: Bool { phase == .ready && isAuthenticated }

    func saveDeviceKey(_ key: String) throws {
        try validateDeviceKey(key)
        if DeviceKeyVault.read() == key {
            completeNoOp("设备密钥未变化，无需更新")
            return
        }
        let isUpdate = DeviceKeyVault.containsKey
        if isUpdate { disconnect(manual: true) }
        try DeviceKeyVault.save(key)
        refreshDeviceKeyState()
        phase = .idle
        appendEvent("安全", isUpdate ? "设备密钥已更新到本机 Keychain" : "设备密钥已保存到本机 Keychain")
    }

    func deleteDeviceKey() {
        disconnect(manual: true)
        DeviceKeyVault.delete()
        refreshDeviceKeyState()
        phase = .needsDeviceKey
        appendEvent("安全", "设备密钥已从 Keychain 删除")
    }

    func saveMaintenanceKey(_ key: String) throws {
        guard key.utf8.count == 4, key.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw NSError(domain: "IoTBluetooth", code: 1, userInfo: [NSLocalizedDescriptionKey: "维护密钥必须为 4 个 ASCII 字节"])
        }
        if KeychainStore.read(account: "maintenance-key") == key {
            completeNoOp("维护密钥未变化，无需更新")
            return
        }
        try KeychainStore.save(key, account: "maintenance-key")
        maintenanceKeyStored = true
        appendEvent("安全", "维护密钥已保存到本机 Keychain")
    }

    func deleteMaintenanceKey() {
        KeychainStore.delete(account: "maintenance-key")
        maintenanceKeyStored = false
        appendEvent("安全", "维护密钥已从 Keychain 删除")
    }

    func scanAndConnect() {
        guard DeviceKeyVault.containsKey else { phase = .needsDeviceKey; return }
        scanRequested = true
        shouldReconnect = true
        guard central.state == .poweredOn else {
            phase = .bluetoothOff
            return
        }
        resetConnectionSession()
        phase = .scanning
        appendEvent("BLE", "开始扫描已配置的目标设备")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.phase == .scanning else { return }
            self.central.stopScan()
            self.fail("20 秒内未发现目标设备")
        }
    }

    func disconnect(manual: Bool = true) {
        if manual { shouldReconnect = false }
        scanRequested = false
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        resetConnectionSession()
        phase = .disconnected
        appendEvent("BLE", manual ? "已手动断开" : "设备连接断开")
    }

    func refreshAll() {
        guardReady {
            beginBusy("正在读取设备状态", timeout: 20)
            send(.lockDetails, payload: [0x01])
        }
    }

    func unlock() {
        guardReady {
            guard snapshot.isLocked != false else {
                completeNoOp("当前已开锁，无需重复操作")
                return
            }
            beginBusy("正在开锁", timeout: 6, timeoutMessage: "开锁命令未回包，已停止等待并回读状态", readBackLockOnTimeout: true)
            let userID: UInt32 = 1
            let timestamp = UInt32(Date().timeIntervalSince1970)
            pendingLockMutation = PendingLockMutation(
                action: "unlock", expectedLockState: "unlocked",
                deviceOperationAt: Int(timestamp)
            )
            let payload: [UInt8] = [0x01] + OmniProtocol.bytes(of: userID) + OmniProtocol.bytes(of: timestamp) + [0x00]
            send(.unlock, payload: payload)
            appendEvent("控制", "已发送开锁请求，等待设备结果")
        }
    }

    func lock() {
        guardReady {
            guard snapshot.isLocked != true else {
                completeNoOp("当前已关锁，无需重复操作")
                return
            }
            beginBusy("正在关锁", timeout: 6, timeoutMessage: "关锁命令未回包，已停止等待并回读状态", readBackLockOnTimeout: true)
            pendingLockMutation = PendingLockMutation(
                action: "lock", expectedLockState: "locked",
                deviceOperationAt: Int(Date().timeIntervalSince1970)
            )
            send(.lock, payload: [0x01])
            appendEvent("控制", "已发送关锁请求，等待设备结果")
        }
    }

    func apply(_ setting: ScooterSetting) {
        guardReady {
            if setting.matches(rideMode: snapshot.rideMode) {
                completeNoOp("当前已经是\(setting.rawValue)，无需重复设置")
                return
            }
            beginBusy(setting.rawValue)
            send(.settings, payload: setting.payload)
            appendEvent("控制", "已发送设置：\(setting.rawValue)")
        }
    }

    func applySettings2(persist: Bool, cruise: Int, startMode: Int, low: Int, medium: Int, high: Int) {
        guardReady {
            let payload = [persist ? 1 : 0, cruise, startMode, low, medium, high].map(UInt8.init)
            beginBusy("正在发送高级滑板车设置")
            send(.settings2, payload: payload)
            appendEvent("控制", "已发送滑板车设置 2")
        }
    }

    func operateExternalLock(_ operation: ExternalLockOperation) {
        guardReady {
            beginBusy(operation.rawValue)
            send(.externalEquipment, payload: [operation.code])
            appendEvent("外设", "已发送：\(operation.rawValue)")
        }
    }

    func startRFIDRegistration() {
        guardReady {
            beginBusy("正在等待 RFID 卡", timeout: 30, timeoutMessage: "RFID 登记等待超时")
            send(.rfid, payload: [0x01])
            appendEvent("RFID", "已启动 RFID 登记")
        }
    }

    func setScooterPower(on: Bool) {
        guardReady {
            beginBusy(on ? "正在开机" : "正在关机")
            send(.power, payload: [on ? 0x02 : 0x01])
            appendEvent("控制", on ? "已发送滑板车开机" : "已发送滑板车关机")
        }
    }

    func requestOldRideData() {
        guardReady {
            beginBusy("正在读取未上传骑行数据")
            send(.oldRideData, payload: [0x01])
            appendEvent("数据", "正在读取未上传骑行数据")
        }
    }

    func clearOldRideData() {
        guardReady {
            beginBusy("正在清除旧骑行数据")
            send(.clearRideData, payload: [0x01])
            appendEvent("数据", "已发送旧骑行数据清除命令")
        }
    }

    func startDeviceLog() {
        guardReady {
            deviceLogMode = false
            send(.log, payload: [OmniCommand.log.rawValue])
            appendEvent("日志", "已请求设备诊断日志")
        }
    }

    func modifyServer(ip: String, port: String) throws {
        guard !ip.isEmpty, UInt16(port) != nil else {
            throw NSError(domain: "IoTBluetooth", code: 2, userInfo: [NSLocalizedDescriptionKey: "服务器地址或端口格式不正确"])
        }
        try guardReadyOrThrow()
        if snapshot.systemInfo["IP"] == ip,
           snapshot.systemInfo["PORT"] == port,
           snapshot.systemInfo["IPMODE"] == "1" {
            completeNoOp("服务器配置未变化，无需重复写入")
            return
        }
        try startConfigurationTransfer("IP:\(ip),PORT:\(port),IPMODE:1,")
    }

    func modifyAPN(apn: String, user: String, password: String) throws {
        guard !apn.isEmpty else {
            throw NSError(domain: "IoTBluetooth", code: 3, userInfo: [NSLocalizedDescriptionKey: "APN 不能为空"])
        }
        try guardReadyOrThrow()
        if password.isEmpty,
           snapshot.systemInfo["APN"] == apn,
           snapshot.systemInfo["USER", default: ""] == user {
            completeNoOp("APN 配置未变化，无需重复写入")
            return
        }
        try startConfigurationTransfer("APN:\(apn),USER:\(user),PW:\(password),")
    }

    func startOTA(fileData: Data) throws {
        try guardReadyOrThrow()
        let verify = try maintenanceKeyBytes()
        guard !fileData.isEmpty else {
            throw NSError(domain: "IoTBluetooth", code: 4, userInfo: [NSLocalizedDescriptionKey: "固件文件为空"])
        }
        try startTransfer(kind: .ota, content: [UInt8](fileData), verifyKey: verify)
        appendEvent("OTA", "已开始固件传输，共 \(fileData.count) 字节")
    }

    var exportLogURL: URL? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let safeEvents = events.map {
            ExportLogEvent(
                timestamp: $0.timestamp,
                category: $0.category,
                message: Self.redactPrivacy(in: $0.message)
            )
        }
        guard let data = try? encoder.encode(safeEvents) else { return nil }
        let url = documentsDirectory.appendingPathComponent("iot-field-log.json")
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    private func startConfigurationTransfer(_ content: String) throws {
        try guardReadyOrThrow()
        let verify = try maintenanceKeyBytes()
        try startTransfer(kind: .configuration, content: Array(content.utf8), verifyKey: verify)
        appendEvent("配置", "已开始发送系统配置，敏感值不写入日志")
    }

    private func startTransfer(kind: TransferKind, content: [UInt8], verifyKey: [UInt8]) throws {
        let pageSize = 16
        let pages = (content.count + pageSize - 1) / pageSize
        var padded = content
        padded.append(contentsOf: repeatElement(0, count: pages * pageSize - content.count))
        let checksum = OmniProtocol.crc16(padded)
        transferJob = TransferJob(kind: kind, bytes: content, pageSize: pageSize, pageCount: pages)
        let mode: UInt8 = kind == .configuration ? 0x01 : 0x00
        let payload: [UInt8] = [
            mode,
            UInt8((pages >> 8) & 0xFF), UInt8(pages & 0xFF),
            UInt8(checksum >> 8), UInt8(checksum & 0xFF),
            systemDeviceType
        ] + verifyKey
        beginBusy(
            kind == .configuration ? "正在修改系统配置" : "正在传输固件",
            timeout: kind == .configuration ? 30 : 120,
            timeoutMessage: kind == .configuration ? "系统配置等待超时" : "固件传输等待超时"
        )
        send(.transferStart, payload: payload)
    }

    private func maintenanceKeyBytes() throws -> [UInt8] {
        guard let key = KeychainStore.read(account: "maintenance-key"), key.utf8.count == 4 else {
            throw NSError(domain: "IoTBluetooth", code: 5, userInfo: [NSLocalizedDescriptionKey: "请先在安全设置中保存 4 字节维护密钥"])
        }
        return Array(key.utf8)
    }

    private func guardReadyOrThrow() throws {
        guard isReady else {
            throw NSError(domain: "IoTBluetooth", code: 6, userInfo: [NSLocalizedDescriptionKey: "请先连接并认证设备"])
        }
        guard !isBusy else {
            throw NSError(domain: "IoTBluetooth", code: 7, userInfo: [NSLocalizedDescriptionKey: "已有操作正在进行，请稍后再试"])
        }
    }

    private func guardReady(_ action: () -> Void) {
        guard isReady else { fail("请先连接并认证设备"); return }
        guard !isBusy else {
            appendEvent("幂等", "已有操作正在进行，忽略重复请求")
            return
        }
        action()
    }

    private func send(_ command: OmniCommand, payload: [UInt8]) {
        sendRaw(OmniProtocol.makeFrame(command: command.rawValue, payload: payload, connectionKey: connectionKey))
    }

    private func sendRaw(_ data: Data) {
        guard let peripheral, let writeCharacteristic else { fail("写入通道尚未就绪"); return }
        peripheral.writeValue(data, for: writeCharacteristic, type: .withResponse)
    }

    private func authenticate() {
        guard let key = DeviceKeyVault.read() else { phase = .needsDeviceKey; return }
        do {
            phase = .authenticating
            sendRaw(try OmniProtocol.authenticationFrame(deviceKey: key))
            appendEvent("BLE", "已发送认证请求")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func processFrame(_ frame: DecodedOmniFrame) {
        let content = frame.content
        switch frame.command {
        case OmniCommand.authenticate.rawValue:
            guard content.count >= 2, content[0] == 1 else {
                recordCapabilityResult(
                    "ble.01", status: "failed", errorCode: "authentication_failed",
                    summary: "认证结果无效，回包长度 \(content.count) 字节"
                )
                fail("设备密钥认证失败")
                return
            }
            connectionKey = content[1]
            isAuthenticated = true
            phase = .ready
            recordCapabilityResult(
                "ble.01", status: "succeeded", summary: "认证成功，回包长度 \(content.count) 字节"
            )
            appendEvent("BLE", "设备认证成功")
            refreshAll()

        case OmniCommand.lockDetails.rawValue:
            if content.count >= 3 {
                snapshot.powerRaw = Int(content[0]) * 256 + Int(content[1])
                snapshot.isLocked = (content[2] & 0x01) == 0
                snapshot.capturedAt = Date()
                appendEvent("状态", snapshot.isLocked == true ? "设备当前为关锁状态" : "设备当前为开锁状态")
                if !completePendingLockMutation(isLocked: snapshot.isLocked == true) {
                    lockStateUpdatedAt = snapshot.capturedAt
                }
                recordCapabilityResult(
                    "ble.31", status: "succeeded",
                    summary: "回包长度 \(content.count) 字节，锁状态 \(snapshot.isLocked == true ? "关锁" : "开锁")"
                )
            } else {
                recordCapabilityResult(
                    "ble.31", status: "failed", errorCode: "response_too_short",
                    summary: "回包长度不足，仅 \(content.count) 字节"
                )
            }
            send(.rideInfo, payload: [0x01])

        case OmniCommand.rideInfo.rawValue:
            if content.count >= 2 {
                snapshot.scooterBatteryPercent = Int(content[0])
                snapshot.rideMode = Int(content[1])
                recordCapabilityResult(
                    "ble.60", status: "succeeded",
                    summary: "回包长度 \(content.count) 字节，电量 \(content[0])%，模式 \(content[1])"
                )
            } else {
                recordCapabilityResult(
                    "ble.60", status: "failed", errorCode: "response_too_short",
                    summary: "回包长度不足，仅 \(content.count) 字节"
                )
            }
            beginSystemInfoRead()

        case OmniCommand.unlock.rawValue:
            let success = content.first == 1
            recordCapabilityResult(
                "ble.05", status: success ? "succeeded" : "failed",
                errorCode: success ? nil : "device_rejected",
                summary: "回包长度 \(content.count) 字节，设备结果 \(content.first.map(String.init) ?? "无")"
            )
            appendEvent("控制", success ? "设备确认开锁成功" : "设备返回开锁失败或超时")
            operationMessage = success ? "开锁成功，正在回读" : "开锁失败"
            if success {
                pendingLockMutation?.responseConfirmed = true
            } else {
                pendingLockMutation = nil
            }
            send(.unlock, payload: [0x02])
            finishMutationWithReadback()

        case OmniCommand.lock.rawValue:
            let success = content.first == 1
            recordCapabilityResult(
                "ble.15", status: success ? "succeeded" : "failed",
                errorCode: success ? nil : "device_rejected",
                summary: "回包长度 \(content.count) 字节，设备结果 \(content.first.map(String.init) ?? "无")"
            )
            appendEvent("控制", success ? "设备确认关锁成功" : "设备返回关锁失败或超时")
            operationMessage = success ? "关锁成功，正在回读" : "关锁失败"
            if success {
                pendingLockMutation?.responseConfirmed = true
            } else {
                pendingLockMutation = nil
            }
            send(.lock, payload: [0x02])
            finishMutationWithReadback()

        case OmniCommand.settings.rawValue, OmniCommand.settings2.rawValue,
             OmniCommand.externalEquipment.rawValue, OmniCommand.rfid.rawValue,
             OmniCommand.power.rawValue, OmniCommand.clearRideData.rawValue:
            let capabilityID: String
            switch frame.command {
            case OmniCommand.settings.rawValue: capabilityID = "ble.61"
            case OmniCommand.settings2.rawValue: capabilityID = "ble.62"
            case OmniCommand.externalEquipment.rawValue: capabilityID = "ble.81"
            case OmniCommand.rfid.rawValue: capabilityID = "archive.rfid"
            case OmniCommand.power.rawValue: capabilityID = "archive.power"
            default: capabilityID = "ble.52"
            }
            recordCapabilityResult(
                capabilityID, status: "succeeded",
                summary: "回包长度 \(content.count) 字节，首字段 \(content.first.map(String.init) ?? "无")"
            )
            appendEvent("设备", "命令 0x\(String(format: "%02X", frame.command)) 返回：\(content.first.map(String.init) ?? "无数据")")
            finishBusy("操作已返回")

        case OmniCommand.oldRideData.rawValue:
            oldRideDataHex = content.map { String(format: "%02X", $0) }.joined()
            recordCapabilityResult(
                "ble.51", status: "succeeded",
                summary: "收到旧骑行数据 \(content.count) 字节，正文不进入指令中心"
            )
            appendEvent("数据", content.isEmpty ? "设备没有返回旧骑行数据" : "已读取旧骑行数据，需确认后再清除")
            finishBusy("骑行数据读取完成")

        case OmniCommand.commandError.rawValue:
            let error = content.first.map(String.init) ?? "unknown"
            recordCapabilityResult(
                "ble.10", status: "failed", errorCode: "ble_error_\(error)",
                summary: "设备返回协议错误，回包长度 \(content.count) 字节，错误码 \(error)"
            )
            fail("设备拒绝命令，错误码 \(content.first.map(String.init) ?? "未知")")

        case OmniCommand.transferStart.rawValue:
            startSystemInfoPages(frame.decrypted)

        case OmniCommand.transferPage.rawValue:
            processTransferPageRequest(content)

        case OmniCommand.log.rawValue:
            deviceLogMode = true
            recordCapabilityResult(
                "archive.logs", status: "succeeded",
                summary: "设备诊断日志流已开启，日志正文不进入指令中心"
            )
            appendEvent("日志", "设备诊断日志流已开启")

        default:
            appendEvent("RX", "收到命令 0x\(String(format: "%02X", frame.command))，长度 \(content.count)")
        }
    }

    private func beginSystemInfoRead() {
        systemReadActive = false
        systemRawBuffer.removeAll()
        systemBuffer.removeAll()
        operationMessage = "正在读取系统信息"
        sendRaw(OmniProtocol.makeFrame(command: 0xFA, payload: [], connectionKey: connectionKey))
    }

    private func startSystemInfoPages(_ decrypted: [UInt8]) {
        guard transferJob == nil, decrypted.count >= 16 else { return }
        systemTotalPages = Int(decrypted[7]) * 256 + Int(decrypted[8])
        systemDeviceType = decrypted[11]
        systemNextPage = 0
        systemReadActive = true
        requestSystemPage(0)
    }

    private func requestSystemPage(_ page: Int) {
        send(.transferPage, payload: [UInt8((page >> 8) & 0xFF), UInt8(page & 0xFF), systemDeviceType])
    }

    private func processSystemPageBytes(_ data: Data) {
        systemRawBuffer.append(contentsOf: data)
        while systemRawBuffer.count >= 20 {
            let page = Array(systemRawBuffer.prefix(20))
            systemRawBuffer.removeFirst(20)
            let number = Int(page[2]) * 256 + Int(page[3])
            guard number == systemNextPage else { fail("系统信息分页顺序错误"); return }
            systemBuffer.append(contentsOf: page[4..<20])
            systemNextPage += 1
            if systemNextPage >= systemTotalPages {
                systemReadActive = false
                snapshot.systemInfo = OmniProtocol.parseSystemInfo(systemBuffer)
                snapshot.capturedAt = Date()
                send(.transferEnd, payload: [OmniCommand.transferStart.rawValue])
                finishBusy("读取完成")
                recordCapabilityResult(
                    "archive.system_transfer", status: "succeeded",
                    summary: "系统信息读取完成，共 \(systemTotalPages) 页，配置正文不进入指令中心"
                )
                appendEvent("状态", "系统信息读取完成，共 \(systemTotalPages) 页")
                saveSnapshot()
            } else {
                requestSystemPage(systemNextPage)
            }
        }
    }

    private func processTransferPageRequest(_ content: [UInt8]) {
        guard let job = transferJob, content.count >= 2 else { return }
        let page = Int(content[0]) * 256 + Int(content[1])
        guard page < job.pageCount else {
            transferJob = nil
            finishBusy("传输完成")
            appendEvent(job.kind == .configuration ? "配置" : "OTA", "设备已接收全部数据")
            if job.kind == .configuration { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshAll() } }
            return
        }
        let start = page * job.pageSize
        let end = min(start + job.pageSize, job.bytes.count)
        sendRaw(OmniProtocol.rawTransferPage(number: page, bytes: Array(job.bytes[start..<end]), pageSize: job.pageSize))
        if page == job.pageCount - 1 {
            transferJob = nil
            finishBusy("数据发送完成，等待设备应用")
            recordCapabilityResult(
                job.kind == .configuration ? "archive.system_transfer" : "archive.ota",
                status: "unknown", errorCode: "awaiting_device_apply",
                summary: "最后一页已发送，共 \(job.pageCount) 页，设备应用结果尚未确认"
            )
            appendEvent(job.kind == .configuration ? "配置" : "OTA", "最后一页已写入设备")
            if job.kind == .configuration { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshAll() } }
        }
    }

    private func finishMutationWithReadback() {
        finishBusy(operationMessage)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.isReady else { return }
            self.refreshAll()
        }
    }

    private func completePendingLockMutation(isLocked: Bool) -> Bool {
        guard let pending = pendingLockMutation, pending.responseConfirmed else { return false }
        pendingLockMutation = nil
        let readbackLockState = isLocked ? "locked" : "unlocked"
        guard readbackLockState == pending.expectedLockState else {
            appendEvent("控制", "命令成功回包与锁状态回读不一致，未生成远程事件")
            return false
        }
        completedLockEvent = PendingBLEEvent(
            action: pending.action,
            readbackLockState: readbackLockState,
            deviceOperationAt: pending.deviceOperationAt
        )
        appendEvent("同步", "BLE 操作结果已生成持久化事件")
        return true
    }

    private func saveSnapshot() {
        var safeSnapshot = snapshot
        safeSnapshot.bikeNumber = "[已脱敏]"
        safeSnapshot.imei = "[已脱敏]"
        safeSnapshot.bleMAC = "[已脱敏]"
        safeSnapshot.systemInfo = Dictionary(uniqueKeysWithValues: snapshot.systemInfo.map { key, value in
            let upper = key.uppercased()
            let sensitive = [
                "IMEI", "MAC", "IP", "HOST", "SERVER", "PORT", "APN", "USER",
                "NAME", "PASS", "PW", "KEY", "LAT", "LON", "LNG", "LOCATION"
            ].contains { upper.contains($0) }
            return (key, sensitive ? "[已脱敏]" : Self.redactPrivacy(in: value))
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(safeSnapshot) else { return }
        try? data.write(
            to: documentsDirectory.appendingPathComponent("latest-device-snapshot.json"),
            options: [.atomic, .completeFileProtection]
        )
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private func appendEvent(_ category: String, _ message: String) {
        let event = FieldLogEvent(category: category, message: message)
        events.insert(event, at: 0)
        if events.count > 500 { events.removeLast(events.count - 500) }
    }

    private func recordCapabilityResult(
        _ capabilityID: String,
        status: String,
        errorCode: String? = nil,
        summary: String
    ) {
        let now = Int(Date().timeIntervalSince1970)
        capabilityResults[capabilityID] = RemoteCapabilityLatestResult(
            status: status,
            createdAt: now,
            completedAt: now,
            errorCode: errorCode,
            rawResponseSummary: summary
        )
    }

    private static func redactPrivacy(in text: String) -> String {
        let replacements = [
            ("(?i)\\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\\b", "[BLE MAC 已脱敏]"),
            ("\\b[0-9]{14,17}\\b", "[IMEI 已脱敏]"),
            ("(?i)https?://[^\\s,]+", "[URL 已脱敏]"),
            ("(?i)\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b", "[地址已脱敏]"),
            ("(?i)\\b(?:imei|mac|ip|host|server|apn|user|username|lat|latitude|lon|lng|longitude|pw|password|key)[:=][^,\\s]+", "[敏感字段已脱敏]")
        ]
        return replacements.reduce(text) { value, replacement in
            value.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }
    }

    private func beginBusy(
        _ message: String,
        timeout: TimeInterval = 10,
        timeoutMessage: String = "设备未在规定时间内回包，已停止等待",
        readBackLockOnTimeout: Bool = false
    ) {
        busyGeneration += 1
        let generation = busyGeneration
        isBusy = true
        operationMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.isBusy, self.busyGeneration == generation else { return }
            self.busyGeneration += 1
            self.isBusy = false
            self.operationMessage = timeoutMessage
            self.appendEvent("超时", timeoutMessage)
            if readBackLockOnTimeout, self.isReady {
                self.pendingLockMutation = nil
                self.refreshAll()
            }
        }
    }

    private func finishBusy(_ message: String) {
        busyGeneration += 1
        isBusy = false
        operationMessage = message
    }

    private func completeNoOp(_ message: String) {
        finishBusy(message)
        appendEvent("幂等", message)
    }

    private func fail(_ message: String) {
        operationMessage = message
        busyGeneration += 1
        isBusy = false
        pendingLockMutation = nil
        if !isAuthenticated { phase = .failed }
        appendEvent("错误", message)
    }

    private func resetConnectionSession() {
        writeCharacteristic = nil
        notifyCharacteristic = nil
        connectionKey = 0
        isAuthenticated = false
        busyGeneration += 1
        isBusy = false
        pendingLockMutation = nil
        systemReadActive = false
        deviceLogMode = false
        transferJob = nil
    }

    private func validateDeviceKey(_ key: String) throws {
        guard key.utf8.count == 8, key.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw OmniProtocolError.invalidKeyLength
        }
    }

    private func refreshDeviceKeyState() {
        deviceKeyStored = DeviceKeyVault.containsKey
    }
}

extension BLEDeviceManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if scanRequested { scanAndConnect() }
            else { phase = deviceKeyStored ? .idle : .needsDeviceKey }
        case .poweredOff, .unauthorized, .unsupported:
            phase = .bluetoothOff
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturer == IoTDeviceProfile.manufacturerData else { return }
        self.peripheral = peripheral
        snapshot.rssi = RSSI.intValue
        central.stopScan()
        phase = .connecting
        appendEvent("BLE", "发现目标 Scooter，RSSI \(RSSI.intValue) dBm")
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        phase = .discovering
        appendEvent("BLE", "连接成功，正在发现 GATT 服务")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(error?.localizedDescription ?? "设备连接失败")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        resetConnectionSession()
        phase = .disconnected
        appendEvent("BLE", error?.localizedDescription ?? "设备已断开")
        if shouldReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.scanAndConnect() }
        }
    }
}

extension BLEDeviceManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            fail(error?.localizedDescription ?? "未发现目标 BLE 服务")
            return
        }
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { fail(error!.localizedDescription); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == writeUUID { writeCharacteristic = characteristic }
            if characteristic.uuid == notifyUUID { notifyCharacteristic = characteristic }
        }
        guard let notifyCharacteristic, writeCharacteristic != nil else { fail("目标读写特征不完整"); return }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else { fail(error?.localizedDescription ?? "Notify 订阅失败"); return }
        authenticate()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { fail(error?.localizedDescription ?? "Notify 读取失败"); return }
        if systemReadActive {
            processSystemPageBytes(data)
            return
        }
        if deviceLogMode {
            let text = String(data: data, encoding: .utf8) ?? "收到 \(data.count) 字节设备日志"
            let safe = Self.redactPrivacy(in: text)
            appendEvent("设备日志", String(safe.prefix(500)))
            return
        }
        do {
            processFrame(try OmniProtocol.decode(data))
        } catch {
            appendEvent("协议", error.localizedDescription)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("BLE 写入失败：\(error.localizedDescription)") }
    }
}

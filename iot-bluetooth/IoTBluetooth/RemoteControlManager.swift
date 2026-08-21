import CryptoKit
import Foundation
import LocalAuthentication
import Security
import UIKit
import AudioToolbox

struct RemoteVehicle: Decodable {
    let id: String
    let displayName: String
    let online: Bool
    let connectionState: String?
    let lastSeenAt: Int?
    let lockState: String
    let lockStateSource: String?
    let lockStateUpdatedAt: Int?
    let powerMv: Int?
    let batteryPercent: Int?
    let securityState: String
    let graceUntil: Int?
    let activeAlarmID: String?
    let activeTripID: String?
    let desiredTrackingInterval: Int?
    let confirmedTrackingInterval: Int?
    let trackingConfirmedAt: Int?
    let telemetryFields: [String]?
    let telemetryUpdatedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, online
        case displayName = "display_name"
        case connectionState = "connection_state"
        case lastSeenAt = "last_seen_at"
        case lockState = "lock_state"
        case lockStateSource = "lock_state_source"
        case lockStateUpdatedAt = "lock_state_updated_at"
        case powerMv = "power_mv"
        case batteryPercent = "battery_percent"
        case securityState = "security_state"
        case graceUntil = "grace_until"
        case activeAlarmID = "active_alarm_id"
        case activeTripID = "active_trip_id"
        case desiredTrackingInterval = "desired_tracking_interval"
        case confirmedTrackingInterval = "confirmed_tracking_interval"
        case trackingConfirmedAt = "tracking_confirmed_at"
        case telemetryFields = "telemetry_fields"
        case telemetryUpdatedAt = "telemetry_updated_at"
    }
}

struct RemoteCapability: Decodable {
    let enabled: Bool
    let reason: String?
    let cooldownSeconds: Int?
    let graceSeconds: Int?
    let capabilityID: String?
    let name: String?
    let group: String?
    let protocolName: String?
    let channel: String?
    let purpose: String?
    let risk: String?
    let supportStatus: String?
    let evidenceLevel: String?
    let executable: Bool?
    let disabledReason: String?
    let parametersSchema: String?
    let persistence: String?
    let latestResult: RemoteCapabilityLatestResult?

    enum CodingKeys: String, CodingKey {
        case enabled, reason
        case cooldownSeconds = "cooldown_seconds"
        case graceSeconds = "grace_seconds"
        case capabilityID = "capability_id"
        case name, group, channel, purpose, risk, executable, persistence
        case protocolName = "protocol"
        case supportStatus = "support_status"
        case evidenceLevel = "evidence_level"
        case disabledReason = "disabled_reason"
        case parametersSchema = "parameters_schema"
        case latestResult = "latest_result"
    }
}

struct RemoteCapabilityLatestResult: Decodable {
    let status: String
    let createdAt: Int
    let completedAt: Int?
    let errorCode: String?
    let rawResponseSummary: String

    enum CodingKeys: String, CodingKey {
        case status
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case errorCode = "error_code"
        case rawResponseSummary = "raw_response_summary"
    }
}

struct CapabilityDisplayItem: Identifiable {
    let id: String
    let name: String
    let group: String
    let protocolName: String
    let channel: String
    let purpose: String
    let risk: String
    let supportStatus: String
    let enabled: Bool
    let executable: Bool
    let disabledReason: String?
    let parametersSchema: String
    let persistence: String
    let latestResult: RemoteCapabilityLatestResult?
}

struct RemoteAlarm: Decodable, Identifiable {
    let id: String
    let alarmType: String
    let state: String
    let inferred: Bool
    let firstTriggeredAt: Int
    let lastTriggeredAt: Int
    let triggerCount: Int
    let acknowledgedAt: Int?
    let clearedAt: Int?
    let offlineStartedAt: Int?
    let baselineCapturedAt: Int?
    let reconnectCapturedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, state, inferred
        case alarmType = "alarm_type"
        case firstTriggeredAt = "first_triggered_at"
        case lastTriggeredAt = "last_triggered_at"
        case triggerCount = "trigger_count"
        case acknowledgedAt = "acknowledged_at"
        case clearedAt = "cleared_at"
        case offlineStartedAt = "offline_started_at"
        case baselineCapturedAt = "baseline_captured_at"
        case reconnectCapturedAt = "reconnect_captured_at"
    }
}

struct RemoteTrip: Decodable, Identifiable {
    let id: String
    let startedAt: Int
    let endedAt: Int?
    let status: String
    let recoveredAfterRestart: Bool
    let pointCount: Int
    let distanceM: Double

    enum CodingKeys: String, CodingKey {
        case id, status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case recoveredAfterRestart = "recovered_after_restart"
        case pointCount = "point_count"
        case distanceM = "distance_m"
    }
}

struct RemoteSettings: Decodable {
    let locationHistoryDays: Int
    let pendingLocationHistoryDays: Int?
    let mutableFields: [String]?
    let commandTimeoutSeconds: Int?
    let silenceWindowSeconds: Int?
    let offlineWindowSeconds: Int?
    let lockGraceSeconds: Int?
    let locationMinSatellites: Int?
    let locationMaxHdop: Double?
    let locationMaxSpeedMps: Double?
    let offlineMovementThresholdM: Double?
    let offlineSampleMaxSeparationM: Double?
    let eventRetentionDays: Int?
    let deviceSessionRetentionDays: Int?

    enum CodingKeys: String, CodingKey {
        case locationHistoryDays = "location_history_days"
        case pendingLocationHistoryDays = "pending_location_history_days"
        case mutableFields = "mutable_fields"
        case commandTimeoutSeconds = "command_timeout_seconds"
        case silenceWindowSeconds = "silence_window_seconds"
        case offlineWindowSeconds = "offline_window_seconds"
        case lockGraceSeconds = "lock_grace_seconds"
        case locationMinSatellites = "location_min_satellites"
        case locationMaxHdop = "location_max_hdop"
        case locationMaxSpeedMps = "location_max_speed_mps"
        case offlineMovementThresholdM = "offline_movement_threshold_m"
        case offlineSampleMaxSeparationM = "offline_sample_max_separation_m"
        case eventRetentionDays = "event_retention_days"
        case deviceSessionRetentionDays = "device_session_retention_days"
    }
}

struct RemoteAuditLog: Decodable, Identifiable {
    let id: Int
    let actor: String
    let action: String
    let objectType: String
    let objectID: String?
    let result: String
    let requestID: String?
    let detailSummary: String
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id, actor, action, result
        case objectType = "object_type"
        case objectID = "object_id"
        case requestID = "request_id"
        case detailSummary = "detail_summary"
        case createdAt = "created_at"
    }
}

struct RemoteDeviceSession: Decodable, Identifiable {
    let id: String
    let peerFingerprint: String
    let connectedAt: Int
    let disconnectedAt: Int?
    let disconnectReason: String?
    let rxCount: Int
    let txCount: Int
    let parseErrorCount: Int
    let lastRxAt: Int?
    let lastTxAt: Int?
    let lastQ0At: Int?
    let lastH0At: Int?
    let current: Bool
    let silenceSeconds: Int?
    let connectivityState: String
    let offlineReason: String?

    enum CodingKeys: String, CodingKey {
        case id, current
        case peerFingerprint = "peer_fingerprint"
        case connectedAt = "connected_at"
        case disconnectedAt = "disconnected_at"
        case disconnectReason = "disconnect_reason"
        case rxCount = "rx_count"
        case txCount = "tx_count"
        case parseErrorCount = "parse_error_count"
        case lastRxAt = "last_rx_at"
        case lastTxAt = "last_tx_at"
        case lastQ0At = "last_q0_at"
        case lastH0At = "last_h0_at"
        case silenceSeconds = "silence_seconds"
        case connectivityState = "connectivity_state"
        case offlineReason = "offline_reason"
    }
}

struct RemoteCommand: Decodable, Identifiable {
    let id: String
    let commandType: String
    let status: String
    let createdAt: Int
    let completedAt: Int?
    let errorCode: String?
    let result: RemoteCommandResult?

    enum CodingKeys: String, CodingKey {
        case id, status, result
        case commandType = "command_type"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case errorCode = "error_code"
    }
}

struct RemoteCommandResult: Decodable {
    let locationValid: Bool?
    let locationDisplayEligible: Bool?
    let locationRejectionReason: String?

    enum CodingKeys: String, CodingKey {
        case locationValid = "location_valid"
        case locationDisplayEligible = "location_display_eligible"
        case locationRejectionReason = "location_rejection_reason"
    }
}

struct RemoteLocation: Decodable, Identifiable {
    let id: Int
    let source: String
    let deviceTimestamp: Int?
    let receivedAt: Int
    let valid: Bool
    let displayEligible: Bool?
    let rejectionReason: String?
    let latitude: Double?
    let longitude: Double?
    let satellites: Int?
    let hdop: Double?
    let altitudeM: Double?
    let mode: String?
    let tripID: String?

    enum CodingKeys: String, CodingKey {
        case id, source, valid, latitude, longitude, satellites, hdop, mode
        case displayEligible = "display_eligible"
        case rejectionReason = "rejection_reason"
        case deviceTimestamp = "device_timestamp"
        case receivedAt = "received_at"
        case altitudeM = "altitude_m"
        case tripID = "trip_id"
    }
}

private enum RemoteCredentialVault {
    private static let serverAccount = "remote.server-url"
    private static let clientAccount = "remote.client-id"
    private static let readTokenAccount = "remote.read-token"
    private static let privateKeyAccount = "remote.control-private-key"

    static var serverURL: String? { KeychainStore.read(account: serverAccount) }
    static var clientID: String? { KeychainStore.read(account: clientAccount) }
    static var readToken: String? { KeychainStore.read(account: readTokenAccount) }

    static func saveServerURL(_ value: String) throws {
        try KeychainStore.save(value, account: serverAccount)
    }

    static func savePairing(clientID: String, readToken: String) throws {
        try KeychainStore.save(clientID, account: clientAccount)
        try KeychainStore.save(readToken, account: readTokenAccount)
    }

    static func privateKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let encoded = KeychainStore.read(account: privateKeyAccount),
           let data = Data(base64Encoded: encoded) {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        try KeychainStore.save(key.dataRepresentation.base64EncodedString(), account: privateKeyAccount)
        return key
    }

    static func clearPairing() {
        KeychainStore.delete(account: clientAccount)
        KeychainStore.delete(account: readTokenAccount)
    }
}

@MainActor
final class RemoteControlManager: ObservableObject {
    @Published var serverURL = RemoteCredentialVault.serverURL ?? ""
    @Published private(set) var vehicle: RemoteVehicle?
    @Published private(set) var capabilities: [String: RemoteCapability] = [:]
    @Published private(set) var commands: [RemoteCommand] = []
    @Published private(set) var alarms: [RemoteAlarm] = []
    @Published private(set) var trips: [RemoteTrip] = []
    @Published private(set) var selectedTrip: RemoteTrip?
    @Published private(set) var selectedTripPoints: [RemoteLocation] = []
    @Published private(set) var settings: RemoteSettings?
    @Published private(set) var auditLogs: [RemoteAuditLog] = []
    @Published private(set) var deviceSessions: [RemoteDeviceSession] = []
    @Published private(set) var latestLocation: RemoteLocation?
    @Published private(set) var lastLocationReport: RemoteLocation?
    @Published private(set) var locations: [RemoteLocation] = []
    @Published private(set) var pendingBLEEventCount = 0
    @Published private(set) var isBusy = false
    @Published private(set) var message = ""
    private let pendingBLEEventStore = PendingBLEEventStore()
    private var isFlushingBLEEvents = false
    private var lastAlertMarker: String?
    private var lastAlertAt: Date?
    private var lastAlertID: String?

    init() {
        do {
            pendingBLEEventCount = try pendingBLEEventStore.load().count
        } catch {
            message = "BLE 事件队列无法读取，请保留 App 数据并联系维护"
        }
    }

    var isPaired: Bool {
        RemoteCredentialVault.clientID != nil && RemoteCredentialVault.readToken != nil
    }

    func capabilityCatalog(
        bleResults: [String: RemoteCapabilityLatestResult]
    ) -> [CapabilityDisplayItem] {
        let remoteItems = capabilities.map { key, capability in
            let capabilityID = capability.capabilityID ?? key
            return CapabilityDisplayItem(
                id: capabilityID,
                name: capability.name ?? key,
                group: capability.group ?? "其他",
                protocolName: capability.protocolName ?? "未标注",
                channel: capability.channel ?? "远程服务",
                purpose: capability.purpose ?? "服务端未提供用途说明",
                risk: capability.risk ?? "未标注",
                supportStatus: capability.supportStatus ?? capability.evidenceLevel ?? "未标注",
                enabled: capability.enabled,
                executable: capability.executable ?? false,
                disabledReason: capability.disabledReason ?? capability.reason,
                parametersSchema: capability.parametersSchema ?? "未标注",
                persistence: capability.persistence ?? "未标注",
                latestResult: bleResults[capabilityID] ?? capability.latestResult
            )
        }
        let localItems = Self.localBLECatalog.map { item in
            CapabilityDisplayItem(
                id: item.id, name: item.name, group: item.group,
                protocolName: item.protocolName, channel: item.channel,
                purpose: item.purpose, risk: item.risk,
                supportStatus: item.supportStatus, enabled: item.enabled,
                executable: item.executable, disabledReason: item.disabledReason,
                parametersSchema: item.parametersSchema, persistence: item.persistence,
                latestResult: bleResults[item.id]
            )
        }
        return remoteItems + localItems
    }

    private static let localBLECatalog: [CapabilityDisplayItem] = [
        localBLE("ble.01", "连接认证", "0x01", "内部流程", "内部流程", "识别并认证目标 BLE 设备", "高"),
        localBLE("ble.05", "主开锁", "0x05", "常用控制", "实车已验证", "近场解除主锁", "高", executable: true),
        localBLE("ble.10", "命令错误", "0x10", "内部流程", "内部流程", "设备返回协议错误", "低"),
        localBLE("ble.15", "主关锁", "0x15", "常用控制", "实车已验证", "近场关闭主锁", "高", executable: true),
        localBLE("ble.31", "锁状态详情", "0x31", "状态与诊断", "实车已验证", "读取主锁状态与详情", "低", executable: true),
        localBLE("ble.51", "旧骑行数据", "0x51", "归档扩展", "协议明确未验证", "读取历史骑行数据", "中"),
        localBLE("ble.52", "清除旧数据", "0x52", "归档扩展", "危险维护", "清除设备侧历史骑行数据", "危险维护"),
        localBLE("ble.60", "骑行信息", "0x60", "状态与诊断", "协议明确未验证", "读取当前骑行信息", "低"),
        localBLE("ble.61", "基础设置", "0x61", "车辆设置", "协议明确未验证", "读取或修改基础设置", "高"),
        localBLE("ble.62", "扩展设置", "0x62", "车辆设置", "协议明确未验证", "读取或修改扩展设置", "高"),
        localBLE("ble.81", "外部车轮锁", "0x81", "外部锁", "不适用", "查询或控制外部车轮锁", "危险维护")
    ]

    private static func localBLE(
        _ id: String, _ name: String, _ protocolName: String, _ group: String,
        _ status: String, _ purpose: String, _ risk: String, executable: Bool = false
    ) -> CapabilityDisplayItem {
        CapabilityDisplayItem(
            id: id, name: name, group: group, protocolName: protocolName,
            channel: "近场 BLE", purpose: purpose, risk: risk,
            supportStatus: status, enabled: false, executable: executable,
            disabledReason: executable ? "请使用车辆首页的固定近场入口" : "目录只展示，不开放执行",
            parametersSchema: "固定协议参数", persistence: "取决于设备命令",
            latestResult: nil
        )
    }

    func pair(code: String) async {
        guard normalizedBaseURL() != nil else {
            message = "请输入有效的 HTTPS 服务地址"
            return
        }
        await perform {
            let key = try RemoteCredentialVault.privateKey()
            var tokenBytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, tokenBytes.count, &tokenBytes) == errSecSuccess else {
                throw RemoteError.message("无法生成读取令牌")
            }
            let readToken = Data(tokenBytes).base64EncodedString()
            let body: [String: Any] = [
                "pairing_code": code.trimmingCharacters(in: .whitespacesAndNewlines),
                "device_name": UIDevice.current.name,
                "read_token": readToken,
                "control_public_key": key.publicKey.x963Representation.base64EncodedString()
            ]
            let response = try await self.request(
                path: "/api/v1/pairings/complete", method: "POST", body: body, authenticated: false
            )
            guard let clientID = response["client_id"] as? String else {
                throw RemoteError.message("配对响应缺少客户端编号")
            }
            try RemoteCredentialVault.saveServerURL(self.serverURL)
            try RemoteCredentialVault.savePairing(clientID: clientID, readToken: readToken)
            self.message = "配对成功"
            try await self.loadRemoteData()
        }
        await flushPendingBLEEvents()
    }

    func refresh() async {
        guard isPaired else { return }
        await perform {
            try await self.loadRemoteData()
            self.message = "远程状态已刷新"
        }
        await flushPendingBLEEvents()
    }

    func poll() async {
        guard isPaired, !isBusy else { return }
        do { try await loadOperationalData() } catch { }
        await flushPendingBLEEvents()
    }

    func enqueueBLEEvent(_ event: PendingBLEEvent) {
        do {
            pendingBLEEventCount = try pendingBLEEventStore.enqueue(event)
            message = "BLE 操作事件已保存到本机"
            Task { await flushPendingBLEEvents() }
        } catch {
            message = "BLE 操作事件保存失败，请勿卸载 App 并联系维护"
        }
    }

    func flushPendingBLEEvents() async {
        guard isPaired, !isBusy, !isFlushingBLEEvents else { return }
        isFlushingBLEEvents = true
        defer { isFlushingBLEEvents = false }
        var uploaded = 0
        var stateChanged = false
        do {
            while let event = try pendingBLEEventStore.load().first {
                let response = try await request(
                    path: "/api/v1/ble-events", method: "POST",
                    body: event.requestBody, signed: true,
                    idempotencyKey: event.id
                )
                let storedEvent = response["event"] as? [String: Any]
                stateChanged = stateChanged
                    || (storedEvent?["state_effect_applied"] as? Bool) == true
                pendingBLEEventCount = try pendingBLEEventStore.remove(event.id)
                uploaded += 1
            }
            if uploaded > 0 {
                if stateChanged { try await loadRemoteData() }
                message = "已补报 \(uploaded) 条 BLE 操作事件"
            }
        } catch {
            do {
                pendingBLEEventCount = try pendingBLEEventStore.load().count
                if pendingBLEEventCount > 0 {
                    message = "BLE 操作事件已在本机排队，网络恢复后自动补报"
                }
            } catch {
                message = "BLE 事件队列无法读取，请保留 App 数据并联系维护"
            }
        }
    }

    func syncBLELockState(isLocked: Bool, observedAt: Date) async {
        guard isPaired else { return }
        for _ in 0..<35 where isBusy {
            try? await Task.sleep(for: .seconds(1))
        }
        guard !isBusy else {
            message = "BLE 状态尚未同步，请稍后刷新或重新连接"
            return
        }
        await perform {
            let response = try await self.request(
                path: "/api/v1/ble-observations", method: "POST",
                body: [
                    "observation_id": UUID().uuidString.lowercased(),
                    "lock_state": isLocked ? "locked" : "unlocked",
                    "observed_at": Int(observedAt.timeIntervalSince1970),
                ],
                signed: true,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            let observation = response["observation"] as? [String: Any]
            try await self.loadRemoteData()
            self.message = observation?["applied"] as? Bool == false
                ? "BLE 状态已记录，服务器保留了更新的状态"
                : "BLE 锁状态已同步到服务器"
        }
    }

    func send(_ type: String, requiresOwnerPresence: Bool = false,
              parameters: [String: Any] = [:]) async {
        await perform {
            if requiresOwnerPresence {
                let reason = [
                    "vehicle.unlock": "确认远程开锁",
                    "vehicle.lock": "确认远程关锁",
                    "security.confirm_locked": "确认车辆已经完成物理关锁",
                    "security.arm": "确认手动布防",
                    "alarm.acknowledge": "确认并解除车辆告警",
                ][type] ?? "确认车辆操作"
                try await self.confirmOwnerPresence(reason: reason)
            }
            let response = try await self.request(
                path: "/api/v1/commands", method: "POST",
                body: ["type": type, "parameters": parameters], signed: requiresOwnerPresence,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            guard let commandObject = response["command"] else {
                throw RemoteError.message("远程服务响应缺少指令状态")
            }
            var command = try self.decodeCommand(commandObject)
            self.message = "指令已提交，正在等待设备结果"
            for _ in 0..<31 where !self.isTerminal(command.status) {
                try await Task.sleep(for: .seconds(1))
                let statusResponse = try await self.request(path: "/api/v1/commands/\(command.id)")
                guard let statusObject = statusResponse["command"] else {
                    throw RemoteError.message("远程服务响应缺少指令状态")
                }
                command = try self.decodeCommand(statusObject)
            }
            try await self.loadRemoteData()
            self.message = self.resultMessage(for: command)
        }
    }

    func loadTrip(_ tripID: String) async {
        guard isPaired else { return }
        await perform {
            let response = try await self.request(path: "/api/v1/trips/\(tripID)")
            guard let tripObject = response["trip"], let pointObject = response["points"] else {
                throw RemoteError.message("远程服务响应缺少骑行详情")
            }
            let decoder = JSONDecoder()
            self.selectedTrip = try decoder.decode(
                RemoteTrip.self,
                from: JSONSerialization.data(withJSONObject: tripObject)
            )
            self.selectedTripPoints = try decoder.decode(
                [RemoteLocation].self,
                from: JSONSerialization.data(withJSONObject: pointObject)
            )
        }
    }

    func setLocationHistoryDays(_ days: Int, confirmShortening: Bool) async {
        guard isPaired else { return }
        await perform {
            let response = try await self.request(
                path: "/api/v1/settings/location-history", method: "PUT",
                body: ["days": days, "confirm_shorten": confirmShortening],
                signed: true, idempotencyKey: UUID().uuidString.lowercased()
            )
            guard let settingsObject = response["settings"] else {
                throw RemoteError.message("远程服务响应缺少保留设置")
            }
            self.settings = try JSONDecoder().decode(
                RemoteSettings.self,
                from: JSONSerialization.data(withJSONObject: settingsObject)
            )
            if self.settings?.pendingLocationHistoryDays == 7 {
                self.message = "已确认改为 7 天，将在下一次清理时生效"
            } else {
                self.message = "轨迹保留期已更新为 \(days) 天"
            }
        }
    }

    func clearPairing() {
        RemoteCredentialVault.clearPairing()
        vehicle = nil
        capabilities = [:]
        commands = []
        alarms = []
        trips = []
        selectedTrip = nil
        selectedTripPoints = []
        settings = nil
        auditLogs = []
        deviceSessions = []
        latestLocation = nil
        lastLocationReport = nil
        locations = []
        lastAlertMarker = nil
        lastAlertAt = nil
        lastAlertID = nil
        message = "已清除远程配对"
        objectWillChange.send()
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadRemoteData() async throws {
        try await loadOperationalData()
        let decoder = JSONDecoder()
        do {
            let tripResponse = try await request(path: "/api/v1/trips?limit=100")
            if let tripObject = tripResponse["trips"] {
                trips = try decoder.decode(
                    [RemoteTrip].self,
                    from: JSONSerialization.data(withJSONObject: tripObject)
                )
            }
        } catch { }
        do {
            let settingsResponse = try await request(path: "/api/v1/settings")
            if let settingsObject = settingsResponse["settings"] {
                settings = try decoder.decode(
                    RemoteSettings.self,
                    from: JSONSerialization.data(withJSONObject: settingsObject)
                )
            }
        } catch { }
        do {
            let auditResponse = try await request(path: "/api/v1/audit-logs?limit=100")
            if let auditObject = auditResponse["audit_logs"] {
                auditLogs = try decoder.decode(
                    [RemoteAuditLog].self,
                    from: JSONSerialization.data(withJSONObject: auditObject)
                )
            }
        } catch { }
        do {
            let sessionResponse = try await request(path: "/api/v1/device-sessions?limit=50")
            if let sessionObject = sessionResponse["device_sessions"] {
                deviceSessions = try decoder.decode(
                    [RemoteDeviceSession].self,
                    from: JSONSerialization.data(withJSONObject: sessionObject)
                )
            }
        } catch { }
        do {
            let locationResponse = try await request(path: "/api/v1/locations?limit=500")
            latestLocation = try decodeOptionalLocation(locationResponse["latest"], decoder: decoder)
            lastLocationReport = try decodeOptionalLocation(locationResponse["last_report"], decoder: decoder)
            if let points = locationResponse["points"] {
                locations = try decoder.decode(
                    [RemoteLocation].self,
                    from: JSONSerialization.data(withJSONObject: points)
                )
            }
        } catch { }
    }

    private func loadOperationalData() async throws {
        let vehicleResponse = try await request(path: "/api/v1/vehicle")
        let capabilityResponse = try await request(path: "/api/v1/capabilities")
        let commandResponse = try await request(path: "/api/v1/commands")
        guard let vehicleObject = vehicleResponse["vehicle"],
              let capabilityObject = capabilityResponse["capabilities"],
              let commandObject = commandResponse["commands"] else {
            throw RemoteError.message("远程服务响应缺少必要字段")
        }
        let decoder = JSONDecoder()
        vehicle = try decoder.decode(
            RemoteVehicle.self,
            from: JSONSerialization.data(withJSONObject: vehicleObject)
        )
        capabilities = try decoder.decode(
            [String: RemoteCapability].self,
            from: JSONSerialization.data(withJSONObject: capabilityObject)
        )
        commands = try decoder.decode(
            [RemoteCommand].self,
            from: JSONSerialization.data(withJSONObject: commandObject)
        )
        do {
            let alarmResponse = try await request(path: "/api/v1/alarms")
            if let alarmObject = alarmResponse["alarms"] {
                let loaded = try decoder.decode(
                    [RemoteAlarm].self,
                    from: JSONSerialization.data(withJSONObject: alarmObject)
                )
                alarms = loaded
                notifyForNewestActiveAlarm(loaded)
            }
        } catch { }
    }

    private func notifyForNewestActiveAlarm(_ loaded: [RemoteAlarm]) {
        guard let alarm = loaded.first(where: { $0.state == "active" }) else { return }
        let marker = "\(alarm.id):\(alarm.lastTriggeredAt)"
        guard marker != lastAlertMarker else { return }
        lastAlertMarker = marker
        let now = Date()
        if lastAlertID == alarm.id,
           let lastAlertAt,
           now.timeIntervalSince(lastAlertAt) < 60 {
            return
        }
        lastAlertID = alarm.id
        lastAlertAt = now
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        AudioServicesPlaySystemSound(1005)
    }

    private func decodeOptionalLocation(_ object: Any?, decoder: JSONDecoder) throws -> RemoteLocation? {
        guard let object, !(object is NSNull) else { return nil }
        return try decoder.decode(
            RemoteLocation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func decodeCommand(_ object: Any) throws -> RemoteCommand {
        try JSONDecoder().decode(
            RemoteCommand.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func isTerminal(_ status: String) -> Bool {
        ["succeeded", "failed", "unknown", "noop", "rejected"].contains(status)
    }

    private func resultMessage(for command: RemoteCommand) -> String {
        switch command.status {
        case "succeeded" where command.commandType == "telemetry.refresh":
            return "设备信息已更新，IoT 已返回最新数据"
        case "succeeded" where command.commandType == "location.once" && command.result?.locationDisplayEligible == true:
            return "车辆最新位置已更新"
        case "succeeded" where command.commandType == "location.once" && command.result?.locationValid == false:
            return "设备已返回，但本次 GPS 定位无效，地图保留上次有效位置"
        case "succeeded" where command.commandType == "location.once" && command.result?.locationDisplayEligible == false:
            return "设备已返回定位，但质量检查未通过，地图保留上次可靠位置"
        case "succeeded" where command.commandType == "location.once":
            return "单次定位已完成，请打开地图查看最新位置"
        case "succeeded" where command.commandType == "vehicle.lock":
            return "IoT 已确认关锁。请确认仪表熄灭、车辆动力断开、轮毂不能转动"
        case "succeeded" where command.commandType == "security.confirm_locked":
            return "已开始 5 分钟布防等待，等待期内移动只记录不提醒"
        case "succeeded" where command.commandType == "security.arm":
            return "车辆已手动布防，机械锁状态保持独立"
        case "succeeded" where command.commandType == "alarm.acknowledge":
            return "告警已确认并解除，定位策略将按当前锁状态恢复"
        case "succeeded":
            return "设备操作成功"
        case "noop":
            return "设备已经处于目标状态，没有重复执行"
        case "rejected":
            return "设备拒绝了本次请求"
        case "failed":
            return "设备返回失败"
        case "unknown":
            return "设备未在 30 秒内返回结果，结果未知"
        default:
            return "指令仍在处理中，请稍后刷新"
        }
    }

    private func request(path: String, method: String = "GET", body: [String: Any]? = nil,
                         authenticated: Bool = true, signed: Bool = false,
                         idempotencyKey: String? = nil) async throws -> [String: Any] {
        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let baseURL = normalizedBaseURL(), let url = URL(string: relativePath, relativeTo: baseURL) else {
            throw RemoteError.message("远程服务地址无效")
        }
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData.isEmpty ? nil : bodyData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if authenticated {
            guard let clientID = RemoteCredentialVault.clientID,
                  let readToken = RemoteCredentialVault.readToken else {
                throw RemoteError.message("尚未完成远程配对")
            }
            request.setValue(clientID, forHTTPHeaderField: "X-Client-Id")
            request.setValue("Bearer \(readToken)", forHTTPHeaderField: "Authorization")
            if signed {
                let timestamp = String(Int(Date().timeIntervalSince1970))
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                let digest = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()
                let canonical = [method, path, url.query ?? "", timestamp, nonce, digest].joined(separator: "\n")
                let signature = try RemoteCredentialVault.privateKey().signature(for: Data(canonical.utf8))
                request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
                request.setValue(nonce, forHTTPHeaderField: "X-Nonce")
                request.setValue(digest, forHTTPHeaderField: "X-Body-SHA256")
                request.setValue(signature.rawRepresentation.base64EncodedString(), forHTTPHeaderField: "X-Signature")
            }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteError.message("远程服务没有返回 HTTP 响应")
        }
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw RemoteError.message("远程服务响应格式错误")
        }
        guard 200..<300 ~= http.statusCode else {
            let error = object["error"] as? [String: Any]
            throw RemoteError.message(error?["message"] as? String ?? "远程请求失败（\(http.statusCode)）")
        }
        return object
    }

    private func normalizedBaseURL() -> URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme == "https",
              components.host != nil else { return nil }
        if !components.path.hasSuffix("/") { components.path += "/" }
        return components.url
    }

    private func confirmOwnerPresence(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? RemoteError.message("设备身份验证不可用")
        }
        let accepted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        if !accepted { throw RemoteError.message("未通过设备身份验证") }
    }
}

private enum RemoteError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

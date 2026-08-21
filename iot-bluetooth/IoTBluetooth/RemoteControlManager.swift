import CryptoKit
import Foundation
import LocalAuthentication
import Security
import UIKit

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

    enum CodingKeys: String, CodingKey {
        case enabled, reason
        case cooldownSeconds = "cooldown_seconds"
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

    enum CodingKeys: String, CodingKey {
        case id, source, valid, latitude, longitude, satellites, hdop, mode
        case displayEligible = "display_eligible"
        case rejectionReason = "rejection_reason"
        case deviceTimestamp = "device_timestamp"
        case receivedAt = "received_at"
        case altitudeM = "altitude_m"
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
    @Published private(set) var latestLocation: RemoteLocation?
    @Published private(set) var lastLocationReport: RemoteLocation?
    @Published private(set) var locations: [RemoteLocation] = []
    @Published private(set) var isBusy = false
    @Published private(set) var message = ""

    var isPaired: Bool {
        RemoteCredentialVault.clientID != nil && RemoteCredentialVault.readToken != nil
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
    }

    func refresh() async {
        guard isPaired else { return }
        await perform {
            try await self.loadRemoteData()
            self.message = "远程状态已刷新"
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
                try await self.confirmOwnerPresence(reason: type == "vehicle.unlock" ? "确认远程开锁" : "确认远程关锁")
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

    func clearPairing() {
        RemoteCredentialVault.clearPairing()
        vehicle = nil
        capabilities = [:]
        commands = []
        latestLocation = nil
        lastLocationReport = nil
        locations = []
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

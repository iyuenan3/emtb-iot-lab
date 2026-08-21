import Foundation
import Security

enum KeychainStore {
    private static let service = "org.emtb.iot-lab"
    private static let legacyServices = ["com.maxwell.iot-bluetooth"]

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert.merge(update) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else if updateStatus != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }
    }

    static func read(account: String) -> String? {
        if let value = read(account: account, service: service) {
            return value
        }
        for legacyService in legacyServices {
            guard let value = read(account: account, service: legacyService) else { continue }
            do {
                try save(value, account: account)
                delete(account: account, service: legacyService)
            } catch {
                return value
            }
            return value
        }
        return nil
    }

    static func delete(account: String) {
        delete(account: account, service: service)
        legacyServices.forEach { delete(account: account, service: $0) }
    }

    private static func read(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum DeviceKeyVault {
    private static let legacyAccount = "device-key"
    private static let activeAccount = "device-key.\(IoTDeviceProfile.imei).active"
    private static let obsoleteAccounts = [
        "device-key.\(IoTDeviceProfile.imei).pending",
        "device-key.\(IoTDeviceProfile.imei).recovery"
    ]

    static func migrateLegacyKeyIfNeeded() throws {
        if read() == nil, let legacyKey = KeychainStore.read(account: legacyAccount) {
            try save(legacyKey)
            KeychainStore.delete(account: legacyAccount)
        }
        obsoleteAccounts.forEach { KeychainStore.delete(account: $0) }
    }

    static func read() -> String? {
        KeychainStore.read(account: activeAccount)
    }

    static var containsKey: Bool {
        read() != nil
    }

    static func save(_ key: String) throws {
        try KeychainStore.save(key, account: activeAccount)
    }

    static func delete() {
        KeychainStore.delete(account: activeAccount)
        KeychainStore.delete(account: legacyAccount)
        obsoleteAccounts.forEach { KeychainStore.delete(account: $0) }
    }
}

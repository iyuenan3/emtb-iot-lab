import Foundation

struct PendingBLEEvent: Codable, Equatable, Identifiable {
    let id: String
    let action: String
    let bleResult: String
    let readbackLockState: String
    let deviceOperationAt: Int

    enum CodingKeys: String, CodingKey {
        case id = "event_id"
        case action
        case bleResult = "ble_result"
        case readbackLockState = "readback_lock_state"
        case deviceOperationAt = "device_operation_at"
    }

    init(action: String, readbackLockState: String, deviceOperationAt: Int) {
        id = UUID().uuidString.lowercased()
        self.action = action
        bleResult = "succeeded"
        self.readbackLockState = readbackLockState
        self.deviceOperationAt = deviceOperationAt
    }

    var requestBody: [String: Any] {
        [
            "event_id": id,
            "action": action,
            "ble_result": bleResult,
            "readback_lock_state": readbackLockState,
            "device_operation_at": deviceOperationAt,
        ]
    }
}

struct PendingBLEEventStore {
    private let defaults: UserDefaults
    private let key = "pending-ble-events.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> [PendingBLEEvent] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([PendingBLEEvent].self, from: data)
    }

    @discardableResult
    func enqueue(_ event: PendingBLEEvent) throws -> Int {
        var events = try load()
        if !events.contains(where: { $0.id == event.id }) {
            events.append(event)
            try save(events)
        }
        return events.count
    }

    @discardableResult
    func remove(_ eventID: String) throws -> Int {
        var events = try load()
        events.removeAll { $0.id == eventID }
        try save(events)
        return events.count
    }

    private func save(_ events: [PendingBLEEvent]) throws {
        defaults.set(try JSONEncoder().encode(events), forKey: key)
    }
}

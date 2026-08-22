import SwiftUI

@main
struct IoTBluetoothApp: App {
    @StateObject private var device = BLEDeviceManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(device)
        }
    }
}

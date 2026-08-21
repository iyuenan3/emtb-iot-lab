import SwiftUI

@main
struct IoTBluetoothApp: App {
    @StateObject private var device = BLEDeviceManager()
    @StateObject private var remote = RemoteControlManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(device)
                .environmentObject(remote)
        }
    }
}

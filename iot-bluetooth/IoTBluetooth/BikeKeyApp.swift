import SwiftUI

@main
struct BikeKeyApp: App {
    @StateObject private var controller = BluetoothKeyController()

    var body: some Scene {
        WindowGroup {
            BikeKeyView()
                .environmentObject(controller)
        }
    }
}

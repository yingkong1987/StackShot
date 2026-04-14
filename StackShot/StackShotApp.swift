import SwiftUI

@main
struct StackShotApp: App {
    @State private var didSetup = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    guard !didSetup else { return }
                    didSetup = true
                    MenuBarController.shared.setup()
                    HotkeyManager.shared.start()
                }
        }
        .defaultSize(width: 420, height: 260)
        .windowResizability(.contentSize)
    }
}

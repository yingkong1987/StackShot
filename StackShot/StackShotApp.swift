import SwiftUI

@main
struct StackShotApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    HotkeyManager.shared.start()
                }
        }
    }
}

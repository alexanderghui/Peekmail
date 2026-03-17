import SwiftUI

@main
struct PeekmailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scenes — window is managed by AppDelegate
        Settings {
            EmptyView()
        }
    }
}

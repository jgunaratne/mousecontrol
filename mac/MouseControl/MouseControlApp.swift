import SwiftUI

/// MouseControl entry point — a macOS app with a floating prompt window and menu bar icon.
@main
struct MouseControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // The app's main window is managed by AppDelegate via NSWindow.
        // Use Settings as a placeholder scene (SwiftUI requires at least one).
        Settings {
            EmptyView()
        }
    }
}

import Cocoa

/// Connection states for the status bar UI.
enum ConnectionState: String {
    case cableNotDetected = "USB-C cable not detected"
    case waitingForCompanion = "Waiting for companion…"
    case connected = "Connected to companion"
    case running = "AI task running…"
}

/// Manages the menu bar status item, icon, and dropdown menu.
class StatusBarController {
    
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var statusMenuItem: NSMenuItem?
    
    private(set) var currentState: ConnectionState = .cableNotDetected
    
    /// Set up the status bar item and menu.
    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        menu = NSMenu()
        
        // Status line
        statusMenuItem = NSMenuItem(title: currentState.rawValue, action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        menu?.addItem(statusMenuItem!)
        
        menu?.addItem(NSMenuItem.separator())
        
        // IP address reference
        let ipItem = NSMenuItem(title: "Mac USB IP: 192.168.100.1", action: nil, keyEquivalent: "")
        ipItem.isEnabled = false
        menu?.addItem(ipItem)
        
        let portItem = NSMenuItem(title: "Port: 9877", action: nil, keyEquivalent: "")
        portItem.isEnabled = false
        menu?.addItem(portItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit MouseControl", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu?.addItem(quitItem)
        
        statusItem?.menu = menu
        
        updateState(.cableNotDetected)
    }
    
    /// Update the connection state, icon, and status text.
    func updateState(_ state: ConnectionState) {
        currentState = state
        statusMenuItem?.title = state.rawValue
        
        let symbolName: String
        switch state {
        case .cableNotDetected:
            symbolName = "brain"
        case .waitingForCompanion:
            symbolName = "brain.fill"
        case .connected:
            symbolName = "brain.head.profile.fill"
        case .running:
            symbolName = "brain.head.profile"
        }
        
        if let button = statusItem?.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MouseControl")?
                .withSymbolConfiguration(config)
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

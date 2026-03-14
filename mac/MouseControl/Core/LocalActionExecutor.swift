import Cocoa
import CoreGraphics

/// Executes AI actions locally on the Mac using CGEvent and other macOS APIs.
/// This is the local equivalent of what the companion apps do on Windows/Linux.
class LocalActionExecutor {
    
    // MARK: - Screenshot
    
    /// Capture the entire main screen and return base64-encoded PNG data + dimensions.
    func captureScreenshot() -> (base64: String, width: Int, height: Int)? {
        guard let displayID = CGMainDisplayID() as CGDirectDisplayID?,
              let screenshot = CGDisplayCreateImage(displayID) else {
            print("❌ [Local] Failed to capture screenshot")
            return nil
        }
        
        let width = screenshot.width
        let height = screenshot.height
        
        let bitmapRep = NSBitmapImageRep(cgImage: screenshot)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            print("❌ [Local] Failed to convert screenshot to PNG")
            return nil
        }
        
        let base64 = pngData.base64EncodedString()
        return (base64: base64, width: width, height: height)
    }
    
    // MARK: - Action Execution
    
    /// Execute a ControlMessage action locally on the Mac.
    func execute(_ action: ControlMessage, completion: @escaping (Bool, String?) -> Void) {
        guard let actionType = action.action else {
            completion(false, "No action type specified")
            return
        }
        
        switch actionType {
        case .click:
            executeClick(action, completion: completion)
        case .mouseMove:
            executeMouseMove(action, completion: completion)
        case .type:
            executeType(action, completion: completion)
        case .keyCombo:
            executeKeyCombo(action, completion: completion)
        case .scroll:
            executeScroll(action, completion: completion)
        case .wait:
            // Handled by the agent loop
            completion(true, nil)
        case .done:
            completion(true, nil)
        }
    }
    
    // MARK: - Click
    
    private func executeClick(_ action: ControlMessage, completion: @escaping (Bool, String?) -> Void) {
        guard let nx = action.normalizedX, let ny = action.normalizedY else {
            completion(false, "Missing coordinates")
            return
        }
        
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let x = CGFloat(nx) * screenSize.width
        let y = CGFloat(ny) * screenSize.height
        let point = CGPoint(x: x, y: y)
        let clickCount = action.clickCount ?? 1
        
        let isRight = action.button == .right
        let downType: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = isRight ? .rightMouseUp : .leftMouseUp
        let mouseButton: CGMouseButton = isRight ? .right : .left
        
        for i in 1...clickCount {
            if let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton) {
                downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                downEvent.post(tap: .cghidEventTap)
            }
            if let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton) {
                upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                upEvent.post(tap: .cghidEventTap)
            }
        }
        
        completion(true, nil)
    }
    
    // MARK: - Mouse Move
    
    private func executeMouseMove(_ action: ControlMessage, completion: @escaping (Bool, String?) -> Void) {
        guard let nx = action.normalizedX, let ny = action.normalizedY else {
            completion(false, "Missing coordinates")
            return
        }
        
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let x = CGFloat(nx) * screenSize.width
        let y = CGFloat(ny) * screenSize.height
        let point = CGPoint(x: x, y: y)
        
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }
        
        completion(true, nil)
    }
    
    // MARK: - Type Text
    
    private func executeType(_ action: ControlMessage, completion: @escaping (Bool, String?) -> Void) {
        guard let text = action.text, !text.isEmpty else {
            completion(false, "No text to type")
            return
        }
        
        for char in text {
            let str = String(char)
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                var chars = Array(str.utf16)
                event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
                event.post(tap: .cghidEventTap)
            }
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                event.post(tap: .cghidEventTap)
            }
            usleep(20_000) // 20ms between keystrokes
        }
        
        completion(true, nil)
    }
    
    // MARK: - Key Combo
    
    private func executeKeyCombo(_ action: ControlMessage, completion: @escaping (Bool, String?) -> Void) {
        guard let keys = action.keys, !keys.isEmpty else {
            completion(false, "No keys specified")
            return
        }
        
        // Build modifier flags and find the main key
        var flags: CGEventFlags = []
        var mainKeyCode: CGKeyCode = 0
        var hasMainKey = false
        
        for key in keys {
            switch key.lowercased() {
            case "cmd", "command", "meta", "super":
                flags.insert(.maskCommand)
            case "ctrl", "control":
                flags.insert(.maskControl)
            case "alt", "option", "opt":
                flags.insert(.maskAlternate)
            case "shift":
                flags.insert(.maskShift)
            default:
                // Map common key names to keycodes
                if let code = keyNameToCode(key) {
                    mainKeyCode = code
                    hasMainKey = true
                }
            }
        }
        
        if hasMainKey {
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: mainKeyCode, keyDown: true) {
                down.flags = flags
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: mainKeyCode, keyDown: false) {
                up.flags = flags
                up.post(tap: .cghidEventTap)
            }
        }
        
        completion(true, nil)
    }
    
    // MARK: - Scroll
    
    private func executeScroll(_ action: ControlMessage, completion: @escaping (Bool, String?) -> Void) {
        let dx = Int32(action.scrollDeltaX ?? 0)
        let dy = Int32(action.scrollDeltaY ?? 0)
        
        if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
            scrollEvent.post(tap: .cghidEventTap)
        }
        
        completion(true, nil)
    }
    
    // MARK: - Helpers
    
    /// Map common key names to macOS virtual key codes.
    private func keyNameToCode(_ name: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "space": 49, "tab": 48, "return": 36, "enter": 36,
            "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "up": 126, "down": 125, "left": 123, "right": 124,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
            "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
            "f11": 103, "f12": 111,
        ]
        return map[name.lowercased()]
    }
}

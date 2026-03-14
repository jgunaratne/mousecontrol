import Foundation

// MARK: - Control Target

/// Whether MouseControl targets the remote PC or local Mac.
enum ControlTarget {
    case pc
    case mac
}

// MARK: - Message Types

/// Top-level message types exchanged between Mac and PC companion.
enum ControlMessageType: String, Codable {
    case requestScreenshot
    case screenshotData
    case executeAction
    case actionResult
    case heartbeat
}

// MARK: - Action Types

/// Discrete actions the AI can command on the PC.
enum ActionType: String, Codable {
    case mouseMove
    case click
    case drag
    case type
    case keyCombo
    case scroll
    case wait
    case done
}

/// Mouse button for click actions.
enum MouseButton: String, Codable {
    case left, right, middle
}

// MARK: - Control Message

/// A single message exchanged between Mac and companion PC.
/// Uses the same 4-byte big-endian length-prefixed JSON framing as MouseShare.
struct ControlMessage: Codable {
    let type: ControlMessageType
    
    // ── Screenshot data (PC → Mac) ─────────────────────────────────────
    
    /// Base64-encoded PNG screenshot data.
    let imageBase64: String?
    
    /// Screenshot dimensions.
    let width: Int?
    let height: Int?
    
    // ── Action fields (Mac → PC) ────────────────────────────────────────
    
    /// The action to execute on the PC.
    let action: ActionType?
    
    /// Normalized X position (0–1, left to right).
    let normalizedX: Double?
    
    /// Normalized Y position (0–1, top to bottom).
    let normalizedY: Double?
    
    /// Mouse button for click actions.
    let button: MouseButton?
    
    /// Click count (1 = single, 2 = double).
    let clickCount: Int?
    
    /// Text to type.
    let text: String?
    
    /// Key names for keyCombo (e.g., ["ctrl", "c"]).
    let keys: [String]?
    
    /// Scroll deltas.
    let scrollDeltaX: Double?
    let scrollDeltaY: Double?
    
    /// Wait duration in seconds.
    let seconds: Double?
    
    /// Summary message when action is "done".
    let summary: String?
    
    // ── Drag fields (Mac → PC) ──────────────────────────────────────────
    
    /// Normalized start X for drag (0–1).
    let startX: Double?
    
    /// Normalized start Y for drag (0–1).
    let startY: Double?
    
    /// Normalized end X for drag (0–1).
    let endX: Double?
    
    /// Normalized end Y for drag (0–1).
    let endY: Double?
    
    // ── Action result (PC → Mac) ────────────────────────────────────────
    
    /// Whether the action succeeded.
    let success: Bool?
    
    /// Error message if the action failed.
    let error: String?
    
    // MARK: - Convenience Initializers
    
    /// Create a heartbeat message.
    static func heartbeat() -> ControlMessage {
        ControlMessage(type: .heartbeat)
    }
    
    /// Create a screenshot request.
    static func requestScreenshot() -> ControlMessage {
        ControlMessage(type: .requestScreenshot)
    }
    
    /// Create an execute action message.
    static func executeAction(
        action: ActionType,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        button: MouseButton? = nil,
        clickCount: Int? = nil,
        text: String? = nil,
        keys: [String]? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil,
        seconds: Double? = nil,
        summary: String? = nil,
        startX: Double? = nil,
        startY: Double? = nil,
        endX: Double? = nil,
        endY: Double? = nil
    ) -> ControlMessage {
        ControlMessage(
            type: .executeAction,
            imageBase64: nil,
            width: nil,
            height: nil,
            action: action,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            button: button,
            clickCount: clickCount,
            text: text,
            keys: keys,
            scrollDeltaX: scrollDeltaX,
            scrollDeltaY: scrollDeltaY,
            seconds: seconds,
            summary: summary,
            startX: startX,
            startY: startY,
            endX: endX,
            endY: endY,
            success: nil,
            error: nil
        )
    }
    
    /// Memberwise init with all fields optional except type.
    init(
        type: ControlMessageType,
        imageBase64: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        action: ActionType? = nil,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        button: MouseButton? = nil,
        clickCount: Int? = nil,
        text: String? = nil,
        keys: [String]? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil,
        seconds: Double? = nil,
        summary: String? = nil,
        startX: Double? = nil,
        startY: Double? = nil,
        endX: Double? = nil,
        endY: Double? = nil,
        success: Bool? = nil,
        error: String? = nil
    ) {
        self.type = type
        self.imageBase64 = imageBase64
        self.width = width
        self.height = height
        self.action = action
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.button = button
        self.clickCount = clickCount
        self.text = text
        self.keys = keys
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.seconds = seconds
        self.summary = summary
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
        self.success = success
        self.error = error
    }
}

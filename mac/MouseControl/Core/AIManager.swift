import Foundation

/// Manages communication with the Google Gemini API for vision-based screen analysis.
/// Sends screenshots + prompts and receives structured JSON actions.
class AIManager {
    
    /// The Gemini API key — loaded from UserDefaults or environment.
    var apiKey: String {
        get {
            UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "geminiAPIKey")
        }
    }
    
    /// Whether the API key is configured.
    var isConfigured: Bool {
        !apiKey.isEmpty
    }
    
    /// The Gemini model to use.
    private let model = "gemini-2.0-flash"
    
    /// Conversation history for multi-step tasks.
    private var conversationHistory: [[String: Any]] = []
    
    /// System prompt that instructs Gemini how to analyze screens and return actions.
    private let systemPrompt = """
    You are an AI agent that controls a remote computer by analyzing screenshots and issuing precise mouse/keyboard actions.
    
    You will receive:
    1. A user's task description
    2. A screenshot of the current state of the PC's screen
    
    You must return EXACTLY ONE action as a JSON object. Available actions:
    
    {"action": "mouseMove", "normalizedX": 0.5, "normalizedY": 0.3}
    - Move mouse to position. X: 0=left, 1=right. Y: 0=top, 1=bottom.
    
    {"action": "click", "normalizedX": 0.5, "normalizedY": 0.3, "button": "left", "count": 1}
    - Click at position. button: "left", "right", or "middle". count: 1 or 2 (double-click).
    
    {"action": "type", "text": "hello world"}
    - Type text. Use this for entering text in fields.
    
    {"action": "keyCombo", "keys": ["ctrl", "c"]}
    - Press a key combination. Key names: ctrl, alt, shift, super, enter, tab, escape, backspace, delete, up, down, left, right, home, end, pageup, pagedown, f1-f12, space, plus any single character.
    
    {"action": "scroll", "deltaX": 0, "deltaY": -3}
    - Scroll. Positive deltaY = scroll up, negative = scroll down.
    
    {"action": "wait", "seconds": 1.0}
    - Wait for something to load or animate.
    
    {"action": "done", "summary": "Completed the task successfully"}
    - The task is complete. Provide a brief summary of what was accomplished.
    
    RULES:
    - Return ONLY the JSON object, no markdown, no explanation, no code fences.
    - Return exactly ONE action per response.
    - Be precise with coordinates — look carefully at the screenshot.
    - For clicking UI elements, aim for their center.
    - If you need to click a specific button or link, identify its position precisely.
    - If the task requires multiple steps, return the NEXT single step. You will get a new screenshot after each action.
    - If something went wrong or the screen doesn't look right, try a different approach.
    - If you cannot complete the task, return: {"action": "done", "summary": "Could not complete: <reason>"}
    """
    
    // MARK: - Public API
    
    /// Start a new task — clears conversation history.
    func startNewTask() {
        conversationHistory = []
    }
    
    /// Analyze a screenshot and determine the next action.
    /// - Parameters:
    ///   - prompt: The user's task description
    ///   - screenshotBase64: Base64-encoded PNG of the current screen
    ///   - completion: Called with the parsed action or an error
    func analyzeScreenshot(
        prompt: String,
        screenshotBase64: String,
        completion: @escaping (Result<ControlMessage, Error>) -> Void
    ) {
        guard isConfigured else {
            completion(.failure(AIError.noAPIKey))
            return
        }
        
        // Build the request
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        
        // Build contents array with conversation history + current turn
        var contents: [[String: Any]] = []
        
        // Add conversation history
        contents.append(contentsOf: conversationHistory)
        
        // Build current user turn
        var parts: [[String: Any]] = []
        
        // Add the user prompt (only on first turn, subsequent turns get
        // "Here is the updated screenshot after the previous action")
        if conversationHistory.isEmpty {
            parts.append(["text": "Task: \(prompt)\n\nHere is the current screenshot of the PC screen. Analyze it and return the next action as JSON."])
        } else {
            parts.append(["text": "Here is the updated screenshot after the previous action. Continue with the next step to complete the task. Return the next action as JSON."])
        }
        
        // Add the screenshot as inline_data
        parts.append([
            "inline_data": [
                "mime_type": "image/png",
                "data": screenshotBase64
            ]
        ])
        
        contents.append([
            "role": "user",
            "parts": parts
        ])
        
        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": contents,
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 500,
                "responseMimeType": "application/json"
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }
        
        // Send the request
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(AIError.noResponse))
                return
            }
            
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(AIError.invalidResponse))
                    return
                }
                
                // Check for API errors
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    completion(.failure(AIError.apiError(message)))
                    return
                }
                
                // Extract the response text
                guard let candidates = json["candidates"] as? [[String: Any]],
                      let firstCandidate = candidates.first,
                      let content = firstCandidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let firstPart = parts.first,
                      let text = firstPart["text"] as? String else {
                    completion(.failure(AIError.invalidResponse))
                    return
                }
                
                // Parse the action JSON
                let action = try self?.parseAction(text)
                
                // Update conversation history
                self?.conversationHistory.append(contentsOf: contents.suffix(1))  // user turn
                self?.conversationHistory.append([
                    "role": "model",
                    "parts": [["text": text]]
                ])
                
                // Keep history manageable (last 10 turns = 20 entries)
                if let count = self?.conversationHistory.count, count > 20 {
                    self?.conversationHistory = Array(self?.conversationHistory.suffix(20) ?? [])
                }
                
                if let action = action {
                    completion(.success(action))
                } else {
                    completion(.failure(AIError.invalidAction))
                }
                
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    // MARK: - Action Parsing
    
    private func parseAction(_ jsonString: String) throws -> ControlMessage {
        // Clean up the response — remove markdown fences if present
        var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            // Remove code fences
            let lines = cleaned.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.hasPrefix("```") }
            cleaned = filtered.joined(separator: "\n")
        }
        
        guard let data = cleaned.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actionStr = dict["action"] as? String,
              let actionType = ActionType(rawValue: actionStr) else {
            throw AIError.invalidAction
        }
        
        return ControlMessage.executeAction(
            action: actionType,
            normalizedX: dict["normalizedX"] as? Double,
            normalizedY: dict["normalizedY"] as? Double,
            button: (dict["button"] as? String).flatMap { MouseButton(rawValue: $0) },
            clickCount: dict["count"] as? Int,
            text: dict["text"] as? String,
            keys: dict["keys"] as? [String],
            scrollDeltaX: dict["deltaX"] as? Double,
            scrollDeltaY: dict["deltaY"] as? Double,
            seconds: dict["seconds"] as? Double,
            summary: dict["summary"] as? String
        )
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case noAPIKey
    case noResponse
    case invalidResponse
    case invalidAction
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "Gemini API key not configured. Set it in the app settings or GEMINI_API_KEY environment variable."
        case .noResponse:
            return "No response received from Gemini API."
        case .invalidResponse:
            return "Could not parse Gemini API response."
        case .invalidAction:
            return "AI returned an invalid or unparseable action."
        case .apiError(let message):
            return "Gemini API error: \(message)"
        }
    }
}

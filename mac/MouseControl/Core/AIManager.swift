import Foundation

/// Manages communication with Gemini 3.1 Pro Preview via Vertex AI for vision-based screen analysis.
/// Sends screenshots + prompts and receives structured JSON actions.
///
/// Authentication: uses `gcloud auth print-access-token` (ADC) — ensure you have
/// run `gcloud auth application-default login` on the Mac.
class AIManager {
    
    /// Google Cloud project ID — loaded from UserDefaults, ~/.mousecontrol.env, or environment.
    var projectID: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: "gcpProjectID"), !saved.isEmpty {
                return saved
            }
            if let envVar = ProcessInfo.processInfo.environment["GCP_PROJECT_ID"], !envVar.isEmpty {
                return envVar
            }
            // Try reading from ~/.mousecontrol.env
            return Self.readEnvFile(key: "GCP_PROJECT_ID") ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "gcpProjectID")
        }
    }
    
    /// Read a key from ~/.mousecontrol.env (simple KEY=VALUE format).
    private static func readEnvFile(key: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let envPath = home.appendingPathComponent(".mousecontrol.env")
        guard let contents = try? String(contentsOf: envPath, encoding: .utf8) else { return nil }
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
    
    /// Whether the project is configured.
    var isConfigured: Bool {
        !projectID.isEmpty
    }
    
    /// The Gemini model to use — 3.1 Pro Preview via Vertex AI.
    private let model = "gemini-3.1-pro-preview"
    
    /// Preview models require the 'global' location.
    private let location = "global"
    
    /// Conversation history for multi-step tasks.
    private var conversationHistory: [[String: Any]] = []
    
    /// Cached access token and its expiry.
    private var cachedAccessToken: String?
    private var tokenExpiry: Date = .distantPast
    
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
    
    // MARK: - Access Token
    
    /// Get a fresh Google Cloud access token using `gcloud auth print-access-token`.
    private func getAccessToken() throws -> String {
        // Return cached token if still valid (with 60s buffer)
        if let token = cachedAccessToken, tokenExpiry > Date().addingTimeInterval(60) {
            return token
        }
        
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gcloud", "auth", "print-access-token"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw AIError.authError("gcloud auth print-access-token failed. Run: gcloud auth application-default login")
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        guard !token.isEmpty else {
            throw AIError.authError("Empty access token. Run: gcloud auth application-default login")
        }
        
        cachedAccessToken = token
        tokenExpiry = Date().addingTimeInterval(3500) // tokens last ~1h, refresh at 58min
        return token
    }
    
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
            completion(.failure(AIError.noProjectID))
            return
        }
        
        // Get access token (may run gcloud CLI)
        let accessToken: String
        do {
            accessToken = try getAccessToken()
        } catch {
            completion(.failure(error))
            return
        }
        
        // Vertex AI endpoint — preview models use 'global' region
        let urlString = "https://\(location)-aiplatform.googleapis.com/v1beta1/projects/\(projectID)/locations/\(location)/publishers/google/models/\(model):generateContent"
        
        guard let url = URL(string: urlString) else {
            completion(.failure(AIError.invalidResponse))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120  // 3.1 Pro may take longer
        
        // Build contents array with conversation history + current turn
        var contents: [[String: Any]] = []
        
        // Add conversation history
        contents.append(contentsOf: conversationHistory)
        
        // Build current user turn
        var parts: [[String: Any]] = []
        
        if conversationHistory.isEmpty {
            parts.append(["text": "Task: \(prompt)\n\nHere is the current screenshot of the PC screen. Analyze it and return the next action as JSON."])
        } else {
            parts.append(["text": "Here is the updated screenshot after the previous action. Continue with the next step to complete the task. Return the next action as JSON."])
        }
        
        // Add the screenshot as inline_data
        parts.append([
            "inlineData": [
                "mimeType": "image/png",
                "data": screenshotBase64
            ]
        ])
        
        contents.append([
            "role": "user",
            "parts": parts
        ])
        
        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": contents,
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 500
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
            
            // Check HTTP status
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                // Token expired — clear cache and retry
                self?.cachedAccessToken = nil
                self?.tokenExpiry = .distantPast
                completion(.failure(AIError.authError("Access token expired. Will retry on next call.")))
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
    
    /// Extract the first complete JSON object from a string using bracket counting.
    private func extractFirstJSON(_ str: String) -> String? {
        var depth = 0
        var start = -1
        for (i, char) in str.enumerated() {
            if char == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 && start >= 0 {
                    let startIdx = str.index(str.startIndex, offsetBy: start)
                    let endIdx = str.index(str.startIndex, offsetBy: i + 1)
                    return String(str[startIdx..<endIdx])
                }
            }
        }
        return nil
    }
    
    private func parseAction(_ jsonString: String) throws -> ControlMessage {
        // Clean up the response — remove markdown fences if present
        var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            let lines = cleaned.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.hasPrefix("```") }
            cleaned = filtered.joined(separator: "\n")
        }
        
        // Use bracket counting to extract the first JSON object (robust against extra text)
        guard let jsonStr = extractFirstJSON(cleaned),
              let data = jsonStr.data(using: .utf8),
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
    case noProjectID
    case noResponse
    case invalidResponse
    case invalidAction
    case apiError(String)
    case authError(String)
    
    var errorDescription: String? {
        switch self {
        case .noProjectID:
            return "GCP Project ID not configured. Set it in the app or GCP_PROJECT_ID environment variable."
        case .noResponse:
            return "No response received from Vertex AI."
        case .invalidResponse:
            return "Could not parse Vertex AI response."
        case .invalidAction:
            return "AI returned an invalid or unparseable action."
        case .apiError(let message):
            return "Vertex AI error: \(message)"
        case .authError(let message):
            return "Auth error: \(message)"
        }
    }
}

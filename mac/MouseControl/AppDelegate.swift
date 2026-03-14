import Cocoa
import SwiftUI

/// Main application delegate — wires together TCPManager, AIManager, and the prompt UI.
/// Orchestrates the AI agent loop: screenshot → AI → action → repeat.
class AppDelegate: NSObject, NSApplicationDelegate {
    
    // MARK: - Components
    
    private let tcpManager = TCPManager()
    private let aiManager = AIManager()
    private let statusBar = StatusBarController()
    private let localExecutor = LocalActionExecutor()
    
    /// Current control target (PC or Mac).
    private var controlTarget: ControlTarget = .pc
    
    /// The prompt view model — shared with the SwiftUI view.
    private let viewModel = PromptViewModel()
    
    /// The prompt window.
    private var promptWindow: NSWindow?
    
    /// Timer to check for USB-C network interface presence.
    private var interfaceCheckTimer: Timer?
    
    /// Whether the USB-C cable/interface has been detected.
    private var cableDetected = false
    
    /// Number of consecutive interface checks that failed.
    private var missedInterfaceChecks = 0
    
    /// Whether the AI agent loop is currently running.
    private var isTaskRunning = false
    
    /// Flag to cancel the current task.
    private var shouldCancelTask = false
    
    /// Maximum number of steps before auto-stopping (safety limit).
    private let maxSteps = 50
    
    // MARK: - App Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Set up the prompt view model callbacks
        viewModel.isProjectConfigured = aiManager.isConfigured
        viewModel.onStartTask = { [weak self] prompt in
            self?.startAITask(prompt: prompt)
        }
        viewModel.onStopTask = { [weak self] in
            self?.stopAITask()
        }
        viewModel.onModelChanged = { [weak self] newModel in
            self?.aiManager.model = newModel
            print("🔵 [MouseControl] Model changed to: \(newModel)")
        }
        viewModel.onTargetChanged = { [weak self] target in
            self?.controlTarget = target
            print("🔵 [MouseControl] Control target changed to: \(target == .mac ? "Mac" : "PC")")
        }
        
        // 2. Set up the status bar
        statusBar.setup()
        
        // 3. Set up TCP manager
        tcpManager.delegate = self
        tcpManager.startListening()
        
        // 4. Create and show the prompt window
        createPromptWindow()
        
        // 5. Start periodic USB-C interface check
        interfaceCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkUSBInterface()
        }
        checkUSBInterface()
        
        print("🖱 [MouseControl] App launched and ready.")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        stopAITask()
        tcpManager.stopListening()
        interfaceCheckTimer?.invalidate()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        promptWindow?.makeKeyAndOrderFront(nil)
        return true
    }
    
    // MARK: - Window Setup
    
    private func createPromptWindow() {
        let promptView = PromptView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: promptView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "MouseControl"
        window.setContentSize(NSSize(width: 520, height: 400))
        window.minSize = NSSize(width: 420, height: 300)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        
        promptWindow = window
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - AI Agent Loop
    
    private func startAITask(prompt: String) {
        guard !isTaskRunning else { return }
        // Check configuration
        guard aiManager.isConfigured else {
            viewModel.statusMessage = "Please configure GCP Project ID first"
            viewModel.isError = true
            return
        }
        
        // For PC mode, require a TCP connection
        if controlTarget == .pc && !tcpManager.isConnected {
            viewModel.statusMessage = "Not connected to companion PC"
            viewModel.isError = true
            return
        }
        
        isTaskRunning = true
        shouldCancelTask = false
        viewModel.isRunning = true
        viewModel.isError = false
        viewModel.actionLog = []
        viewModel.stepCount = 0
        viewModel.latestScreenshot = nil
        viewModel.statusMessage = "Starting task…"
        
        statusBar.updateState(.running)
        aiManager.startNewTask()
        
        viewModel.addLogEntry("Task started: \"\(prompt)\"")
        
        // Begin the agent loop
        agentLoop(prompt: prompt)
    }
    
    private func stopAITask() {
        shouldCancelTask = true
        isTaskRunning = false
        viewModel.isRunning = false
        viewModel.statusMessage = "Task cancelled"
        viewModel.addLogEntry("Task cancelled by user")
        
        if tcpManager.isConnected {
            statusBar.updateState(.connected)
        } else if cableDetected {
            statusBar.updateState(.waitingForCompanion)
        } else {
            statusBar.updateState(.cableNotDetected)
        }
    }
    
    /// The main agent loop: screenshot → AI → action → repeat.
    private func agentLoop(prompt: String) {
        guard isTaskRunning, !shouldCancelTask else { return }
        guard viewModel.stepCount < maxSteps else {
            viewModel.addLogEntry("⚠️ Maximum steps (\(maxSteps)) reached — stopping")
            stopAITask()
            return
        }
        
        viewModel.stepCount += 1
        let step = viewModel.stepCount
        
        // Step 1: Get screenshot (from companion or local)
        viewModel.statusMessage = "Requesting screenshot (step \(step))…"
        viewModel.addLogEntry("📸 Requesting screenshot…")
        
        if controlTarget == .mac {
            // Local Mac screenshot
            guard let capture = localExecutor.captureScreenshot() else {
                viewModel.addLogEntry("❌ Failed to capture Mac screenshot")
                viewModel.statusMessage = "Failed to capture screenshot"
                viewModel.isError = true
                stopAITask()
                return
            }
            
            // Display screenshot
            if let imageData = Data(base64Encoded: capture.base64),
               let image = NSImage(data: imageData) {
                viewModel.latestScreenshot = image
                viewModel.addLogEntry("📸 Screenshot received (\(capture.width)×\(capture.height))")
            }
            
            // Analyze and execute locally
            viewModel.statusMessage = "AI analyzing screenshot (step \(step))…"
            viewModel.addLogEntry("🤖 Sending to Gemini for analysis…")
            
            DispatchQueue.global(qos: .userInitiated).async {
                let resizedBase64 = self.resizeScreenshotForAI(capture.base64)
                
                self.aiManager.analyzeScreenshot(prompt: prompt, screenshotBase64: resizedBase64) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self = self, self.isTaskRunning, !self.shouldCancelTask else { return }
                        self.handleAIResult(result, prompt: prompt, step: step)
                    }
                }
            }
        } else {
            // Remote PC screenshot
            tcpManager.requestScreenshot { [weak self] screenshotMessage in
                guard let self = self, self.isTaskRunning, !self.shouldCancelTask else { return }
                
                guard let base64 = screenshotMessage.imageBase64 else {
                    self.viewModel.addLogEntry("❌ Invalid screenshot data")
                    self.viewModel.statusMessage = "Failed to get screenshot"
                    self.viewModel.isError = true
                    self.stopAITask()
                    return
                }
                
                // Display the full-res screenshot
                if let imageData = Data(base64Encoded: base64),
                   let image = NSImage(data: imageData) {
                    self.viewModel.latestScreenshot = image
                    self.viewModel.addLogEntry("📸 Screenshot received (\(screenshotMessage.width ?? 0)×\(screenshotMessage.height ?? 0))")
                }
                
                // Step 2: Downscale screenshot for AI (4K is way too large)
                self.viewModel.statusMessage = "AI analyzing screenshot (step \(step))…"
                self.viewModel.addLogEntry("🤖 Sending to Gemini for analysis…")
                
                DispatchQueue.global(qos: .userInitiated).async {
                    let resizedBase64 = self.resizeScreenshotForAI(base64)
                    
                    self.aiManager.analyzeScreenshot(prompt: prompt, screenshotBase64: resizedBase64) { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self = self, self.isTaskRunning, !self.shouldCancelTask else { return }
                            self.handleAIResult(result, prompt: prompt, step: step)
                        }
                    }
                }
            }
        }
    }
    
    /// Handle the AI result — shared between local and remote paths.
    private func handleAIResult(_ result: Result<ControlMessage, Error>, prompt: String, step: Int) {
        switch result {
        case .success(let actionMessage):
            guard let action = actionMessage.action else {
                viewModel.addLogEntry("❌ AI returned no action")
                stopAITask()
                return
            }
            
            // Check if the task is done
            if action == .done {
                let summary = actionMessage.summary ?? "Task completed"
                viewModel.addLogEntry("✅ Done: \(summary)")
                viewModel.statusMessage = summary
                isTaskRunning = false
                viewModel.isRunning = false
                if tcpManager.isConnected {
                    statusBar.updateState(.connected)
                }
                return
            }
            
            // Log the action
            logAction(actionMessage)
            
            // Wait action — handled locally
            if action == .wait {
                let waitTime = actionMessage.seconds ?? 1.0
                viewModel.statusMessage = "Waiting \(waitTime)s…"
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    self.agentLoop(prompt: prompt)
                }
                return
            }
            
            // Execute action based on target
            viewModel.statusMessage = "Executing action (step \(step))…"
            
            if controlTarget == .mac {
                // Local Mac execution
                localExecutor.execute(actionMessage) { [weak self] success, error in
                    guard let self = self, self.isTaskRunning, !self.shouldCancelTask else { return }
                    DispatchQueue.main.async {
                        if !success {
                            self.viewModel.addLogEntry("⚠️ Action failed: \(error ?? "unknown")")
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.agentLoop(prompt: prompt)
                        }
                    }
                }
            } else {
                // Remote PC execution
                tcpManager.executeAction(actionMessage) { [weak self] resultMessage in
                    guard let self = self, self.isTaskRunning, !self.shouldCancelTask else { return }
                    if resultMessage.success == false {
                        self.viewModel.addLogEntry("⚠️ Action failed: \(resultMessage.error ?? "unknown")")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.agentLoop(prompt: prompt)
                    }
                }
            }
            
        case .failure(let error):
            viewModel.addLogEntry("❌ AI error: \(error.localizedDescription)")
            viewModel.statusMessage = "AI error: \(error.localizedDescription)"
            viewModel.isError = true
            stopAITask()
        }
    }
    
    private func logAction(_ message: ControlMessage) {
        guard let action = message.action else { return }
        
        switch action {
        case .mouseMove:
            let x = String(format: "%.2f", message.normalizedX ?? 0)
            let y = String(format: "%.2f", message.normalizedY ?? 0)
            viewModel.addLogEntry("🖱 Move to (\(x), \(y))")
        case .click:
            let x = String(format: "%.2f", message.normalizedX ?? 0)
            let y = String(format: "%.2f", message.normalizedY ?? 0)
            let btn = message.button?.rawValue ?? "left"
            let count = message.clickCount ?? 1
            viewModel.addLogEntry("🖱 \(count > 1 ? "Double-c" : "C")lick (\(btn)) at (\(x), \(y))")
        case .type:
            let text = message.text ?? ""
            let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
            viewModel.addLogEntry("⌨️ Type: \"\(preview)\"")
        case .keyCombo:
            let keys = message.keys?.joined(separator: "+") ?? ""
            viewModel.addLogEntry("⌨️ Key combo: \(keys)")
        case .scroll:
            viewModel.addLogEntry("🖱 Scroll (dx=\(message.scrollDeltaX ?? 0), dy=\(message.scrollDeltaY ?? 0))")
        case .wait:
            viewModel.addLogEntry("⏳ Wait \(message.seconds ?? 1)s")
        case .done:
            viewModel.addLogEntry("✅ \(message.summary ?? "Done")")
        }
    }
    
    // MARK: - Screenshot Resizing
    
    /// Downscale a base64 PNG screenshot to a smaller JPEG for AI analysis.
    /// 4K (3840×2160) screenshots produce ~8MB base64 — this reduces to ~200-400KB.
    private func resizeScreenshotForAI(_ base64PNG: String) -> String {
        guard let imageData = Data(base64Encoded: base64PNG),
              let image = NSImage(data: imageData) else {
            print("⚠️ [AIManager] Could not decode screenshot for resizing")
            return base64PNG  // Fall back to original
        }
        
        let originalSize = image.size
        let maxWidth: CGFloat = 1024
        
        // Only downscale if wider than maxWidth
        let scale: CGFloat
        if originalSize.width > maxWidth {
            scale = maxWidth / originalSize.width
        } else {
            scale = 1.0
        }
        
        let newSize = NSSize(
            width: originalSize.width * scale,
            height: originalSize.height * scale
        )
        
        // Draw into a new bitmap
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(newSize.width),
            pixelsHigh: Int(newSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            print("⚠️ [AIManager] Could not create bitmap for resizing")
            return base64PNG
        }
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        image.draw(in: NSRect(origin: .zero, size: newSize))
        NSGraphicsContext.restoreGraphicsState()
        
        // Encode as JPEG (much smaller than PNG)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) else {
            print("⚠️ [AIManager] Could not encode JPEG")
            return base64PNG
        }
        
        let resizedBase64 = jpegData.base64EncodedString()
        print("🔵 [AIManager] Screenshot resized: \(Int(originalSize.width))×\(Int(originalSize.height)) → \(Int(newSize.width))×\(Int(newSize.height)), \(base64PNG.count / 1024)KB → \(resizedBase64.count / 1024)KB")
        return resizedBase64
    }
    
    // MARK: - USB-C Interface Detection
    
    private func checkUSBInterface() {
        var detected = false
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }
            
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                ptr.pointee.ifa_addr,
                socklen_t(addr.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            
            let address = String(cString: hostname)
            if address.hasPrefix("192.168.100.") {
                detected = true
                break
            }
        }
        
        let previouslyDetected = cableDetected
        cableDetected = detected
        
        if detected {
            missedInterfaceChecks = 0
            
            if !previouslyDetected {
                print("🔌 [MouseControl] USB-C interface detected — starting listener.")
                tcpManager.stopListening()
                tcpManager.startListening()
                statusBar.updateState(.waitingForCompanion)
            }
        } else if previouslyDetected {
            missedInterfaceChecks += 1
            
            if missedInterfaceChecks >= 2 {
                print("🔌 [MouseControl] USB-C interface lost — stopping listener.")
                if isTaskRunning {
                    stopAITask()
                }
                tcpManager.stopListening()
                statusBar.updateState(.cableNotDetected)
                viewModel.isConnected = false
            }
        }
    }
}

// MARK: - TCPManagerDelegate

extension AppDelegate: TCPManagerDelegate {
    func clientConnected() {
        print("🟢 [MouseControl] Companion connected.")
        statusBar.updateState(.connected)
        viewModel.isConnected = true
    }
    
    func clientDisconnected() {
        print("🔴 [MouseControl] Companion disconnected.")
        if isTaskRunning {
            stopAITask()
        }
        viewModel.isConnected = false
        
        if cableDetected {
            statusBar.updateState(.waitingForCompanion)
        } else {
            statusBar.updateState(.cableNotDetected)
        }
    }
    
    func messageReceived(_ message: ControlMessage) {
        // Handle any unexpected messages
        print("📨 [MouseControl] Received message: \(message.type)")
    }
}

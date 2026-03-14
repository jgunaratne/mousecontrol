import SwiftUI
import AppKit
import Speech

/// The main prompt window view — where the user enters a task and sees AI progress.
struct PromptView: View {
    @ObservedObject var viewModel: PromptViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cursorarrow.rays")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("MouseControl")
                    .font(.title2.bold())
                Spacer()
                connectionBadge
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Main content
            VStack(spacing: 12) {
                // API Key field (only shown if not configured)
                if !viewModel.isProjectConfigured {
                    projectIDSection
                }
                
                // Prompt input
                promptSection
                
                // Screenshot viewer
                if let screenshot = viewModel.latestScreenshot {
                    screenshotSection(screenshot)
                }
                
                // Action log
                if !viewModel.actionLog.isEmpty {
                    actionLogSection
                }
            }
            .padding(16)
            
            Spacer(minLength: 0)
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Subviews
    
    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(viewModel.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlColor))
        )
    }
    
    private var projectIDSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("GCP Project ID Required", systemImage: "cloud.fill")
                .font(.caption.bold())
                .foregroundColor(.orange)
            
            Text("Uses Gemini 3.1 Pro Preview via Vertex AI. Run `gcloud auth application-default login` first.")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            HStack {
                TextField("your-gcp-project-id", text: $viewModel.projectIDInput)
                    .textFieldStyle(.roundedBorder)
                
                Button("Save") {
                    viewModel.saveProjectID()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
    
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What should I do on the \(viewModel.controlTarget == .pc ? "PC" : "Mac")?")
                    .font(.headline)
                Spacer()
                // PC / Mac toggle
                Picker("", selection: $viewModel.controlTarget) {
                    Text("PC").tag(ControlTarget.pc)
                    Text("Mac").tag(ControlTarget.mac)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .onChange(of: viewModel.controlTarget) { newTarget in
                    viewModel.onTargetChanged?(newTarget)
                }
                // Model selector
                Picker("", selection: $viewModel.selectedModel) {
                    ForEach(AIManager.availableModels, id: \.self) { model in
                        Text(Self.shortModelName(model)).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
                .onChange(of: viewModel.selectedModel) { newModel in
                    viewModel.onModelChanged?(newModel)
                }
            }
            
            HStack(spacing: 8) {
                // Mic toggle button
                Button(action: { viewModel.toggleVoice() }) {
                    Image(systemName: viewModel.isVoiceActive ? "mic.fill" : "mic")
                        .font(.title3)
                        .foregroundColor(viewModel.isVoiceActive ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .help(viewModel.isVoiceActive ? "Stop listening" : "Voice input")
                .disabled(viewModel.isRunning)
                
                TextField("e.g., Open Firefox and search for 'Swift tutorials'", text: $viewModel.prompt)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isRunning)
                    .onSubmit {
                        if !viewModel.isRunning && !viewModel.prompt.isEmpty {
                            viewModel.startTask()
                        }
                    }
                
                if viewModel.isRunning {
                    Button(action: { viewModel.stopTask() }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button(action: { viewModel.startTask() }) {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.prompt.isEmpty || !viewModel.isConnected || !viewModel.isProjectConfigured)
                }
            }
            
            // Status
            if viewModel.isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundColor(viewModel.isError ? .red : .secondary)
            }
        }
    }
    
    /// Short display name for a model ID.
    private static func shortModelName(_ model: String) -> String {
        switch model {
        case "gemini-3.1-pro-preview": return "3.1 Pro"
        case "gemini-3.1-pro-preview-customtools": return "3.1 Pro (Custom Tools)"
        case "gemini-3.1-flash-preview": return "3.1 Flash"
        default: return model
        }
    }
    
    private func screenshotSection(_ image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Latest Screenshot")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Text("Step \(viewModel.stepCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 200)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
    }
    
    private var actionLogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Action Log")
                .font(.caption.bold())
                .foregroundColor(.secondary)
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(viewModel.actionLog.enumerated()), id: \.offset) { index, entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: viewModel.actionLog.count) { _ in
                    if let last = viewModel.actionLog.indices.last {
                        withAnimation {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - ViewModel

/// View model for the prompt window — manages task state and communicates with AppDelegate.
class PromptViewModel: ObservableObject {
    @Published var prompt: String = ""
    @Published var isRunning: Bool = false
    @Published var isConnected: Bool = false
    @Published var statusMessage: String = ""
    @Published var isError: Bool = false
    @Published var latestScreenshot: NSImage?
    @Published var actionLog: [String] = []
    @Published var stepCount: Int = 0
    @Published var projectIDInput: String = ""
    @Published var isProjectConfigured: Bool = false
    @Published var selectedModel: String = AIManager.availableModels[0]
    @Published var isVoiceActive: Bool = false
    @Published var controlTarget: ControlTarget = .pc
    
    /// Speech manager for voice input.
    let speechManager = SpeechManager()
    
    /// Called by the UI to start a new task.
    var onStartTask: ((String) -> Void)?
    
    /// Called by the UI to stop the current task.
    var onStopTask: (() -> Void)?
    
    /// Called when the user changes the model selection.
    var onModelChanged: ((String) -> Void)?
    
    /// Called when the user changes the control target.
    var onTargetChanged: ((ControlTarget) -> Void)?
    
    func startTask() {
        guard !prompt.isEmpty else { return }
        onStartTask?(prompt)
    }
    
    func stopTask() {
        onStopTask?()
    }
    
    func toggleVoice() {
        if isVoiceActive {
            // Stop listening — this will fire onFinalResult → startTask
            speechManager.stopListening()
            isVoiceActive = false
        } else {
            // Set up callbacks
            speechManager.onTranscription = { [weak self] text in
                self?.prompt = text
            }
            speechManager.onFinalResult = { [weak self] text in
                self?.prompt = text
                self?.isVoiceActive = false
                // Auto-start the task when mic is stopped
                if !text.isEmpty {
                    self?.startTask()
                }
            }
            speechManager.startListening()
            isVoiceActive = true
        }
    }
    
    func saveProjectID() {
        guard !projectIDInput.isEmpty else { return }
        let aiManager = AIManager()
        aiManager.projectID = projectIDInput
        isProjectConfigured = true
        projectIDInput = ""
    }
    
    func addLogEntry(_ entry: String) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        actionLog.append("[\(timestamp)] \(entry)")
    }
}

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

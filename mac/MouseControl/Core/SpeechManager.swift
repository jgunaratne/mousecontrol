import Foundation
import Speech
import AVFoundation

/// Manages live speech-to-text using macOS SFSpeechRecognizer + AVAudioEngine.
/// Streams partial transcriptions via `onTranscription` and final results via `onFinalResult`.
/// Auto-submits after 1.5 seconds of silence.
class SpeechManager: NSObject, ObservableObject {
    
    @Published var isListening = false
    @Published var isAuthorized = false
    
    /// Called with partial transcriptions (updates as user speaks).
    var onTranscription: ((String) -> Void)?
    
    /// Called when listening stops with the final transcription.
    var onFinalResult: ((String) -> Void)?
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    /// Timer that fires after silence to auto-submit.
    private var silenceTimer: Timer?
    
    /// How long to wait after the last speech before auto-submitting (seconds).
    private let silenceTimeout: TimeInterval = 1.5
    
    /// The latest transcription text (used when silence timer fires).
    private var latestTranscription: String = ""
    
    override init() {
        super.init()
        checkAuthorization()
    }
    
    // MARK: - Authorization
    
    func checkAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.isAuthorized = (status == .authorized)
                if status != .authorized {
                    print("⚠️ [Speech] Authorization status: \(status.rawValue)")
                }
            }
        }
    }
    
    // MARK: - Start / Stop
    
    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }
    
    func startListening() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("❌ [Speech] Speech recognizer not available")
            return
        }
        guard isAuthorized else {
            print("❌ [Speech] Not authorized for speech recognition")
            return
        }
        
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil
        latestTranscription = ""
        
        // Set up the audio session
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Create a new recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        // Start the recognition task
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let transcription = result.bestTranscription.formattedString
                self.latestTranscription = transcription
                
                DispatchQueue.main.async {
                    self.onTranscription?(transcription)
                    // Reset the silence timer on each new transcription
                    self.resetSilenceTimer()
                }
                
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.silenceTimer?.invalidate()
                        self.silenceTimer = nil
                        self.onFinalResult?(transcription)
                        self.stopListening()
                    }
                }
            }
            
            if let error = error {
                print("⚠️ [Speech] Recognition error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    // If we have text, treat it as final
                    if !self.latestTranscription.isEmpty {
                        self.onFinalResult?(self.latestTranscription)
                    }
                    self.stopListening()
                }
            }
        }
        
        // Install a tap on the audio input
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        // Start the audio engine
        do {
            audioEngine.prepare()
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isListening = true
            }
            print("🎤 [Speech] Listening started")
        } catch {
            print("❌ [Speech] Audio engine failed to start: \(error.localizedDescription)")
        }
    }
    
    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        
        DispatchQueue.main.async {
            self.isListening = false
        }
        print("🎤 [Speech] Listening stopped")
    }
    
    // MARK: - Silence Timer
    
    /// Reset the silence timer — fires after `silenceTimeout` seconds of no new speech.
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            guard let self = self, self.isListening else { return }
            print("🎤 [Speech] Silence detected — auto-submitting")
            let text = self.latestTranscription
            self.onFinalResult?(text)
            self.stopListening()
        }
    }
}


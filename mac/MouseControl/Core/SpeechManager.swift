import Foundation
import Speech
import AVFoundation

/// Manages live speech-to-text using macOS SFSpeechRecognizer + AVAudioEngine.
/// Streams partial transcriptions via `onTranscription` and final results via `onFinalResult`.
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
                DispatchQueue.main.async {
                    self.onTranscription?(transcription)
                }
                
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.onFinalResult?(transcription)
                        self.stopListening()
                    }
                }
            }
            
            if let error = error {
                print("⚠️ [Speech] Recognition error: \(error.localizedDescription)")
                DispatchQueue.main.async {
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
}

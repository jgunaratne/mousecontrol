import Foundation
import Network

/// Delegate callbacks for TCP connection state changes and received messages.
protocol TCPManagerDelegate: AnyObject {
    func clientConnected()
    func clientDisconnected()
    func messageReceived(_ message: ControlMessage)
}

/// Manages a TCP server that listens for a single companion PC connection.
/// Messages are framed with a 4-byte big-endian length header followed by JSON payload.
/// Adapted from MouseShare's TCPManager — supports larger payloads (screenshots up to 10MB).
class TCPManager {
    
    weak var delegate: TCPManagerDelegate?
    
    /// Whether a client is currently connected.
    private(set) var isConnected: Bool = false
    
    /// The address to bind to (USB-C interface).
    private let host: NWEndpoint.Host = "192.168.100.1"
    
    /// The port to listen on.
    private let port: NWEndpoint.Port = 9877  // Different port from MouseShare (9876)
    
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.mousecontrol.tcp", qos: .userInteractive)
    
    /// Timer that sends heartbeat messages to the connected client.
    private var heartbeatTimer: DispatchSourceTimer?
    
    /// Interval between heartbeat messages (seconds).
    private let heartbeatInterval: TimeInterval = 10
    
    /// Maximum allowed message size (10 MB — screenshots can be large).
    private let maxMessageSize: UInt32 = 10_000_000
    
    /// Completion handler for pending screenshot requests.
    private var screenshotCompletion: ((ControlMessage) -> Void)?
    
    /// Completion handler for pending action results.
    private var actionResultCompletion: ((ControlMessage) -> Void)?
    
    // MARK: - Server Lifecycle
    
    /// Start listening for incoming connections on the USB-C interface.
    func startListening() {
        do {
            let params = NWParameters.tcp
            
            // Enable TCP keepalive for dead-peer detection.
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 30
                tcpOptions.keepaliveInterval = 10
                tcpOptions.keepaliveCount = 3
            }
            
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: port)
            
            listener = try NWListener(using: params)
        } catch {
            print("❌ [TCPManager] Failed to create listener: \(error)")
            return
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("✅ [TCPManager] Listening on \(self?.host ?? "?"):\(self?.port ?? 0)")
            case .failed(let error):
                print("❌ [TCPManager] Listener failed: \(error)")
                self?.listener?.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.startListening()
                }
            case .cancelled:
                print("⏹ [TCPManager] Listener cancelled.")
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] newConnection in
            self?.handleNewConnection(newConnection)
        }
        
        listener?.start(queue: queue)
    }
    
    /// Stop the listener and disconnect any active client.
    func stopListening() {
        listener?.cancel()
        listener = nil
        disconnect()
    }
    
    // MARK: - Connection Handling
    
    private func handleNewConnection(_ newConnection: NWConnection) {
        if let existing = connection {
            print("⚠️ [TCPManager] New connection replacing existing one.")
            existing.cancel()
        }
        
        connection = newConnection
        
        newConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("✅ [TCPManager] Companion connected.")
                self?.isConnected = true
                self?.startHeartbeat()
                DispatchQueue.main.async {
                    self?.delegate?.clientConnected()
                }
                self?.receiveNextMessage()
                
            case .failed(let error):
                print("❌ [TCPManager] Connection failed: \(error)")
                self?.handleDisconnect()
                
            case .cancelled:
                self?.handleDisconnect()
                
            default:
                break
            }
        }
        
        newConnection.start(queue: queue)
    }
    
    private func disconnect() {
        stopHeartbeat()
        connection?.cancel()
        connection = nil
        if isConnected {
            isConnected = false
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.clientDisconnected()
            }
        }
    }
    
    private func handleDisconnect() {
        print("📡 [TCPManager] Companion disconnected.")
        stopHeartbeat()
        connection = nil
        isConnected = false
        
        // Cancel any pending completions.
        screenshotCompletion = nil
        actionResultCompletion = nil
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.clientDisconnected()
        }
    }
    
    // MARK: - Heartbeat
    
    private func startHeartbeat() {
        stopHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isConnected else { return }
            self.send(.heartbeat())
        }
        heartbeatTimer = timer
        timer.resume()
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
    
    // MARK: - Sending (Length-Prefixed JSON)
    
    /// Send a message to the connected companion PC.
    func send(_ message: ControlMessage) {
        guard let connection = connection, isConnected else { return }
        
        do {
            let jsonData = try JSONEncoder().encode(message)
            var length = UInt32(jsonData.count).bigEndian
            var frameData = Data(bytes: &length, count: 4)
            frameData.append(jsonData)
            
            connection.send(content: frameData, completion: .contentProcessed { error in
                if let error = error {
                    print("⚠️ [TCPManager] Send error: \(error)")
                }
            })
        } catch {
            print("❌ [TCPManager] Failed to encode message: \(error)")
        }
    }
    
    /// Request a screenshot from the companion and wait for the response.
    func requestScreenshot(completion: @escaping (ControlMessage) -> Void) {
        screenshotCompletion = completion
        send(.requestScreenshot())
    }
    
    /// Send an action to the companion and wait for the result.
    func executeAction(_ message: ControlMessage, completion: @escaping (ControlMessage) -> Void) {
        actionResultCompletion = completion
        send(message)
    }
    
    // MARK: - Receiving (Length-Prefixed JSON)
    
    private func receiveNextMessage() {
        guard let connection = connection else { return }
        
        // Read 4-byte length header
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            if let error = error {
                print("❌ [TCPManager] Receive header error: \(error)")
                self?.handleDisconnect()
                return
            }
            
            if isComplete {
                self?.handleDisconnect()
                return
            }
            
            guard let headerData = data, headerData.count == 4 else {
                self?.handleDisconnect()
                return
            }
            
            let length = headerData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            guard length > 0, length < self?.maxMessageSize ?? 10_000_000 else {
                print("⚠️ [TCPManager] Invalid message length: \(length)")
                self?.handleDisconnect()
                return
            }
            
            self?.receivePayload(length: Int(length))
        }
    }
    
    private func receivePayload(length: Int) {
        guard let connection = connection else { return }
        
        // For large payloads (screenshots), we may need to accumulate data.
        var accumulated = Data()
        accumulated.reserveCapacity(length)
        
        receiveChunked(connection: connection, remaining: length, accumulated: accumulated)
    }
    
    /// Receive data in chunks until we have the full payload.
    /// NWConnection.receive may return less than requested for large messages.
    private func receiveChunked(connection: NWConnection, remaining: Int, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            if let error = error {
                print("❌ [TCPManager] Receive payload error: \(error)")
                self?.handleDisconnect()
                return
            }
            
            if isComplete && (data == nil || data!.isEmpty) {
                self?.handleDisconnect()
                return
            }
            
            guard let chunk = data else {
                self?.handleDisconnect()
                return
            }
            
            var buffer = accumulated
            buffer.append(chunk)
            
            if buffer.count < remaining + accumulated.count - remaining {
                // Still need more data
                let stillNeeded = remaining - chunk.count
                if stillNeeded > 0 {
                    self?.receiveChunked(connection: connection, remaining: stillNeeded, accumulated: buffer)
                    return
                }
            }
            
            // Check if we have all the data
            let totalNeeded = accumulated.count + remaining
            if buffer.count >= totalNeeded - accumulated.count + chunk.count {
                // We may have enough, let's check
            }
            
            let newRemaining = remaining - chunk.count
            if newRemaining > 0 {
                self?.receiveChunked(connection: connection, remaining: newRemaining, accumulated: buffer)
                return
            }
            
            // Full payload received
            do {
                let message = try JSONDecoder().decode(ControlMessage.self, from: buffer)
                self?.handleReceivedMessage(message)
            } catch {
                print("⚠️ [TCPManager] Failed to decode message: \(error)")
            }
            
            // Loop: wait for the next message
            self?.receiveNextMessage()
        }
    }
    
    private func handleReceivedMessage(_ message: ControlMessage) {
        switch message.type {
        case .screenshotData:
            if let completion = screenshotCompletion {
                screenshotCompletion = nil
                DispatchQueue.main.async {
                    completion(message)
                }
            }
            
        case .actionResult:
            if let completion = actionResultCompletion {
                actionResultCompletion = nil
                DispatchQueue.main.async {
                    completion(message)
                }
            }
            
        case .heartbeat:
            break // Silent
            
        default:
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.messageReceived(message)
            }
        }
    }
}

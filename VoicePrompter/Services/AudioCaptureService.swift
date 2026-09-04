//
//  AudioCaptureService.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import AVFoundation
import Accelerate

nonisolated private final class SingleBufferConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !wasSupplied else {
            status.pointee = .noDataNow
            return nil
        }

        wasSupplied = true
        status.pointee = .haveData
        return buffer
    }
}

struct AudioInputSource: Identifiable, Equatable {
    let id: String
    let name: String
    let portType: AVAudioSession.Port

    var icon: String {
        switch portType {
        case .builtInMic:
            return "iphone"
        case .headsetMic:
            return "headphones"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            return "airpodspro"
        case .usbAudio:
            return "cable.connector"
        case .carAudio:
            return "car"
        default:
            return "mic"
        }
    }

    static func == (lhs: AudioInputSource, rhs: AudioInputSource) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
protocol AudioCapturing: AnyObject {
    var onAudioBuffer: (@Sendable (Data) -> Void)? { get set }
    var onMicLevel: (@Sendable (Float) -> Void)? { get set }
    var micBoost: Float { get set }
    var voiceIsolation: Bool { get set }
    func requestPermission() async throws
    func start() throws
    func stop()
    func getAvailableInputs() -> [AudioInputSource]
    func getCurrentInput() -> AudioInputSource?
    func setInput(_ source: AudioInputSource) throws
}

@MainActor
final class AudioCaptureService: NSObject, AudioCapturing {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var isCapturing = false
    private var hasInstalledTap = false
    private var sessionIsActive = false

    var onAudioBuffer: (@Sendable (Data) -> Void)?
    var onMicLevel: (@Sendable (Float) -> Void)?

    // Audio enhancement settings
    var micBoost: Float = 1.0  // Gain multiplier (1.0 to 4.0)
    var voiceIsolation: Bool = false

    /// Get all available audio input sources
    func getAvailableInputs() -> [AudioInputSource] {
        let session = AVAudioSession.sharedInstance()
        guard let inputs = session.availableInputs else { return [] }

        return inputs.map { port in
            AudioInputSource(
                id: port.uid,
                name: port.portName,
                portType: port.portType
            )
        }
    }

    /// Get the currently active input source
    func getCurrentInput() -> AudioInputSource? {
        let session = AVAudioSession.sharedInstance()
        guard let currentRoute = session.currentRoute.inputs.first else { return nil }

        return AudioInputSource(
            id: currentRoute.uid,
            name: currentRoute.portName,
            portType: currentRoute.portType
        )
    }

    /// Switch to a specific input source
    func setInput(_ source: AudioInputSource) throws {
        let session = AVAudioSession.sharedInstance()
        guard let inputs = session.availableInputs,
              let port = inputs.first(where: { $0.uid == source.id }) else {
            throw AudioCaptureError.inputNotFound
        }

        try session.setPreferredInput(port)
    }

    func requestPermission() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        try Task.checkCancellation()
        guard granted else { throw AudioCaptureError.microphoneDenied }
    }

    func start() throws {
        guard !isCapturing else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            let mode: AVAudioSession.Mode = voiceIsolation ? .voiceChat : .measurement
            try session.setCategory(.playAndRecord, mode: mode, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            sessionIsActive = true
            guard session.isInputAvailable else { throw AudioCaptureError.inputNotFound }

            let engine = AVAudioEngine()
            audioEngine = engine
            let input = engine.inputNode
            inputNode = input
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: 16000, channels: 1, interleaved: false) else {
                throw AudioCaptureError.formatCreationFailed
            }

            // The tap runs on an audio thread. Capture values instead of calling
            // main-actor methods or reading mutable UI settings from that thread.
            let gain = micBoost
            let audioCallback = onAudioBuffer
            let levelCallback = onMicLevel
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                Self.processBuffer(buffer, targetFormat: targetFormat, gain: gain,
                                   onAudio: audioCallback, onLevel: levelCallback)
            }
            hasInstalledTap = true
            try engine.start()
            isCapturing = true
        } catch {
            stop()
            throw error
        }
    }

    nonisolated private static func processBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat,
        gain: Float, onAudio: (@Sendable (Data) -> Void)?, onLevel: (@Sendable (Float) -> Void)?) {
        // If formats match, use buffer directly
        if buffer.format.isEqual(targetFormat) {
            processConvertedBuffer(buffer, gain: gain, onAudio: onAudio, onLevel: onLevel)
            return
        }
        
        // Convert to target format
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat),
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)) + 1) else {
            return
        }
        
        var error: NSError?
        let inputProvider = SingleBufferConverterInput(buffer: buffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            inputProvider.next(status: outStatus)
        }
        
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        
        guard error == nil else {
            return
        }
        
        processConvertedBuffer(convertedBuffer, gain: gain, onAudio: onAudio, onLevel: onLevel)
    }
    
    nonisolated private static func processConvertedBuffer(_ buffer: AVAudioPCMBuffer,
        gain: Float, onAudio: (@Sendable (Data) -> Void)?, onLevel: (@Sendable (Float) -> Void)?) {
        guard let floatChannelData = buffer.floatChannelData else {
            return
        }

        let channelData = floatChannelData[0]
        let frameLength = Int(buffer.frameLength)

        guard frameLength > 0 else { return }

        // Apply mic boost (gain) if greater than 1.0
        var processedData: [Float]
        if gain > 1.0 {
            // Apply gain using vDSP for efficiency
            var gain = gain
            processedData = [Float](repeating: 0, count: frameLength)
            vDSP_vsmul(channelData, 1, &gain, &processedData, 1, vDSP_Length(frameLength))

            // Soft clip to prevent harsh distortion
            for i in 0..<frameLength {
                processedData[i] = max(-1.0, min(1.0, processedData[i]))
            }
        } else {
            processedData = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        }

        // Calculate RMS level for mic meter (from processed audio)
        var rms: Float = 0
        processedData.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress!, 1, &rms, vDSP_Length(frameLength))
        }
        let level = min(1.0, max(0.0, rms * 10.0)) // Scale for visibility

        onLevel?(level)

        // Convert to Data for Whisper
        let data = processedData.withUnsafeBytes { Data($0) }
        onAudio?(data)
    }
    
    func stop() {
        if hasInstalledTap { inputNode?.removeTap(onBus: 0) }
        hasInstalledTap = false
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        isCapturing = false
        if sessionIsActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionIsActive = false
        }
    }
}

nonisolated enum AudioCaptureError: LocalizedError {
    case microphoneDenied
    case formatCreationFailed
    case inputNotFound

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off. Enable it for VoicePrompter in Settings, then try again."
        case .formatCreationFailed:
            return "The microphone is unavailable. Reconnect your microphone or headset, then try again."
        case .inputNotFound:
            return "No microphone is available. Connect a microphone or disconnect your headset, then try again."
        }
    }
}

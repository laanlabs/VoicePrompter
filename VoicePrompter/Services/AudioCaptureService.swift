//
//  AudioCaptureService.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import AVFoundation
import Accelerate

class AudioCaptureService: NSObject {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var isCapturing = false

    var onAudioBuffer: ((Data) -> Void)?
    var onMicLevel: ((Float) -> Void)?

    // Audio enhancement settings
    var micBoost: Float = 1.0  // Gain multiplier (1.0 to 4.0)
    var voiceIsolation: Bool = false
    
    func start() throws {
        guard !isCapturing else { return }

        // Request microphone permission
        let session = AVAudioSession.sharedInstance()

        // Use voiceChat mode for voice isolation (includes noise reduction)
        // or measurement mode for raw audio
        let audioMode: AVAudioSession.Mode = voiceIsolation ? .voiceChat : .measurement
        try session.setCategory(.playAndRecord, mode: audioMode, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        // Enable voice isolation on iOS 17+ if available
        if voiceIsolation {
            if #available(iOS 17.0, *) {
                try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
            }
        }
        
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw AudioCaptureError.engineCreationFailed
        }
        
        inputNode = engine.inputNode
        guard let input = inputNode else {
            throw AudioCaptureError.inputNodeNotFound
        }
        
        // Configure for 16kHz mono
        let inputFormat = input.inputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
        
        guard let format = targetFormat else {
            throw AudioCaptureError.formatCreationFailed
        }
        
        // Install tap
        let bufferSize: AVAudioFrameCount = 16000 // ~1 second at 16kHz
        
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer, targetFormat: format)
        }
        
        try engine.start()
        isCapturing = true
    }
    
    private func processBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        // If formats match, use buffer directly
        if buffer.format.isEqual(targetFormat) {
            processConvertedBuffer(buffer)
            return
        }
        
        // Convert to target format
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat),
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: buffer.frameLength) else {
            return
        }
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        
        guard error == nil else {
            return
        }
        
        processConvertedBuffer(convertedBuffer)
    }
    
    private func processConvertedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatChannelData = buffer.floatChannelData else {
            return
        }

        let channelData = floatChannelData[0]
        let frameLength = Int(buffer.frameLength)

        guard frameLength > 0 else { return }

        // Apply mic boost (gain) if greater than 1.0
        var processedData: [Float]
        if micBoost > 1.0 {
            // Apply gain using vDSP for efficiency
            var gain = micBoost
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

        DispatchQueue.main.async {
            self.onMicLevel?(level)
        }

        // Convert to Data for Whisper
        let data = processedData.withUnsafeBytes { Data($0) }
        onAudioBuffer?(data)
    }
    
    func stop() {
        guard isCapturing else { return }
        
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        isCapturing = false
        
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    deinit {
        stop()
    }
}

enum AudioCaptureError: Error {
    case engineCreationFailed
    case inputNodeNotFound
    case formatCreationFailed
}


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
    
    func start() throws {
        guard !isCapturing else { return }
        
        // Request microphone permission
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        
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
        
        // Calculate RMS level for mic meter
        let channelData = floatChannelData[0]
        let frameLength = Int(buffer.frameLength)
        
        guard frameLength > 0 else { return }
        
        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))
        let level = min(1.0, max(0.0, rms * 10.0)) // Scale for visibility
        
        DispatchQueue.main.async {
            self.onMicLevel?(level)
        }
        
        // Convert to Data for Whisper
        let data = Data(bytes: channelData, count: frameLength * MemoryLayout<Float>.size)
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


//
//  VoiceTrackEngine.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import Foundation
import Combine

enum VoiceTrackState: Equatable {
    case idle
    case loadingModel
    case listening
    case matched
    case paused
    case error(String)
}

struct TranscriptionLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let text: String
    let matchedIndex: Int?
    let wordsHeard: [String]
}

@MainActor
class VoiceTrackEngine: ObservableObject {
    @Published var state: VoiceTrackState = .idle
    @Published var currentWordIndex: Int = 0
    @Published var micLevel: Float = 0.0
    @Published var lastTranscription: String = ""
    @Published var isModelReady: Bool = false
    @Published var transcriptionLog: [TranscriptionLogEntry] = []
    @Published var lastMatchDebug: String = ""
    @Published var currentInputSource: AudioInputSource?
    @Published var availableInputSources: [AudioInputSource] = []

    private let audioCapture: any AudioCapturing
    let whisperService: WhisperService
    private let textMatcher = TextMatcher()
    
    private var audioBuffer: Data = Data()
    private var transcriptionTask: Task<Void, Never>?
    private var isRunning = false
    private var startupTask: Task<Void, Error>?
    
    private let bufferDuration: TimeInterval = 1.5 // Process 1.5-second chunks for faster response
    private let sampleRate: Double = 16000.0
    private let bytesPerSample = MemoryLayout<Float32>.size
    private let maxLogEntries = 20
    
    convenience init() {
        self.init(whisperService: .shared, audioCapture: AudioCaptureService())
    }

    init(whisperService: WhisperService, audioCapture: any AudioCapturing) {
        self.whisperService = whisperService
        self.audioCapture = audioCapture
        audioCapture.onAudioBuffer = { [weak self] data in
            Task { @MainActor [weak self] in
                await self?.handleAudioBuffer(data)
            }
        }
        
        audioCapture.onMicLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.micLevel = level
            }
        }
    }
    
    func loadScript(content: String, trackingMode: TrackingMode = .mix) {
        let plainText = MarkdownParser.extractPlainText(from: content)
        textMatcher.loadScript(plainText)
        textMatcher.configure(for: trackingMode)
        currentWordIndex = 0
        state = .idle
        transcriptionLog = []
        lastMatchDebug = ""
    }
    
    /// Configure audio settings before starting
    func configureAudio(micBoost: Float, voiceIsolation: Bool) {
        audioCapture.micBoost = micBoost
        audioCapture.voiceIsolation = voiceIsolation
    }

    /// Refresh available audio input sources
    func refreshInputSources() {
        availableInputSources = audioCapture.getAvailableInputs()
        currentInputSource = audioCapture.getCurrentInput()
    }

    /// Switch to a different audio input source
    func setInputSource(_ source: AudioInputSource) {
        do {
            try audioCapture.setInput(source)
            currentInputSource = source
            print("🎤 Switched to input: \(source.name)")
        } catch {
            print("❌ Failed to switch input: \(error)")
        }
    }

    func start() async throws {
        try Task.checkCancellation()
        if let previous = startupTask, previous.isCancelled {
            _ = await previous.result
            try Task.checkCancellation()
        }
        guard !isRunning else { return }
        let task: Task<Void, Error>
        if let existing = startupTask {
            task = existing
        } else {
            state = .loadingModel
            task = Task {
                defer { self.startupTask = nil }
                do {
                    try await self.audioCapture.requestPermission()
                    try Task.checkCancellation()
                    try await self.whisperService.loadModel()
                    try Task.checkCancellation()
                    self.isModelReady = true
                    try self.audioCapture.start()
                    self.refreshInputSources()
                    self.isRunning = true
                    self.state = .listening
                    self.audioBuffer = Data()
                } catch {
                    self.audioCapture.stop()
                    self.isRunning = false
                    self.state = Task.isCancelled || error is CancellationError ? .idle : .error(error.localizedDescription)
                    throw error
                }
            }
            startupTask = task
        }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }
    
    func stop() {
        startupTask?.cancel()
        whisperService.cancelLoading()
        isRunning = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        audioCapture.stop()
        audioBuffer = Data()
        micLevel = 0
        state = .idle
    }
    
    func reset() {
        textMatcher.reset()
        currentWordIndex = 0
        audioBuffer = Data()
        transcriptionLog = []
        lastMatchDebug = ""
        if isRunning {
            state = .listening
        } else {
            state = .idle
        }
    }
    
    private func handleAudioBuffer(_ data: Data) async {
        guard isRunning else { return }
        
        audioBuffer.append(data)
        
        // Process when we have enough audio
        let bufferSize = Int(bufferDuration * sampleRate * Double(bytesPerSample))
        if audioBuffer.count >= bufferSize {
            let chunk = audioBuffer.prefix(bufferSize)
            // Keep some overlap for better recognition
            let removeCount = Int(Double(bufferSize) * 0.7)
            audioBuffer.removeFirst(min(removeCount, audioBuffer.count))
            
            await processAudioChunk(chunk)
        }
    }
    
    private func processAudioChunk(_ audioData: Data) async {
        guard isRunning else { return }
        
        // Cancel previous transcription if still running
        transcriptionTask?.cancel()
        
        transcriptionTask = Task {
            do {
                guard let transcribedText = try await whisperService.transcribe(audioData) else {
                    return
                }
                
                guard !Task.isCancelled else { return }
                
                // Clean up transcription (remove leading/trailing whitespace)
                let cleanedText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Skip empty or very short transcriptions
                guard cleanedText.count > 1 else { return }
                
                // Store transcription for debug display
                lastTranscription = cleanedText
                print("🎤 Transcribed: '\(cleanedText)'")
                
                // Get the tokenized words for logging
                let heardWords = MarkdownParser.tokenize(cleanedText)
                
                // Match transcribed text against script
                let matchIndex = textMatcher.findMatch(transcribedText: cleanedText)
                
                // Create log entry
                let entry = TranscriptionLogEntry(
                    timestamp: Date(),
                    text: cleanedText,
                    matchedIndex: matchIndex,
                    wordsHeard: heardWords
                )
                
                // Add to log (keep limited entries)
                transcriptionLog.insert(entry, at: 0)
                if transcriptionLog.count > maxLogEntries {
                    transcriptionLog.removeLast()
                }
                
                // Update debug info
                if let debugInfo = textMatcher.lastDebugInfo {
                    let scriptSample = debugInfo.scriptWordsInRange.prefix(10).joined(separator: " ")
                    let posInfo = "Pos: \(textMatcher.getCurrentPosition())"
                    let confInfo = "Conf: \(String(format: "%.2f", debugInfo.bestConfidence))"
                    let proxInfo = "Prox: \(String(format: "%.2f", debugInfo.proximityBonus))"
                    lastMatchDebug = """
                    Heard: \(heardWords.joined(separator: " "))
                    Script[\(debugInfo.searchRange.lowerBound)...]: \(scriptSample)
                    \(posInfo) | \(confInfo) | \(proxInfo)
                    """
                }
                
                if let idx = matchIndex {
                    currentWordIndex = idx
                    state = .matched
                    print("✅ Matched at word index: \(idx)")
                } else {
                    // Keep listening, don't change to paused immediately
                    if case .matched = state {
                        // Only pause after multiple failed matches
                    }
                    print("⚠️ No match found for: \(heardWords)")
                }
            } catch {
                if !Task.isCancelled {
                    state = .error(error.localizedDescription)
                    print("❌ Error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    var wordCount: Int {
        textMatcher.wordCount
    }
    
    func getScriptWords() -> [String] {
        return textMatcher.getScriptWords()
    }
}

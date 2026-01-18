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
    
    private let audioCapture = AudioCaptureService()
    let whisperService = WhisperService()  // Exposed to allow observing loading status
    private let textMatcher = TextMatcher()
    
    private var audioBuffer: Data = Data()
    private var transcriptionTask: Task<Void, Never>?
    private var isRunning = false
    
    private let bufferDuration: TimeInterval = 1.5 // Process 1.5-second chunks for faster response
    private let sampleRate: Double = 16000.0
    private let bytesPerSample = MemoryLayout<Float32>.size
    private let maxLogEntries = 20
    
    init() {
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
    
    func loadScript(content: String) {
        let plainText = MarkdownParser.extractPlainText(from: content)
        textMatcher.loadScript(plainText)
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

    func start() async throws {
        guard !isRunning else { return }

        // Load Whisper model if needed
        if !whisperService.isModelLoaded {
            state = .loadingModel
            try await whisperService.loadModel()
            isModelReady = true
        }

        // Start audio capture
        try audioCapture.start()

        isRunning = true
        state = .listening
        audioBuffer = Data()
    }
    
    func stop() {
        guard isRunning else { return }
        
        isRunning = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        audioCapture.stop()
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


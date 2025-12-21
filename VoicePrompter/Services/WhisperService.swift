//
//  WhisperService.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import Foundation
import Combine
import WhisperKit

@MainActor
class WhisperService: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var loadingStatus: String = ""
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading: Bool = false
    @Published var errorMessage: String?
    
    private var whisperKit: WhisperKit?
    private let modelName = "openai_whisper-small.en"
    
    // Silence threshold - lower to be more sensitive
    private let silenceThreshold: Float = 0.0005
    
    // Standard path where WhisperKit caches models
    private var modelBasePath: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
    }
    
    private var modelPath: URL {
        modelBasePath.appendingPathComponent(modelName)
    }
    
    /// Check if the model folder exists and has content
    private func checkModelCache() -> (exists: Bool, fileCount: Int, path: String) {
        let fileManager = FileManager.default
        let path = modelPath.path
        
        guard fileManager.fileExists(atPath: path) else {
            return (false, 0, path)
        }
        
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            // Filter to only count actual model files (not hidden files)
            let modelFiles = contents.filter { !$0.hasPrefix(".") }
            return (modelFiles.count > 0, modelFiles.count, path)
        } catch {
            return (false, 0, path)
        }
    }
    
    func loadModel() async throws {
        guard !isModelLoaded else { return }
        
        isLoading = true
        errorMessage = nil
        
        // Check for cached model first
        loadingStatus = "Checking for speech model..."
        print("🔍 Checking for cached model...")
        
        let cacheStatus = checkModelCache()
        print("📁 Cache check: exists=\(cacheStatus.exists), files=\(cacheStatus.fileCount), path=\(cacheStatus.path)")
        
        do {
            if cacheStatus.exists && cacheStatus.fileCount >= 5 {
                // Model appears to be cached - try loading directly
                loadingStatus = "Loading cached model..."
                isDownloading = false
                downloadProgress = 1.0
                print("✅ Model found in cache with \(cacheStatus.fileCount) files")
                
                do {
                    let whisper = try await WhisperKit(
                        modelFolder: modelPath.path,
                        verbose: false,
                        logLevel: .error,
                        prewarm: true,
                        load: true,
                        download: false
                    )
                    whisperKit = whisper
                    print("✅ Loaded model from cache successfully")
                } catch {
                    // Cache might be corrupted, try downloading fresh
                    print("⚠️ Failed to load from cache: \(error.localizedDescription)")
                    print("📥 Will try downloading fresh copy...")
                    try await downloadModel()
                }
            } else {
                // No cache found - need to download
                if cacheStatus.exists {
                    loadingStatus = "Model cache incomplete, downloading..."
                    print("⚠️ Cache exists but incomplete (\(cacheStatus.fileCount) files)")
                } else {
                    loadingStatus = "Model not found, downloading..."
                    print("📥 No cached model found")
                }
                try await downloadModel()
            }
            
            loadingStatus = "Warming up model..."
            
            // Small delay to show the warming up message
            try? await Task.sleep(nanoseconds: 300_000_000)
            
            isModelLoaded = true
            isLoading = false
            loadingStatus = "Ready"
            print("✅ WhisperKit model loaded and ready")
            
        } catch {
            isLoading = false
            isDownloading = false
            errorMessage = error.localizedDescription
            loadingStatus = "Error: \(error.localizedDescription)"
            print("❌ Failed to load model: \(error)")
            throw error
        }
    }
    
    private func downloadModel() async throws {
        isDownloading = true
        downloadProgress = 0.0
        loadingStatus = "Downloading speech model (~150MB)..."
        print("📥 Starting model download...")
        
        // Start a task to show progress animation
        let progressTask = Task { @MainActor in
            var progress = 0.0
            while progress < 0.90 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000) // 0.8 second
                progress += 0.03
                self.downloadProgress = min(progress, 0.90)
                let percent = Int(self.downloadProgress * 100)
                self.loadingStatus = "Downloading speech model... \(percent)%"
            }
        }
        
        let whisper = try await WhisperKit(
            model: modelName,
            verbose: true,  // Enable verbose to see download progress in console
            logLevel: .info,
            prewarm: true,
            load: true,
            download: true
        )
        
        progressTask.cancel()
        isDownloading = false
        downloadProgress = 1.0
        loadingStatus = "Download complete!"
        whisperKit = whisper
        
        // Verify the download
        let newCacheStatus = checkModelCache()
        print("✅ Model downloaded and cached: \(newCacheStatus.fileCount) files at \(newCacheStatus.path)")
    }
    
    func transcribe(_ audioData: Data) async throws -> String? {
        guard let whisper = whisperKit else {
            throw WhisperError.modelNotLoaded
        }
        
        // Convert Data to Float32 array
        let floatArray = audioData.withUnsafeBytes { bytes -> [Float] in
            guard let baseAddress = bytes.baseAddress else { return [] }
            let count = audioData.count / MemoryLayout<Float32>.size
            return Array(UnsafeBufferPointer<Float32>(
                start: baseAddress.assumingMemoryBound(to: Float32.self),
                count: count
            ))
        }
        
        guard !floatArray.isEmpty else {
            return nil
        }
        
        // Check audio levels to avoid processing silence
        let rms = sqrt(floatArray.map { $0 * $0 }.reduce(0, +) / Float(floatArray.count))
        if rms < silenceThreshold {
            return nil
        }
        
        print("🎤 Processing audio (RMS: \(String(format: "%.4f", rms)))")
        
        // Transcribe with WhisperKit
        let decodeOptions = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )
        
        let results = try await whisper.transcribe(
            audioArray: floatArray,
            decodeOptions: decodeOptions
        )
        
        // Extract text from the first transcription result
        guard let firstResult = results.first else {
            return nil
        }
        
        let rawText = firstResult.text
        
        // Clean up the transcription
        let cleanedText = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Remove common Whisper artifacts
            .replacingOccurrences(of: #"^\s*\[.*?\]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\[.*?\]\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*\(.*?\)\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Skip if result is too short or looks like noise
        if cleanedText.count < 2 {
            return nil
        }
        
        print("🎙️ Transcribed: '\(cleanedText)'")
        return cleanedText
    }
}

enum WhisperError: Error {
    case modelNotLoaded
    case transcriptionFailed
}

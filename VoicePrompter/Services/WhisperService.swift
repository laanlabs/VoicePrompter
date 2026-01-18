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
    @Published var loadingSubtitle: String = ""  // Secondary status line
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading: Bool = false
    @Published var isLoadingFromCache: Bool = false
    @Published var errorMessage: String?
    @Published var canRetry: Bool = false

    private var whisperKit: WhisperKit?
    private let modelName = "openai_whisper-small.en"
    private var cacheLoadingTask: Task<Void, Never>?

    // Retry configuration
    private let maxRetries = 3
    private let baseRetryDelay: UInt64 = 2_000_000_000 // 2 seconds in nanoseconds
    
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

    /// Public method to check if download will be required (for pre-download prompt)
    func needsDownload() -> Bool {
        let cacheStatus = checkModelCache()
        // Model is considered cached if it exists with at least 5 files
        return !(cacheStatus.exists && cacheStatus.fileCount >= 5)
    }

    /// Simulate progress for cache loading with informative stages
    private func startCacheLoadingProgress() {
        isLoadingFromCache = true
        downloadProgress = 0.0

        cacheLoadingTask = Task { @MainActor in
            let stages: [(progress: Double, status: String, subtitle: String, duration: UInt64)] = [
                (0.05, "Loading cached model...", "Reading model files from storage", 500_000_000),
                (0.15, "Initializing encoder...", "Setting up audio processing", 2_000_000_000),
                (0.35, "Loading neural network...", "This may take a moment on older devices", 3_000_000_000),
                (0.55, "Preparing decoder...", "Loading language model", 2_500_000_000),
                (0.75, "Optimizing for device...", "Configuring for best performance", 2_000_000_000),
                (0.90, "Almost ready...", "Final initialization", 1_500_000_000),
            ]

            for stage in stages {
                guard !Task.isCancelled else { return }

                // Animate progress to this stage
                let startProgress = self.downloadProgress
                let targetProgress = stage.progress
                let steps = 10
                let stepDelay = stage.duration / UInt64(steps)

                for step in 1...steps {
                    guard !Task.isCancelled else { return }
                    let fraction = Double(step) / Double(steps)
                    self.downloadProgress = startProgress + (targetProgress - startProgress) * fraction
                    try? await Task.sleep(nanoseconds: stepDelay)
                }

                self.loadingStatus = stage.status
                self.loadingSubtitle = stage.subtitle
            }

            // Hold at 90% until actual loading completes
            while !Task.isCancelled && self.isLoadingFromCache {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopCacheLoadingProgress() {
        cacheLoadingTask?.cancel()
        cacheLoadingTask = nil
        isLoadingFromCache = false
        downloadProgress = 1.0
        loadingSubtitle = ""
    }

    /// Estimated download size for user disclosure
    static let estimatedDownloadSize = "~150 MB"
    
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
                isDownloading = false
                print("✅ Model found in cache with \(cacheStatus.fileCount) files")

                // Start the progress animation
                startCacheLoadingProgress()

                do {
                    let whisper = try await WhisperKit(
                        modelFolder: modelPath.path,
                        verbose: false,
                        logLevel: .error,
                        prewarm: true,
                        load: true,
                        download: false
                    )
                    stopCacheLoadingProgress()
                    whisperKit = whisper
                    print("✅ Loaded model from cache successfully")
                } catch {
                    stopCacheLoadingProgress()
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
            stopCacheLoadingProgress()

            // Provide user-friendly error message
            let userMessage: String
            if let whisperError = error as? WhisperError {
                userMessage = whisperError.errorDescription ?? error.localizedDescription
                canRetry = whisperError.isRetryable
            } else {
                let categorized = categorizeError(error)
                userMessage = categorized.errorDescription ?? error.localizedDescription
                canRetry = categorized.isRetryable
            }

            errorMessage = userMessage
            loadingStatus = "Error: \(userMessage)"
            print("❌ Failed to load model: \(error)")
            throw error
        }
    }
    
    private func downloadModel() async throws {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                try await attemptDownload(attempt: attempt)
                return // Success - exit the retry loop
            } catch {
                lastError = error
                let whisperError = categorizeError(error)

                if whisperError.isRetryable && attempt < maxRetries {
                    let delay = baseRetryDelay * UInt64(attempt) // Exponential backoff
                    let delaySecs = Double(delay) / 1_000_000_000
                    loadingStatus = "Connection issue, retrying in \(Int(delaySecs))s... (attempt \(attempt)/\(maxRetries))"
                    print("⚠️ Attempt \(attempt) failed: \(error.localizedDescription). Retrying in \(delaySecs)s...")
                    try? await Task.sleep(nanoseconds: delay)
                } else {
                    // Not retryable or last attempt - throw the error
                    throw whisperError
                }
            }
        }

        // If we get here, all retries failed
        if let error = lastError {
            throw categorizeError(error)
        }
    }

    private func attemptDownload(attempt: Int) async throws {
        isDownloading = true
        downloadProgress = 0.0

        if attempt > 1 {
            loadingStatus = "Retrying download (attempt \(attempt)/\(maxRetries))..."
        } else {
            loadingStatus = "Downloading speech model (~150MB)..."
        }
        print("📥 Starting model download (attempt \(attempt))...")

        // Start a task to show progress animation
        let progressTask = Task { @MainActor in
            var progress = 0.0
            while progress < 0.90 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000) // 0.8 second
                progress += 0.03
                self.downloadProgress = min(progress, 0.90)
                let percent = Int(self.downloadProgress * 100)
                if attempt > 1 {
                    self.loadingStatus = "Downloading (attempt \(attempt))... \(percent)%"
                } else {
                    self.loadingStatus = "Downloading speech model... \(percent)%"
                }
            }
        }

        defer {
            progressTask.cancel()
        }

        let whisper = try await WhisperKit(
            model: modelName,
            verbose: true,  // Enable verbose to see download progress in console
            logLevel: .info,
            prewarm: true,
            load: true,
            download: true
        )

        isDownloading = false
        downloadProgress = 1.0
        loadingStatus = "Download complete!"
        whisperKit = whisper

        // Verify the download
        let newCacheStatus = checkModelCache()
        print("✅ Model downloaded and cached: \(newCacheStatus.fileCount) files at \(newCacheStatus.path)")
    }

    /// Categorize errors to determine if they're retryable and provide better messages
    private func categorizeError(_ error: Error) -> WhisperError {
        let description = error.localizedDescription.lowercased()

        // Check for timeout errors
        if description.contains("504") || description.contains("timeout") || description.contains("timed out") {
            return .networkTimeout
        }

        // Check for server errors (5xx)
        if description.contains("502") || description.contains("bad gateway") {
            return .serverError(statusCode: 502)
        }
        if description.contains("503") || description.contains("service unavailable") {
            return .serverError(statusCode: 503)
        }
        if description.contains("500") || description.contains("internal server error") {
            return .serverError(statusCode: 500)
        }

        // For other errors, wrap them
        return .downloadFailed(underlying: error)
    }

    /// Reset error state and allow retry
    func resetForRetry() {
        errorMessage = nil
        canRetry = false
        loadingStatus = ""
        downloadProgress = 0.0
        isDownloading = false
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

enum WhisperError: Error, LocalizedError {
    case modelNotLoaded
    case transcriptionFailed
    case networkTimeout
    case serverError(statusCode: Int)
    case downloadFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Speech model not loaded"
        case .transcriptionFailed:
            return "Transcription failed"
        case .networkTimeout:
            return "Network timeout - please check your connection and try again"
        case .serverError(let code):
            return "Server error (\(code)) - this is usually temporary, please try again"
        case .downloadFailed(let error):
            return "Download failed: \(error.localizedDescription)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .networkTimeout, .serverError:
            return true
        case .downloadFailed(let error):
            // Check if underlying error suggests retry
            let desc = error.localizedDescription.lowercased()
            return desc.contains("timeout") || desc.contains("504") || desc.contains("502") || desc.contains("503")
        default:
            return false
        }
    }
}

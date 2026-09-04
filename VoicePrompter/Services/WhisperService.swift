import Foundation
import Combine
import OSLog
import WhisperKit

@MainActor
protocol SpeechModelBackend: AnyObject {
    func download(model: SpeechModel, root: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    func prepare(folder: URL, tokenizerRoot: URL) async throws
    func prewarm() async throws
    func load() async throws
    func unload() async
    func transcribe(audioArray: [Float], decodeOptions: DecodingOptions) async throws -> [TranscriptionResult]
}

@MainActor
final class WhisperKitBackend: SpeechModelBackend {
    private var whisper: WhisperKit?

    func download(model: SpeechModel, root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKit.download(variant: model.name, downloadBase: root) {
            progress($0.fractionCompleted)
        }
    }

    func prepare(folder: URL, tokenizerRoot: URL) async throws {
        whisper = try await WhisperKit(modelFolder: folder.path, tokenizerFolder: tokenizerRoot,
                                       verbose: false, logLevel: .error,
                                       prewarm: false, load: false, download: false)
    }

    func prewarm() async throws {
        guard let whisper else { throw SpeechSetupError.modelNotLoaded }
        try await whisper.prewarmModels()
    }

    func load() async throws {
        guard let whisper else { throw SpeechSetupError.modelNotLoaded }
        try await whisper.loadModels()
    }

    func unload() async {
        await whisper?.unloadModels()
        whisper = nil
    }

    func transcribe(audioArray: [Float], decodeOptions: DecodingOptions) async throws -> [TranscriptionResult] {
        guard let whisper else { throw SpeechSetupError.modelNotLoaded }
        return try await whisper.transcribe(audioArray: audioArray, decodeOptions: decodeOptions)
    }
}

@MainActor
final class WhisperService: ObservableObject {
    // Reopening a script reuses one model and waits for any canceled load to finish.
    static let shared = WhisperService()

    @Published private(set) var isModelLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var loadingStatus = ""
    @Published private(set) var loadingSubtitle = ""
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var isDownloading = false
    @Published private(set) var errorMessage: String?

    let model: SpeechModel
    private let cache: SpeechModelCache
    private let backend: any SpeechModelBackend
    private var loadingTask: Task<Void, Error>?
    private var loadID: UUID?
    private var isTranscribing = false
    private let logger = Logger(subsystem: "com.laan.labs.VoicePrompter", category: "SpeechSetup")
    private let silenceThreshold: Float = 0.0005

    var estimatedDownloadSize: String { model.estimatedDownloadSize }

    init(model: SpeechModel? = nil, downloadRoot: URL? = nil, backend: (any SpeechModelBackend)? = nil) {
        let selected = model ?? SpeechModel.recommended(defaultModel: WhisperKit.recommendedModels().default,
                                                        physicalMemory: ProcessInfo.processInfo.physicalMemory)
        self.model = selected
        self.cache = SpeechModelCache(downloadRoot: downloadRoot ?? FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("huggingface"), model: selected)
        self.backend = backend ?? WhisperKitBackend()
    }

    func needsDownload() -> Bool {
        !isModelLoaded && !(cache.hasModelReceipt && cache.hasModelFiles && cache.hasTokenizer)
    }

    func loadModel() async throws {
        try Task.checkCancellation()
        // Core ML may finish a native call after cancellation. Keep ownership until
        // it has unloaded, so a quick retry never overlaps that work.
        if let previous = loadingTask, previous.isCancelled {
            _ = await previous.result
            try Task.checkCancellation()
        }
        if isModelLoaded { return }
        let task: Task<Void, Error>
        if let existing = loadingTask {
            task = existing
        } else {
            let id = UUID()
            loadID = id
            task = Task {
                defer { self.loadingTask = nil; self.loadID = nil }
                try await self.performLoad(id: id)
            }
            loadingTask = task
        }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    func cancelLoading() { loadingTask?.cancel() }

    private func performLoad(id: UUID) async throws {
        isLoading = true
        errorMessage = nil
        downloadProgress = 0
        loadingStatus = "Checking speech files…"
        loadingSubtitle = ""
        logger.info("Starting speech setup: \(self.model.name, privacy: .public)")
        var initializing = false
        defer { isLoading = false; isDownloading = false; loadingSubtitle = "" }

        do {
            let cache = self.cache
            try await fileOperation { try cache.prepareStorage() }
            let valid = try await fileOperation { try cache.modelIsValid() }
            try Task.checkCancellation()
            if !valid {
                try await fileOperation { try cache.removeLegacyDownloads() }
                try await fileOperation { try cache.invalidateModel() }
                loadingStatus = "Downloading speech model…"
                loadingSubtitle = "\(estimatedDownloadSize). Keep the app open while downloading."
                isDownloading = true
                logger.info("Downloading speech model")
                try await backend.download(model: model, root: cache.downloadRoot) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.loadID == id, self.isDownloading,
                              self.loadingTask?.isCancelled == false, fraction.isFinite else { return }
                        self.downloadProgress = min(1, max(self.downloadProgress, fraction))
                    }
                }
                try Task.checkCancellation()
                isDownloading = false
                loadingStatus = "Verifying speech files…"
                try await fileOperation { try cache.recordDownload() }
            }
            try Task.checkCancellation()
            // A broken tokenizer cache must not be accepted by Hub's metadata fast path.
            if !cache.hasTokenizer {
                try await fileOperation { try cache.invalidateTokenizer() }
            }
            initializing = true
            loadingStatus = "Preparing speech recognition…"
            loadingSubtitle = "First-time preparation can take a few minutes. You can cancel at any time."
            logger.info("Prewarming speech model")
            try await backend.prepare(folder: cache.modelFolder, tokenizerRoot: cache.downloadRoot)
            try Task.checkCancellation()
            try await backend.prewarm()
            try Task.checkCancellation()
            loadingStatus = "Loading speech recognition…"
            loadingSubtitle = cache.hasTokenizer ? "Loading the model on your device." : "Finishing language setup. An internet connection may be needed."
            logger.info("Loading speech model and tokenizer")
            try await backend.load()
            try Task.checkCancellation()
            isModelLoaded = true
            loadingStatus = "Ready"
            logger.info("Speech model ready")
        } catch {
            await backend.unload()
            isModelLoaded = false
            if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                loadingStatus = ""
                logger.info("Speech setup canceled")
                throw CancellationError()
            }
            let failure: SpeechSetupError
            if SpeechSetupError.isStorageError(error) {
                failure = .insufficientStorage
            } else if SpeechSetupError.isNetworkError(error) {
                failure = .offline
            } else if let setupError = error as? SpeechSetupError {
                failure = setupError
            } else if initializing {
                // Retain files for diagnostics, but make an explicit user retry
                // replace both the model and its download metadata.
                try? cache.invalidateReceipt()
                try? cache.invalidateTokenizer()
                failure = .initialization(error.localizedDescription)
            } else {
                failure = .download(error.localizedDescription)
            }
            errorMessage = failure.localizedDescription
            loadingStatus = failure.localizedDescription
            logger.error("Speech setup failed: \(String(describing: error), privacy: .public)")
            throw failure
        }
    }

    private func fileOperation<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func transcribe(_ audioData: Data) async throws -> String? {
        try Task.checkCancellation()
        guard isModelLoaded else { throw SpeechSetupError.modelNotLoaded }
        // Cancellation of a Swift task does not guarantee Core ML has stopped.
        // Drop a chunk while inference is busy instead of allocating another run.
        guard !isTranscribing else { return nil }
        isTranscribing = true
        defer { isTranscribing = false }
        
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
        
        let results = try await backend.transcribe(
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
        
        return cleanedText
    }
}

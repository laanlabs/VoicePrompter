import AVFoundation
import Foundation
import XCTest
import WhisperKit
@testable import VoicePrompter

final class SpeechModelCacheTests: XCTestCase {
    func testModelRecommendationUsesSmallDeviceFallback() {
        XCTAssertEqual(SpeechModel.recommended(defaultModel: "openai_whisper-base.en",
                                               physicalMemory: 3 * 1_024 * 1_024 * 1_024), .tiny)
        XCTAssertEqual(SpeechModel.recommended(defaultModel: "openai_whisper-tiny.en",
                                               physicalMemory: 8 * 1_024 * 1_024 * 1_024), .tiny)
        XCTAssertEqual(SpeechModel.recommended(defaultModel: "openai_whisper-small.en",
                                               physicalMemory: 8 * 1_024 * 1_024 * 1_024), .base)
    }

    func testIncompleteModelDirectoryIsRejected() throws {
        try withTemporaryDirectory { root in
            let cache = SpeechModelCache(downloadRoot: root, model: .base)
            try FileManager.default.createDirectory(at: cache.modelFolder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: cache.modelFolder.appendingPathComponent("config.json"))

            XCTAssertFalse(cache.hasModelFiles)
            XCTAssertFalse(try cache.modelIsValid())
        }
    }

    func testReceiptDetectsModelTampering() throws {
        try withTemporaryDirectory { root in
            let cache = SpeechModelCache(downloadRoot: root, model: .base)
            try ModelFixture.writeModel(to: root, model: .base)
            try cache.recordDownload()
            XCTAssertTrue(try cache.modelIsValid())

            try Data("changed".utf8).write(
                to: cache.modelFolder.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin")
            )
            XCTAssertFalse(try cache.modelIsValid())
        }
    }

    func testInvalidationRemovesRejectedFilesAndDownloadMetadata() throws {
        try withTemporaryDirectory { root in
            let cache = SpeechModelCache(downloadRoot: root, model: .base)
            try ModelFixture.writeModel(to: root, model: .base)
            let metadata = cache.repository
                .appendingPathComponent(".cache/huggingface/download/\(cache.model.name)")
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            try Data("metadata".utf8).write(to: metadata.appendingPathComponent("file.metadata"))

            try cache.invalidateModel()

            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.modelFolder.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        }
    }

    func testLegacySmallModelIsRemovedBeforeMigration() throws {
        try withTemporaryDirectory { root in
            let cache = SpeechModelCache(downloadRoot: root, model: .base)
            let legacyModel = cache.repository.appendingPathComponent("openai_whisper-small.en")
            let legacyMetadata = cache.repository
                .appendingPathComponent(".cache/huggingface/download/openai_whisper-small.en")
            let legacyTokenizer = root.appendingPathComponent("models/openai/whisper-small.en")
            for folder in [legacyModel, legacyMetadata, legacyTokenizer] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("legacy".utf8).write(to: folder.appendingPathComponent("fixture"))
            }

            try cache.removeLegacyDownloads()

            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyModel.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyMetadata.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyTokenizer.path))
        }
    }

    func testModelStorageIsExcludedFromBackup() throws {
        try withTemporaryDirectory { root in
            let downloadRoot = root.appendingPathComponent("huggingface")
            let cache = SpeechModelCache(downloadRoot: downloadRoot, model: .base)

            try cache.prepareStorage()

            let values = try downloadRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
        }
    }
}

@MainActor
final class WhisperServiceTests: XCTestCase {
    func testLiveBaseModelDownloadAndInitialization() async throws {
        guard ProcessInfo.processInfo.environment["VOICEPROMPTER_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip("Set VOICEPROMPTER_LIVE_MODEL_TEST=1 to exercise the real model download.")
        }

        try await withTemporaryDirectory { root in
            let service = WhisperService(model: .base, downloadRoot: root)

            try await service.loadModel()

            XCTAssertTrue(service.isModelLoaded)
            XCTAssertFalse(service.needsDownload())
        }
    }

    func testConcurrentLoadsShareOneInitialization() async throws {
        try await withTemporaryDirectory { root in
            let backend = FakeSpeechModelBackend(downloadDelayNanoseconds: 50_000_000)
            let service = WhisperService(model: .base, downloadRoot: root, backend: backend)

            async let first: Void = service.loadModel()
            async let second: Void = service.loadModel()
            _ = try await (first, second)

            XCTAssertEqual(backend.downloadCalls, 1)
            XCTAssertEqual(backend.prepareCalls, 1)
            XCTAssertEqual(backend.prewarmCalls, 1)
            XCTAssertEqual(backend.loadCalls, 1)
            XCTAssertTrue(service.isModelLoaded)
        }
    }

    func testOfflineFailureIsActionable() async throws {
        try await withTemporaryDirectory { root in
            let backend = FakeSpeechModelBackend()
            backend.downloadError = URLError(.notConnectedToInternet)
            let service = WhisperService(model: .base, downloadRoot: root, backend: backend)

            do {
                try await service.loadModel()
                XCTFail("Expected speech setup to fail")
            } catch {
                guard let setupError = error as? SpeechSetupError,
                      case .offline = setupError else {
                    return XCTFail("Expected an offline error, got \(error)")
                }
            }

            XCTAssertEqual(service.errorMessage,
                           "Speech setup needs an internet connection. Connect to Wi-Fi or cellular data, then try again.")
            XCTAssertFalse(service.isLoading)
        }
    }

    func testInitializationFailureForcesARepairDownloadOnRetry() async throws {
        try await withTemporaryDirectory { root in
            let backend = FakeSpeechModelBackend()
            backend.prepareError = TestFailure.initialization
            let service = WhisperService(model: .base, downloadRoot: root, backend: backend)

            do {
                try await service.loadModel()
                XCTFail("Expected speech initialization to fail")
            } catch {
                guard let setupError = error as? SpeechSetupError,
                      case .initialization = setupError else {
                    return XCTFail("Expected an initialization error, got \(error)")
                }
            }
            XCTAssertTrue(service.needsDownload())

            backend.prepareError = nil
            try await service.loadModel()

            XCTAssertEqual(backend.downloadCalls, 2)
            XCTAssertTrue(service.isModelLoaded)
        }
    }
}

@MainActor
final class VoiceTrackEngineStartupTests: XCTestCase {
    func testConcurrentStartsShareOneStartup() async throws {
        try await withTemporaryDirectory { root in
            let backend = FakeSpeechModelBackend(downloadDelayNanoseconds: 50_000_000)
            let service = WhisperService(model: .base, downloadRoot: root, backend: backend)
            let audio = FakeAudioCapture()
            let engine = VoiceTrackEngine(whisperService: service, audioCapture: audio)

            async let first: Void = engine.start()
            async let second: Void = engine.start()
            _ = try await (first, second)

            XCTAssertEqual(audio.permissionRequests, 1)
            XCTAssertEqual(audio.startCalls, 1)
            XCTAssertEqual(backend.downloadCalls, 1)
            XCTAssertEqual(engine.state, .listening)
        }
    }

    func testStopDuringLoadingPreventsAudioStartup() async throws {
        try await withTemporaryDirectory { root in
            let backend = FakeSpeechModelBackend(downloadDelayNanoseconds: 2_000_000_000)
            let service = WhisperService(model: .base, downloadRoot: root, backend: backend)
            let audio = FakeAudioCapture()
            let engine = VoiceTrackEngine(whisperService: service, audioCapture: audio)
            let start = Task { try await engine.start() }

            while backend.downloadCalls == 0 { await Task.yield() }
            engine.stop()
            _ = await start.result

            XCTAssertEqual(audio.startCalls, 0)
            XCTAssertEqual(engine.state, .idle)
            XCTAssertFalse(service.isModelLoaded)
        }
    }

    func testAudioStartFailurePublishesRecoverableError() async throws {
        try await withTemporaryDirectory { root in
            let backend = FakeSpeechModelBackend()
            let service = WhisperService(model: .base, downloadRoot: root, backend: backend)
            let audio = FakeAudioCapture()
            audio.startError = TestFailure.audioStart
            let engine = VoiceTrackEngine(whisperService: service, audioCapture: audio)

            do {
                try await engine.start()
                XCTFail("Expected audio capture to fail")
            } catch {
                XCTAssertEqual(error as? TestFailure, .audioStart)
            }

            XCTAssertEqual(engine.state, .error(TestFailure.audioStart.localizedDescription))
            XCTAssertEqual(audio.stopCalls, 1)
        }
    }
}

private enum TestFailure: LocalizedError, Equatable {
    case audioStart
    case initialization

    var errorDescription: String? {
        switch self {
        case .audioStart: return "Audio startup failed."
        case .initialization: return "Model initialization failed."
        }
    }
}

@MainActor
private final class FakeSpeechModelBackend: SpeechModelBackend {
    var downloadCalls = 0
    var prepareCalls = 0
    var prewarmCalls = 0
    var loadCalls = 0
    var unloadCalls = 0
    var downloadError: Error?
    var prepareError: Error?
    var prewarmError: Error?
    var loadError: Error?
    let downloadDelayNanoseconds: UInt64

    init(downloadDelayNanoseconds: UInt64 = 0) {
        self.downloadDelayNanoseconds = downloadDelayNanoseconds
    }

    func download(model: SpeechModel, root: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadCalls += 1
        progress(0.25)
        if downloadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: downloadDelayNanoseconds)
        }
        if let downloadError { throw downloadError }
        try ModelFixture.writeModel(to: root, model: model)
        progress(1)
    }

    func prepare(folder: URL, tokenizerRoot: URL) async throws {
        prepareCalls += 1
        if let prepareError { throw prepareError }
        let model: SpeechModel = folder.lastPathComponent.contains("tiny") ? .tiny : .base
        try ModelFixture.writeTokenizer(to: tokenizerRoot, model: model)
    }

    func prewarm() async throws {
        prewarmCalls += 1
        if let prewarmError { throw prewarmError }
    }

    func load() async throws {
        loadCalls += 1
        if let loadError { throw loadError }
    }

    func unload() async {
        unloadCalls += 1
    }

    func transcribe(audioArray: [Float], decodeOptions: DecodingOptions) async throws -> [TranscriptionResult] {
        []
    }
}

@MainActor
private final class FakeAudioCapture: AudioCapturing {
    var onAudioBuffer: (@Sendable (Data) -> Void)?
    var onMicLevel: (@Sendable (Float) -> Void)?
    var micBoost: Float = 1
    var voiceIsolation = false
    var permissionRequests = 0
    var startCalls = 0
    var stopCalls = 0
    var startError: Error?

    func requestPermission() async throws {
        permissionRequests += 1
    }

    func start() throws {
        startCalls += 1
        if let startError { throw startError }
    }

    func stop() {
        stopCalls += 1
    }

    func getAvailableInputs() -> [AudioInputSource] { [] }
    func getCurrentInput() -> AudioInputSource? { nil }
    func setInput(_ source: AudioInputSource) throws {}
}

private enum ModelFixture {
    static func writeModel(to root: URL, model: SpeechModel) throws {
        let folder = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.name)")
        let files = [
            "config.json", "generation_config.json",
            "MelSpectrogram.mlmodelc/coremldata.bin", "MelSpectrogram.mlmodelc/model.mil",
            "AudioEncoder.mlmodelc/coremldata.bin", "AudioEncoder.mlmodelc/model.mil",
            "TextDecoder.mlmodelc/coremldata.bin", "TextDecoder.mlmodelc/model.mil",
            "AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/weights/weight.bin"
        ]
        for path in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let contents = path.hasSuffix(".json") ? Data("{\"fixture\":true}".utf8) : Data("fixture".utf8)
            try contents.write(to: url)
        }
    }

    static func writeTokenizer(to root: URL, model: SpeechModel) throws {
        let folder = root.appendingPathComponent("models/\(model.tokenizerRepository)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"model\":{}}".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer_config.json"))
    }
}

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root)
}

private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

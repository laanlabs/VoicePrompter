import Foundation
import CryptoKit

nonisolated enum SpeechModel: String, Sendable {
    case tiny, base

    var name: String { "openai_whisper-\(rawValue).en" }
    var tokenizerRepository: String { "openai/whisper-\(rawValue).en" }

    // The upstream tiny.en snapshot includes both compiled models and packages.
    // Include those files and the tokenizer in the disclosure.
    var estimatedDownloadSize: String { self == .tiny ? "~160 MB" : "~150 MB" }

    static func recommended(defaultModel: String, physicalMemory: UInt64) -> SpeechModel {
        defaultModel.contains("tiny") || physicalMemory <= 3 * 1_024 * 1_024 * 1_024 ? .tiny : .base
    }
}

/// Our receipt verifies the model files independently of the downloader's metadata
/// fast path. Hashing runs off the main actor before handing files to Core ML.
nonisolated struct SpeechModelCache: Sendable {
    let downloadRoot: URL
    let model: SpeechModel

    var repository: URL { downloadRoot.appendingPathComponent("models/argmaxinc/whisperkit-coreml") }
    var modelFolder: URL { repository.appendingPathComponent(model.name) }
    var tokenizerFolder: URL { downloadRoot.appendingPathComponent("models/\(model.tokenizerRepository)") }
    private var receiptURL: URL { modelFolder.appendingPathComponent(".voiceprompter-receipt.json") }
    private var legacySmallModelFolder: URL { repository.appendingPathComponent("openai_whisper-small.en") }
    private var legacySmallTokenizerFolder: URL {
        downloadRoot.appendingPathComponent("models/openai/whisper-small.en")
    }

    private struct FileRecord: Codable {
        let path: String
        let size: Int
        let sha256: String
    }

    private struct Receipt: Codable {
        let version: Int
        let files: [FileRecord]
    }

    private var requiredFiles: [String] {
        ["config.json", "generation_config.json"] +
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].flatMap {
            ["\($0).mlmodelc/coremldata.bin", "\($0).mlmodelc/model.mil"]
        } + ["AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/weights/weight.bin"]
    }

    var hasModelFiles: Bool {
        requiredFiles.allSatisfy { nonemptyFile(modelFolder.appendingPathComponent($0)) } &&
        isJSONObject(modelFolder.appendingPathComponent("config.json")) &&
        isJSONObject(modelFolder.appendingPathComponent("generation_config.json"))
    }

    var hasModelReceipt: Bool { FileManager.default.fileExists(atPath: receiptURL.path) }

    var hasTokenizer: Bool {
        isJSONObject(tokenizerFolder.appendingPathComponent("tokenizer.json"), requiredKey: "model") &&
        isJSONObject(tokenizerFolder.appendingPathComponent("tokenizer_config.json"))
    }

    func modelIsValid() throws -> Bool {
        guard hasModelFiles,
              let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.version == 1,
              Set(requiredFiles).isSubset(of: Set(receipt.files.map(\.path))) else { return false }

        for file in receipt.files {
            try Task.checkCancellation()
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else { return false }
            let url = modelFolder.appendingPathComponent(file.path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, values.fileSize == file.size,
                  try digest(url) == file.sha256 else { return false }
        }
        return true
    }

    func recordDownload() throws {
        guard hasModelFiles else { throw SpeechSetupError.incompleteDownload }
        guard let enumerator = FileManager.default.enumerator(at: modelFolder,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            throw SpeechSetupError.incompleteDownload
        }
        var files: [FileRecord] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            files.append(FileRecord(path: String(url.path.dropFirst(modelFolder.path.count + 1)),
                                    size: values.fileSize ?? 0, sha256: try digest(url)))
        }
        try JSONEncoder().encode(Receipt(version: 1, files: files)).write(to: receiptURL, options: .atomic)
    }

    func prepareStorage() throws {
        try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
        var root = downloadRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    func removeLegacyDownloads() throws {
        guard model.name != legacySmallModelFolder.lastPathComponent else { return }
        try removeIfPresent(legacySmallModelFolder)
        try removeIfPresent(
            repository.appendingPathComponent(".cache/huggingface/download/openai_whisper-small.en")
        )
        try removeIfPresent(legacySmallTokenizerFolder)
    }

    func invalidateModel() throws {
        try removeIfPresent(modelFolder)
        // Without deleting metadata too, Hub can return the same rejected files.
        try removeIfPresent(repository.appendingPathComponent(".cache/huggingface/download/\(model.name)"))
    }

    func invalidateReceipt() throws { try removeIfPresent(receiptURL) }

    func invalidateTokenizer() throws { try removeIfPresent(tokenizerFolder) }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func nonemptyFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    private func isJSONObject(_ url: URL, requiredKey: String? = nil) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return requiredKey.map { json[$0] != nil } ?? true
    }

    private func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum SpeechSetupError: LocalizedError {
    case incompleteDownload
    case modelNotLoaded
    case offline
    case insufficientStorage
    case download(String)
    case initialization(String)

    var errorDescription: String? {
        switch self {
        case .incompleteDownload: return "The speech download is incomplete. Please try again to download a fresh copy."
        case .modelNotLoaded: return "The speech model is not ready. Please try again."
        case .offline: return "Speech setup needs an internet connection. Connect to Wi-Fi or cellular data, then try again."
        case .insufficientStorage: return "There is not enough free storage to set up speech recognition. Free some space, then try again."
        case .download(let detail): return "Couldn’t download the speech files. Please check your connection and try again. \(detail)"
        case .initialization: return "Couldn’t prepare speech recognition. Tap Try Again to repair the speech download."
        }
    }

    static func isNetworkError(_ error: Error) -> Bool {
        errorChain(error).contains { $0.domain == NSURLErrorDomain && $0.code != NSURLErrorCancelled }
    }

    static func isStorageError(_ error: Error) -> Bool {
        errorChain(error).contains {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError) ||
            ($0.domain == NSPOSIXErrorDomain && $0.code == 28)
        }
    }

    private static func errorChain(_ error: Error) -> [NSError] {
        var result: [NSError] = []
        var next: NSError? = error as NSError
        while let current = next, result.count < 8 {
            result.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }
}

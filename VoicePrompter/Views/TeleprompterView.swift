//
//  TeleprompterView.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import SwiftUI

struct TeleprompterView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings = AppSettings()
    @StateObject private var voiceTrack = VoiceTrackEngine()
    
    let script: Script
    
    @State private var showingSettings = false
    @State private var isVoiceTrackActive = false
    @State private var startTime: Date?
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var showDebugPanel = false
    @State private var showDownloadConfirmation = false
    @State private var startupTask: Task<Void, Never>?
    @State private var startupID: UUID?

    private var setupError: String? {
        if case .error(let message) = voiceTrack.state { return message }
        return nil
    }

    private var showsSetup: Bool {
        voiceTrack.state == .loadingModel || setupError != nil
    }

    private var scriptWords: [String] {
        MarkdownParser.tokenize(MarkdownParser.extractPlainText(from: script.content))
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                settings.backgroundColor
                    .ignoresSafeArea()
                
                // Content with word highlighting - scrollable with per-word IDs
                ScrollViewReader { proxy in
                    ScrollView {
                        // Spacer at top to allow first words to scroll to tracking position (35% from top)
                        Spacer()
                            .frame(height: geometry.size.height * 0.35)
                        
                        // Word flow layout with individual IDs for scrolling
                        WordFlowView(
                            content: script.content,
                            currentWordIndex: voiceTrack.currentWordIndex,
                            fontSize: settings.fontSize,
                            textColor: settings.textColor,
                            highlightColor: .yellow,
                            lineSpacing: settings.lineSpacing
                        )
                        .padding(.horizontal, settings.horizontalMargin)
                        .scaleEffect(x: settings.mirrorMode ? -1 : 1)
                        
                        // Spacer at bottom to allow last words to scroll to tracking position
                        Spacer()
                            .frame(height: geometry.size.height * 0.65)
                    }
                    .onChange(of: voiceTrack.currentWordIndex) { _, newIndex in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("word-\(newIndex)", anchor: UnitPoint(x: 0.5, y: 0.35))
                        }
                    }
                }

                // Tracking line indicator (35% from top)
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 2)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.35)
                
                // Overlay controls
                VStack {
                    HStack {
                        // Status indicator
                        VoiceTrackStatusView(state: voiceTrack.state)
                        
                        Spacer()
                        
                        // Debug toggle
                        Button {
                            showDebugPanel.toggle()
                        } label: {
                            Image(systemName: "ladybug.fill")
                                .font(.title2)
                                .foregroundColor(showDebugPanel ? .green : .white.opacity(0.7))
                                .padding()
                        }
                        
                        // Settings button
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.7))
                                .padding()
                        }
                        
                        // Exit button
                        Button {
                            stopVoiceTrack()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.7))
                                .padding()
                        }
                    }
                    .padding()
                    
                    // Debug panel showing transcription and word log
                    if showDebugPanel && isVoiceTrackActive {
                        VStack(alignment: .leading, spacing: 8) {
                            // Header
                            HStack {
                                Text("🐛 DEBUG")
                                    .font(.caption.bold())
                                    .foregroundColor(.green)
                                Spacer()
                                Text("Word: \(voiceTrack.currentWordIndex)/\(voiceTrack.wordCount)")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            
                            Divider().background(Color.white.opacity(0.3))
                            
                            // Last heard
                            VStack(alignment: .leading, spacing: 2) {
                                Text("🎤 Last heard:")
                                    .font(.caption2.bold())
                                    .foregroundColor(.yellow)
                                
                                Text(voiceTrack.lastTranscription.isEmpty ? "(listening...)" : "\"\(voiceTrack.lastTranscription)\"")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                            }
                            
                            // Current script word
                            if voiceTrack.currentWordIndex < scriptWords.count {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("📍 Current word in script:")
                                        .font(.caption2.bold())
                                        .foregroundColor(.cyan)
                                    
                                    let startIdx = max(0, voiceTrack.currentWordIndex - 2)
                                    let endIdx = min(scriptWords.count, voiceTrack.currentWordIndex + 5)
                                    let contextWords = scriptWords[startIdx..<endIdx]
                                    let highlightPos = voiceTrack.currentWordIndex - startIdx
                                    
                                    HStack(spacing: 4) {
                                        ForEach(Array(contextWords.enumerated()), id: \.offset) { idx, word in
                                            Text(word)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundColor(idx == highlightPos ? .black : .white.opacity(0.7))
                                                .padding(.horizontal, idx == highlightPos ? 4 : 0)
                                                .background(idx == highlightPos ? Color.yellow : Color.clear)
                                                .cornerRadius(2)
                                        }
                                    }
                                }
                            }
                            
                            // Match debug info
                            if !voiceTrack.lastMatchDebug.isEmpty {
                                Divider().background(Color.white.opacity(0.3))
                                
                                Text("🔍 Match Info:")
                                    .font(.caption2.bold())
                                    .foregroundColor(.orange)
                                
                                Text(voiceTrack.lastMatchDebug)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineLimit(4)
                            }
                            
                            // Recent transcriptions log
                            if !voiceTrack.transcriptionLog.isEmpty {
                                Divider().background(Color.white.opacity(0.3))
                                
                                Text("📝 Recent (\(voiceTrack.transcriptionLog.count)):")
                                    .font(.caption2.bold())
                                    .foregroundColor(.purple)
                                
                                ScrollView(.vertical, showsIndicators: false) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(voiceTrack.transcriptionLog.prefix(5)) { entry in
                                            HStack(alignment: .top, spacing: 4) {
                                                Text(entry.matchedIndex != nil ? "✅" : "❌")
                                                    .font(.caption2)
                                                
                                                VStack(alignment: .leading, spacing: 0) {
                                                    Text(entry.wordsHeard.joined(separator: " "))
                                                        .font(.system(.caption2, design: .monospaced))
                                                        .foregroundColor(.white.opacity(0.9))
                                                        .lineLimit(1)
                                                    
                                                    if let idx = entry.matchedIndex {
                                                        Text("→ word #\(idx)")
                                                            .font(.system(.caption2, design: .monospaced))
                                                            .foregroundColor(.green.opacity(0.8))
                                                    }
                                                }
                                                
                                                Spacer()
                                            }
                                        }
                                    }
                                }
                                .frame(maxHeight: 100)
                            }
                        }
                        .padding()
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }
                    
                    Spacer()
                    
                    // Bottom controls
                    VStack(spacing: 16) {
                        // Elapsed time
                        HStack {
                            Spacer()
                            Text(formatTime(elapsedTime))
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.horizontal)

                        // Mic level (if enabled)
                        if settings.showMicLevel {
                            MicLevelView(level: voiceTrack.micLevel)
                                .frame(height: 4)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.bottom)
                }

                // Bottom corner controls: Mic source (left) and Play/Pause (right)
                VStack {
                    Spacer()
                    HStack {
                        // Mic source button (bottom left) - only when voice tracking is active
                        if isVoiceTrackActive, let currentInput = voiceTrack.currentInputSource {
                            Menu {
                                ForEach(voiceTrack.availableInputSources) { source in
                                    Button {
                                        voiceTrack.setInputSource(source)
                                    } label: {
                                        Label(source.name, systemImage: source.icon)
                                        if source == currentInput {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: currentInput.icon)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.blue.opacity(0.8))
                                    .clipShape(Circle())
                            }
                            .padding(.leading, 20)
                            .padding(.bottom, 30)
                        }

                        Spacer()

                        // Play/Pause button (bottom right)
                        Button {
                            if isVoiceTrackActive {
                                stopVoiceTrack()
                            } else {
                                startVoiceTrack()
                            }
                        } label: {
                            Image(systemName: isVoiceTrackActive ? "stop.fill" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(isVoiceTrackActive ? Color.red.opacity(0.8) : Color.green.opacity(0.8))
                                .clipShape(Circle())
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 30)
                    }
                }
                
                if showsSetup {
                    LoadingOverlayView(
                        service: voiceTrack.whisperService,
                        error: setupError,
                        onRetry: { beginVoiceTrack() },
                        onCancel: { stopVoiceTrack() }
                    )
                }
            }
        }
        .onAppear {
            voiceTrack.loadScript(content: script.content, trackingMode: settings.trackingMode)
        }
        .onDisappear {
            stopVoiceTrack()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .alert("Download Required", isPresented: $showDownloadConfirmation) {
            Button("Download") {
                beginVoiceTrack()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("VoiceTrack needs speech recognition files for this device (\(voiceTrack.whisperService.estimatedDownloadSize)). This enables automatic script scrolling based on your voice.\n\nSetup requires an internet connection. After setup, speech recognition works offline.")
        }
    }
    
    private func startVoiceTrack() {
        // Check if model needs to be downloaded first
        if voiceTrack.whisperService.needsDownload() {
            showDownloadConfirmation = true
        } else {
            beginVoiceTrack()
        }
    }

    private func beginVoiceTrack() {
        guard startupTask == nil else { return }
        let id = UUID()
        startupID = id
        startupTask = Task {
            defer {
                if startupID == id { startupTask = nil; startupID = nil }
            }
            do {
                voiceTrack.configureAudio(micBoost: Float(settings.micBoost), voiceIsolation: settings.voiceIsolation)
                try await voiceTrack.start()
                try Task.checkCancellation()
                guard startupID == id else { return }
                isVoiceTrackActive = true
                startTime = Date()
                elapsedTime = 0
                startTimer()
            } catch {
                // The engine publishes startup errors, including microphone failures.
                guard startupID == id else { return }
                isVoiceTrackActive = false
                timer?.invalidate()
                timer = nil
            }
        }
    }

    private func stopVoiceTrack() {
        startupTask?.cancel()
        startupTask = nil
        startupID = nil
        voiceTrack.stop()
        isVoiceTrackActive = false
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let start = startTime { elapsedTime = Date().timeIntervalSince(start) }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct VoiceTrackStatusView: View {
    let state: VoiceTrackState
    
    var body: some View {
        HStack(spacing: 8) {
            if case .loadingModel = state {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.7)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
            }
            
            Text(statusText)
                .font(.caption)
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.3))
        .cornerRadius(20)
    }
    
    private var statusColor: Color {
        switch state {
        case .idle:
            return .gray
        case .loadingModel:
            return .blue
        case .listening:
            return .yellow
        case .matched:
            return .green
        case .paused:
            return .orange
        case .error:
            return .red
        }
    }
    
    private var statusText: String {
        switch state {
        case .idle:
            return "Idle"
        case .loadingModel:
            return "Loading..."
        case .listening:
            return "Listening"
        case .matched:
            return "Tracking"
        case .paused:
            return "Off-script"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

// Download percentages come from the downloader. Core ML preparation has no
// reliable percentage, so it uses an indeterminate indicator and a cancel button.
struct LoadingOverlayView: View {
    @ObservedObject var service: WhisperService
    let error: String?
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(spacing: 20) {
                if let error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Couldn’t Start VoiceTrack")
                        .font(.title2.bold())
                    Text(error)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    Button("Try Again", action: onRetry)
                        .buttonStyle(.borderedProminent)
                } else {
                    if service.isDownloading {
                        ProgressView(value: service.downloadProgress)
                            .tint(.green)
                        Text("\(Int(service.downloadProgress * 100))%")
                            .monospacedDigit()
                    } else {
                        ProgressView().tint(.white).scaleEffect(1.5)
                            .padding(.vertical, 10)
                    }
                    Text(service.isLoading ? service.loadingStatus : "Starting microphone…")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    if service.isLoading && !service.loadingSubtitle.isEmpty {
                        Text(service.loadingSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                }
                Button(error == nil ? "Cancel" : "Close", action: onCancel)
                    .buttonStyle(.bordered)
            }
            .foregroundStyle(.white)
            .padding(28)
            .frame(maxWidth: 420)
            .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 20))
            .padding(20)
        }
    }
}

// Word flow layout - displays words with proper horizontal wrapping and paragraph breaks
struct WordFlowView: View {
    let content: String
    let currentWordIndex: Int
    let fontSize: Double
    let textColor: Color
    let highlightColor: Color
    let lineSpacing: Double
    
    // Use display words (capitalized, with punctuation) but split the same way as TextMatcher
    private var displayWords: [String] {
        let plainText = MarkdownParser.extractPlainText(from: content)
        return MarkdownParser.splitForDisplay(plainText)
    }
    
    // Group words into paragraphs (separated by "\n" markers)
    private var paragraphs: [[(index: Int, word: String)]] {
        var result: [[(index: Int, word: String)]] = []
        var currentParagraph: [(index: Int, word: String)] = []
        
        for (index, word) in displayWords.enumerated() {
            if word == "\n" {
                if !currentParagraph.isEmpty {
                    result.append(currentParagraph)
                    currentParagraph = []
                }
                // Add an empty entry for the line break to maintain index
                result.append([(index: index, word: "\n")])
            } else {
                currentParagraph.append((index: index, word: word))
            }
        }
        
        // Don't forget the last paragraph
        if !currentParagraph.isEmpty {
            result.append(currentParagraph)
        }
        
        return result
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.4) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { paraIndex, paragraph in
                if paragraph.count == 1 && paragraph[0].word == "\n" {
                    // This is a line break - add spacing
                    Color.clear
                        .frame(height: fontSize * 0.3)
                        .id("word-\(paragraph[0].index)")
                } else {
                    // Regular paragraph with flowing words
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: fontSize * lineSpacing * 0.5) {
                        ForEach(paragraph, id: \.index) { item in
                            WordView(
                                word: item.word,
                                isHighlighted: item.index == currentWordIndex,
                                isPast: item.index < currentWordIndex,
                                fontSize: fontSize,
                                textColor: textColor,
                                highlightColor: highlightColor
                            )
                            .id("word-\(item.index)")
                        }
                    }
                }
            }
        }
    }
}

// Individual word view with CONSISTENT sizing (no size change on highlight)
struct WordView: View {
    let word: String
    let isHighlighted: Bool
    let isPast: Bool
    let fontSize: Double
    let textColor: Color
    let highlightColor: Color
    
    var body: some View {
        Text(word)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(wordColor)
            // Use fixed padding for ALL words to prevent size changes
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isHighlighted ? highlightColor : Color.clear)
            .cornerRadius(4)
    }
    
    private var wordColor: Color {
        if isHighlighted {
            return .black
        } else if isPast {
            return textColor.opacity(0.5)
        } else {
            return textColor
        }
    }
}

// Proper flow layout using Layout protocol
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            // Wrap to next line if needed
            if currentX + size.width > containerWidth && currentX > 0 {
                currentY += lineHeight + verticalSpacing
                currentX = 0
                lineHeight = 0
            }
            
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + horizontalSpacing
            maxWidth = max(maxWidth, currentX - horizontalSpacing)
        }
        
        return CGSize(width: maxWidth, height: currentY + lineHeight)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let containerWidth = bounds.width
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            // Wrap to next line if needed
            if currentX + size.width > containerWidth && currentX > 0 {
                currentY += lineHeight + verticalSpacing
                currentX = 0
                lineHeight = 0
            }
            
            subview.place(
                at: CGPoint(x: bounds.minX + currentX, y: bounds.minY + currentY),
                proposal: ProposedViewSize(size)
            )
            
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + horizontalSpacing
        }
    }
}

struct MicLevelView: View {
    let level: Float
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                
                Rectangle()
                    .fill(Color.green)
                    .frame(width: geometry.size.width * CGFloat(level))
            }
        }
        .cornerRadius(2)
    }
}

#Preview {
    TeleprompterView(script: Script(title: "Test", content: "# Hello\n\nThis is a test script with some words to demonstrate the voice tracking feature."))
}

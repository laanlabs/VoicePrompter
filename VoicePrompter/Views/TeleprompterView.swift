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
    @State private var loadingStatusText = ""
    @State private var downloadProgress: Double = 0.0
    @State private var isDownloading: Bool = false
    @State private var showDownloadConfirmation = false
    @State private var showErrorState = false
    @State private var canRetryDownload = false

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
                        // Spacer at top to allow first words to scroll to center
                        Spacer()
                            .frame(height: geometry.size.height / 2)
                        
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
                        
                        // Spacer at bottom to allow last words to scroll to center
                        Spacer()
                            .frame(height: geometry.size.height / 2)
                    }
                    .onChange(of: voiceTrack.currentWordIndex) { _, newIndex in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("word-\(newIndex)", anchor: .center)
                        }
                    }
                }
                
                // Center line indicator
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 2)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                
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
                        // Progress and time
                        HStack {
                            if voiceTrack.wordCount > 0 {
                                Text("\(Int((Double(voiceTrack.currentWordIndex) / Double(voiceTrack.wordCount)) * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            
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
                        
                        // VoiceTrack toggle
                        Button {
                            if isVoiceTrackActive {
                                stopVoiceTrack()
                            } else {
                                startVoiceTrack()
                            }
                        } label: {
                            HStack {
                                Image(systemName: isVoiceTrackActive ? "pause.circle.fill" : "play.circle.fill")
                                Text(isVoiceTrackActive ? "Pause VoiceTrack" : "Start VoiceTrack")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .background(isVoiceTrackActive ? Color.red.opacity(0.8) : Color.green.opacity(0.8))
                            .cornerRadius(12)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom)
                }
                
                // Loading overlay
                if case .loadingModel = voiceTrack.state {
                    LoadingOverlayView(
                        status: loadingStatusText,
                        progress: downloadProgress,
                        isDownloading: isDownloading,
                        showError: showErrorState,
                        canRetry: canRetryDownload,
                        onRetry: {
                            retryDownload()
                        }
                    )
                }
            }
        }
        .onAppear {
            voiceTrack.loadScript(content: script.content)
        }
        .onReceive(voiceTrack.whisperService.$loadingStatus) { status in
            loadingStatusText = status
        }
        .onReceive(voiceTrack.whisperService.$downloadProgress) { progress in
            downloadProgress = progress
        }
        .onReceive(voiceTrack.whisperService.$isDownloading) { downloading in
            isDownloading = downloading
        }
        .onReceive(voiceTrack.whisperService.$errorMessage) { error in
            showErrorState = error != nil
        }
        .onReceive(voiceTrack.whisperService.$canRetry) { retry in
            canRetryDownload = retry
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
            Text("VoiceTrack requires a one-time download of the speech recognition model (\(WhisperService.estimatedDownloadSize)). This enables automatic script scrolling based on your voice.\n\nThe download will only happen once and requires an internet connection.")
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
        Task {
            do {
                showErrorState = false
                canRetryDownload = false
                startTime = Date()
                elapsedTime = 0
                startTimer()
                try await voiceTrack.start()
                isVoiceTrackActive = true
            } catch {
                print("Failed to start VoiceTrack: \(error)")
                // Error state will be set by onReceive handlers
            }
        }
    }

    private func retryDownload() {
        voiceTrack.whisperService.resetForRetry()
        showErrorState = false
        canRetryDownload = false
        beginVoiceTrack()
    }
    
    private func stopVoiceTrack() {
        voiceTrack.stop()
        isVoiceTrackActive = false
        timer?.invalidate()
        timer = nil
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let start = startTime {
                elapsedTime = Date().timeIntervalSince(start)
            }
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

// Loading overlay with actual status and progress bar from WhisperService
struct LoadingOverlayView: View {
    let status: String
    let progress: Double
    let isDownloading: Bool
    let showError: Bool
    let canRetry: Bool
    let onRetry: () -> Void

    @State private var dots = ""

    private var title: String {
        if showError {
            return "Download Failed"
        } else if isDownloading {
            return "Downloading Model"
        } else if status.lowercased().contains("check") {
            return "Checking for Model"
        } else if status.lowercased().contains("cache") {
            return "Loading from Cache"
        } else if status.lowercased().contains("warm") {
            return "Preparing Model"
        } else if status.lowercased().contains("retry") {
            return "Retrying Download"
        } else {
            return "Loading Speech Model"
        }
    }

    private var subtitle: String {
        if showError && canRetry {
            return "This is usually a temporary server issue"
        } else if isDownloading {
            return "First-time setup (~150MB)"
        } else if status.lowercased().contains("cache") {
            return "Using previously downloaded model"
        } else {
            return ""
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Error state indicator
                if showError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.orange)
                }
                // Animated spinner or progress indicator
                else if isDownloading {
                    // Show progress ring when downloading
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 8)
                            .frame(width: 80, height: 80)

                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.3), value: progress)

                        Text("\(Int(progress * 100))%")
                            .font(.headline.bold())
                            .foregroundColor(.white)
                    }
                } else {
                    // Animated spinner for checking/loading
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(2.5)
                }

                Text(title)
                    .font(.title2.bold())
                    .foregroundColor(showError ? .orange : .white)

                // Actual status message from WhisperService
                Text(status.isEmpty ? "Initializing\(dots)" : status)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 20)
                    .padding(.horizontal)

                // Subtitle info
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(showError ? .white.opacity(0.6) : .green.opacity(0.8))
                }

                // Retry button when error occurs
                if showError && canRetry {
                    Button(action: onRetry) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Try Again")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(10)
                    }
                    .padding(.top, 8)
                }

                // Progress bar for download
                if isDownloading && !showError {
                    VStack(spacing: 8) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(0.2))

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.green)
                                    .frame(width: geometry.size.width * progress)
                                    .animation(.easeInOut(duration: 0.3), value: progress)
                            }
                        }
                        .frame(height: 8)
                        .padding(.horizontal, 20)

                        Text("~150MB (one-time download)")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                    }
                } else if status.lowercased().contains("cache") && !showError {
                    Text("Using cached model - no download needed")
                        .font(.caption)
                        .foregroundColor(.green.opacity(0.7))
                }
            }
            .padding(40)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(20)
        }
        .onAppear {
            startDotsAnimation()
        }
    }

    private func startDotsAnimation() {
        // Animate dots for visual feedback
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
            dots = String(repeating: ".", count: (dots.count + 1) % 4)
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

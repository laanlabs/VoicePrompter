//
//  TextMatcher.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import Foundation

struct MatchingConfig {
    var maxFuzzyDistance: Int
    var maxSingleWordJump: Int
    var maxPhraseJump: Int
    var acceptanceThreshold: Double
    var minPhraseConfidence: Double
    var lookForwardWindow: Int

    static func forMode(_ mode: TrackingMode) -> MatchingConfig {
        switch mode {
        case .strict:
            return MatchingConfig(
                maxFuzzyDistance: 1,
                maxSingleWordJump: 2,
                maxPhraseJump: 8,
                acceptanceThreshold: 0.55,
                minPhraseConfidence: 0.75,
                lookForwardWindow: 12
            )
        case .mix:
            return MatchingConfig(
                maxFuzzyDistance: 2,
                maxSingleWordJump: 5,
                maxPhraseJump: 15,
                acceptanceThreshold: 0.4,
                minPhraseConfidence: 0.6,
                lookForwardWindow: 20
            )
        case .loose:
            return MatchingConfig(
                maxFuzzyDistance: 3,
                maxSingleWordJump: 10,
                maxPhraseJump: 30,
                acceptanceThreshold: 0.25,
                minPhraseConfidence: 0.4,
                lookForwardWindow: 35
            )
        }
    }
}

struct MatchDebugInfo {
    let transcribedWords: [String]
    let bestMatchIndex: Int?
    let bestConfidence: Double
    let searchRange: ClosedRange<Int>
    let scriptWordsInRange: [String]
    let proximityBonus: Double
}

class TextMatcher {
    private var scriptWords: [String] = []      // Normalized words for matching
    private var displayWords: [String] = []     // Original words for display (same count)
    private var currentPosition: Int = 0
    var lastDebugInfo: MatchDebugInfo?

    // Configuration (defaults to Mix mode)
    private var config = MatchingConfig.forMode(.mix)
    private let minPhraseWordsForJump = 2  // Need at least this many matching words to jump

    func configure(for mode: TrackingMode) {
        config = MatchingConfig.forMode(mode)
        print("🎛️ TextMatcher configured for \(mode.rawValue) mode")
    }
    
    func loadScript(_ plainText: String) {
        // Use consistent splitting for both display and matching
        displayWords = MarkdownParser.splitForDisplay(plainText)
        scriptWords = MarkdownParser.tokenize(plainText)
        currentPosition = 0
        
        // Verify alignment
        if displayWords.count != scriptWords.count {
            print("⚠️ Word count mismatch! Display: \(displayWords.count), Match: \(scriptWords.count)")
            // Fallback to simpler tokenization
            scriptWords = displayWords.map { $0.lowercased() }
        }
        
        print("📜 Loaded script with \(scriptWords.count) words")
        print("📜 First 10 words: \(scriptWords.prefix(10).joined(separator: ", "))")
    }
    
    /// Find best match for transcribed text in the script
    /// Uses proximity-weighted scoring to prevent jumping ahead
    func findMatch(transcribedText: String) -> Int? {
        let transcribedWords = MarkdownParser.tokenizeTranscription(transcribedText)
        guard !transcribedWords.isEmpty else {
            print("⚠️ No transcribed words to match")
            return nil
        }
        
        print("🔍 Matching transcribed words: \(transcribedWords)")
        print("🔍 Current position: \(currentPosition)")
        
        // Search window: look back a bit and forward
        let lookBack = 3
        let lookForward = config.lookForwardWindow
        let startIndex = max(0, currentPosition - lookBack)
        let endIndex = min(scriptWords.count, currentPosition + lookForward)
        
        guard startIndex < endIndex else {
            print("⚠️ Invalid search range: \(startIndex)..<\(endIndex)")
            return nil
        }
        
        let scriptWordsInRange = Array(scriptWords[startIndex..<endIndex])
        print("🔍 Searching script words [\(startIndex)...\(endIndex-1)]: \(scriptWordsInRange.prefix(10).joined(separator: ", "))...")
        
        var bestMatch: (index: Int, confidence: Double, matchedWords: Int, proximityBonus: Double)? = nil
        
        // Score each potential starting position (skip line breaks)
        for scriptIndex in startIndex..<endIndex {
            // Skip line break markers as starting positions
            if scriptWords[scriptIndex] == "\n" {
                continue
            }
            
            let result = scoreMatch(
                transcribedWords: transcribedWords,
                scriptStartIndex: scriptIndex
            )
            
            guard result.matchedWords > 0 else { continue }
            
            // Calculate proximity bonus - positions closer to current get bonus
            let distance = abs(scriptIndex - currentPosition)
            let proximityBonus = calculateProximityBonus(distance: distance, matchedWords: result.matchedWords)
            
            // Check if this jump is allowed
            let jumpDistance = scriptIndex - currentPosition
            let isAllowedJump = isJumpAllowed(
                jumpDistance: jumpDistance,
                matchedWords: result.matchedWords,
                confidence: result.confidence
            )
            
            guard isAllowedJump else {
                print("🚫 Jump to \(scriptIndex) rejected (distance: \(jumpDistance), matched: \(result.matchedWords))")
                continue
            }
            
            // Final score combines match confidence with proximity
            let finalScore = result.confidence + proximityBonus
            
            if finalScore > 0.3 {
                print("📊 Position \(scriptIndex): conf=\(String(format: "%.2f", result.confidence)), prox=\(String(format: "%.2f", proximityBonus)), final=\(String(format: "%.2f", finalScore)), words=\(result.matchedWords)")
            }
            
            if bestMatch == nil || finalScore > (bestMatch!.confidence + bestMatch!.proximityBonus) {
                bestMatch = (scriptIndex, result.confidence, result.matchedWords, proximityBonus)
            }
        }
        
        // Update debug info
        lastDebugInfo = MatchDebugInfo(
            transcribedWords: transcribedWords,
            bestMatchIndex: bestMatch?.index,
            bestConfidence: bestMatch?.confidence ?? 0.0,
            searchRange: startIndex...max(startIndex, endIndex-1),
            scriptWordsInRange: scriptWordsInRange,
            proximityBonus: bestMatch?.proximityBonus ?? 0.0
        )
        
        // Accept match if confidence + proximity is good enough
        if let match = bestMatch {
            let finalScore = match.confidence + match.proximityBonus
            if finalScore > config.acceptanceThreshold {
                print("✅ Best match at index \(match.index) (conf: \(String(format: "%.2f", match.confidence)), prox: \(String(format: "%.2f", match.proximityBonus)), words: \(match.matchedWords))")
                currentPosition = match.index + match.matchedWords
                return match.index
            }
        }
        
        print("❌ No match found above threshold")
        return nil
    }
    
    /// Calculate how well the transcribed words match at a script position
    /// Skips line break markers ("\n") when matching
    private func scoreMatch(transcribedWords: [String], scriptStartIndex: Int) -> (confidence: Double, matchedWords: Int) {
        var matchScore = 0.0
        var matchedCount = 0
        var transcribedIndex = 0
        var scriptIndex = scriptStartIndex
        
        // Match transcribed words against script words, skipping line breaks
        while transcribedIndex < transcribedWords.count && scriptIndex < scriptWords.count {
            let scriptWord = scriptWords[scriptIndex]
            
            // Skip line break markers in script
            if scriptWord == "\n" {
                scriptIndex += 1
                continue
            }
            
            let transcribedWord = transcribedWords[transcribedIndex]
            
            if transcribedWord == scriptWord {
                matchScore += 1.0
                matchedCount += 1
            } else {
                let distance = levenshteinDistance(transcribedWord, scriptWord)
                let maxLen = max(transcribedWord.count, scriptWord.count)
                if maxLen > 0 && distance <= config.maxFuzzyDistance && distance < maxLen / 2 {
                    let wordConfidence = 1.0 - (Double(distance) / Double(maxLen))
                    matchScore += wordConfidence
                    matchedCount += 1
                }
            }
            
            transcribedIndex += 1
            scriptIndex += 1
        }
        
        guard matchedCount > 0 else { return (0.0, 0) }
        
        // Normalize by number of transcribed words
        let confidence = matchScore / Double(transcribedWords.count)
        return (confidence, matchedCount)
    }
    
    /// Calculate bonus for positions close to current position
    private func calculateProximityBonus(distance: Int, matchedWords: Int) -> Double {
        // Strong bonus for being right at expected position
        if distance == 0 {
            return 0.5
        } else if distance <= 2 {
            return 0.3
        } else if distance <= 5 {
            return 0.15
        } else if distance <= 10 {
            return 0.05
        } else {
            // Penalty for being far away
            return -0.1 * Double(distance - 10) / 10.0
        }
    }
    
    /// Check if a jump of this distance is allowed given match quality
    private func isJumpAllowed(jumpDistance: Int, matchedWords: Int, confidence: Double) -> Bool {
        // Always allow backward movement (user went back)
        if jumpDistance < 0 {
            return true
        }

        // Small forward movement is always ok
        if jumpDistance <= config.maxSingleWordJump {
            return true
        }

        // Medium jump requires multiple matched words with good confidence
        if jumpDistance <= config.maxPhraseJump {
            return matchedWords >= minPhraseWordsForJump && confidence >= config.minPhraseConfidence
        }

        // Large jumps require very strong evidence
        return matchedWords >= 3 && confidence >= 0.8
    }
    
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let m = s1Array.count
        let n = s2Array.count
        
        if m == 0 { return n }
        if n == 0 { return m }
        
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        
        for i in 0...m {
            dp[i][0] = i
        }
        for j in 0...n {
            dp[0][j] = j
        }
        
        for i in 1...m {
            for j in 1...n {
                if s1Array[i - 1] == s2Array[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = min(
                        dp[i - 1][j] + 1,      // deletion
                        dp[i][j - 1] + 1,      // insertion
                        dp[i - 1][j - 1] + 1   // substitution
                    )
                }
            }
        }
        
        return dp[m][n]
    }
    
    func reset() {
        currentPosition = 0
        lastDebugInfo = nil
    }
    
    func setPosition(_ position: Int) {
        currentPosition = max(0, min(position, scriptWords.count))
    }
    
    var wordCount: Int {
        scriptWords.count
    }
    
    func getScriptWords() -> [String] {
        return scriptWords
    }
    
    func getDisplayWords() -> [String] {
        return displayWords
    }
    
    func getCurrentPosition() -> Int {
        return currentPosition
    }
}

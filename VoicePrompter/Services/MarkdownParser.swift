//
//  MarkdownParser.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import Foundation

struct MarkdownParser {
    /// Extract plain text from markdown, removing all markdown syntax
    static func extractPlainText(from markdown: String) -> String {
        var text = markdown
        
        // Remove code blocks (```...```)
        text = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
        
        // Remove inline code (`...`)
        text = text.replacingOccurrences(of: #"`[^`]+`"#, with: "", options: .regularExpression)
        
        // Remove images (![alt](url))
        text = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        
        // Extract link text only ([text](url) -> text)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        
        // Process line by line for line-start patterns
        let lines = text.components(separatedBy: .newlines)
        let processedLines = lines.map { line -> String in
            var processedLine = line
            
            // Remove heading markers (#, ##, ###)
            if let match = processedLine.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                processedLine = String(processedLine[match.upperBound...])
            }
            
            // Remove list markers (-, *, +)
            if let match = processedLine.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                processedLine = String(processedLine[match.upperBound...])
            }
            
            // Remove numbered list markers (1., 2., etc.)
            if let match = processedLine.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) {
                processedLine = String(processedLine[match.upperBound...])
            }
            
            // Remove blockquote markers (>)
            if let match = processedLine.range(of: #"^>\s*"#, options: .regularExpression) {
                processedLine = String(processedLine[match.upperBound...])
            }
            
            return processedLine
        }
        text = processedLines.joined(separator: "\n")
        
        // Remove bold/italic markers (**text** -> text, *text* -> text)
        text = text.replacingOccurrences(of: #"\*\*([^\*]+)\*\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!\*)\*([^\*]+)\*(?!\*)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!_)_([^_]+)_(?!_)"#, with: "$1", options: .regularExpression)
        
        // Clean up extra whitespace
        text = text.replacingOccurrences(of: #"\n\s*\n"#, with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return text
    }
    
    /// Split text for display, keeping original formatting but consistent word boundaries
    /// This ensures display words have the same count/index as tokenized words
    /// Uses special "\n" marker to indicate line breaks
    static func splitForDisplay(_ text: String) -> [String] {
        var result: [String] = []
        
        // Split by lines first to preserve paragraph structure
        let lines = text.components(separatedBy: .newlines)
        
        for (lineIndex, line) in lines.enumerated() {
            // Skip empty lines but add a line break marker
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty {
                // Add paragraph break marker (only if we have content before)
                if !result.isEmpty && result.last != "\n" {
                    result.append("\n")
                }
                continue
            }
            
            // Split line into words
            let words = trimmedLine
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .split(separator: " ")
                .map { String($0) }
                .filter { !$0.isEmpty }
            
            result.append(contentsOf: words)
            
            // Add line break after each non-empty line (except the last)
            if lineIndex < lines.count - 1 {
                result.append("\n")
            }
        }
        
        // Clean up: remove trailing line breaks and consecutive line breaks
        while result.last == "\n" {
            result.removeLast()
        }
        
        return result
    }
    
    /// Tokenize plain text into word array for matching
    /// Normalizes text by removing punctuation and lowercasing
    /// Keeps line break markers to maintain alignment with display words
    static func tokenize(_ text: String) -> [String] {
        // First split the same way as splitForDisplay to ensure consistent word count
        let displayWords = splitForDisplay(text)
        
        // Then normalize each word individually (keeping line break markers)
        return displayWords.map { word in
            // Keep line break markers as-is
            if word == "\n" {
                return "\n"
            }
            
            // Clean common Whisper artifacts from individual words
            var cleaned = word.lowercased()
            
            // Remove leading/trailing punctuation but keep apostrophes in middle
            cleaned = cleaned.replacingOccurrences(of: #"^[^\w']+"#, with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"[^\w']+$"#, with: "", options: .regularExpression)
            
            return cleaned
        }.filter { !$0.isEmpty }
    }
    
    /// Tokenize transcribed text (from Whisper) - more aggressive noise filtering
    static func tokenizeTranscription(_ text: String) -> [String] {
        var cleaned = text
        
        // Remove common Whisper noise/artifacts
        let noisePatterns = [
            #"^\s*\[.*?\]\s*"#,           // [music], [silence], etc.
            #"^\s*\(.*?\)\s*"#,           // (music), (silence), etc.
            #"^\s*♪.*?♪\s*"#,             // Music notes
            #"\s*\.\.\.\s*"#,             // Ellipsis
        ]
        
        for pattern in noisePatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        
        // Split and normalize
        return splitForDisplay(cleaned).map { word in
            var normalized = word.lowercased()
            normalized = normalized.replacingOccurrences(of: #"^[^\w']+"#, with: "", options: .regularExpression)
            normalized = normalized.replacingOccurrences(of: #"[^\w']+$"#, with: "", options: .regularExpression)
            return normalized
        }.filter { !$0.isEmpty && $0.count >= 1 }
    }
    
}

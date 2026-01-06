//
//  Script.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import Foundation
import SwiftData

@Model
final class Script {
    @Attribute(.unique) var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    
    @Transient var isDemo: Bool = false
    
    init(title: String = "Untitled Script", content: String = "") {
        self.id = UUID()
        self.title = title
        self.content = content
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    var wordCount: Int {
        // Extract plain text from markdown and count words
        let plainText = MarkdownParser.extractPlainText(from: content)
        return plainText.split(separator: " ").count
    }
    
    var estimatedDuration: TimeInterval {
        // Based on 150 WPM average
        let wordsPerSecond = 150.0 / 60.0
        return TimeInterval(wordCount) / wordsPerSecond
    }
}


//
//  ScriptEditorView.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import SwiftUI
import SwiftData

struct ScriptEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var settings = AppSettings()
    
    @State private var title: String
    @State private var content: String
    @State private var isNewScript: Bool
    @State private var hasUnsavedChanges: Bool = false
    
    // Track the actual script object (will be set after first save for new scripts)
    @State private var currentScript: Script?
    
    @State private var saveTask: Task<Void, Never>?
    @State private var showingDeleteConfirmation = false
    @State private var showingTeleprompter = false
    
    init(script: Script?) {
        if let script = script {
            _title = State(initialValue: script.title)
            _content = State(initialValue: script.content)
            _isNewScript = State(initialValue: false)
            _currentScript = State(initialValue: script)
        } else {
            _title = State(initialValue: "Untitled Script")
            _content = State(initialValue: "")
            _isNewScript = State(initialValue: true)
            _currentScript = State(initialValue: nil)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Title field at top
            TextField("Script Title", text: $title)
                .font(.title2.bold())
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(Color(.systemBackground))
                .onChange(of: title) { _, _ in
                    hasUnsavedChanges = true
                    if !isNewScript {
                        debouncedSave()
                    }
                }
            
            Divider()
            
            // Editor
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .padding()
                .onChange(of: content) { _, _ in
                    hasUnsavedChanges = true
                    if !isNewScript {
                        debouncedSave()
                    }
                }
            
            // Stats bar
            HStack {
                Text("\(wordCount) words")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if hasUnsavedChanges && isNewScript {
                    Text("Unsaved")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Text(formatDuration(estimatedDuration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemGray6))
        }
        .navigationTitle(isNewScript ? "New Script" : "Edit Script")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Done/Save button - prominent in top right
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saveScript()
                    dismiss()
                } label: {
                    Text("Done")
                        .fontWeight(.semibold)
                }
            }
            
            // Present button
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Save before presenting
                    if hasUnsavedChanges || isNewScript {
                        saveScript()
                    }
                    showingTeleprompter = true
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            
            // Cancel/Delete button on the left
            ToolbarItem(placement: .cancellationAction) {
                if isNewScript {
                    Button("Cancel") {
                        dismiss()
                    }
                } else {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .onDisappear {
            saveTask?.cancel()
            // Auto-save on exit if there are changes and it's not a brand new empty script
            if hasUnsavedChanges && (!isNewScript || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                saveScript()
            }
        }
        .confirmationDialog("Delete Script", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleteScript()
            }
        } message: {
            Text("Are you sure you want to delete this script? This action cannot be undone.")
        }
        .fullScreenCover(isPresented: $showingTeleprompter) {
            if let script = currentScript {
                TeleprompterView(script: script)
            } else {
                // Create temporary script for preview (shouldn't happen normally)
                let tempScript = Script(title: title, content: content)
                TeleprompterView(script: tempScript)
            }
        }
    }
    
    private var wordCount: Int {
        let plainText = MarkdownParser.extractPlainText(from: content)
        return plainText.split(separator: " ").count
    }
    
    private var estimatedDuration: TimeInterval {
        let wordsPerSecond = 150.0 / 60.0
        return TimeInterval(wordCount) / wordsPerSecond
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
    
    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            if !Task.isCancelled {
                await MainActor.run {
                    saveScript()
                }
            }
        }
    }
    
    private func saveScript() {
        if let script = currentScript {
            // Update existing script
            script.title = title
            script.content = content
            script.updatedAt = Date()
        } else {
            // Create new script ONCE
            let newScript = Script(title: title, content: content)
            modelContext.insert(newScript)
            currentScript = newScript
            isNewScript = false
        }
        
        try? modelContext.save()
        hasUnsavedChanges = false
    }
    
    private func deleteScript() {
        if let script = currentScript {
            modelContext.delete(script)
            try? modelContext.save()
            dismiss()
        }
    }
}

#Preview {
    NavigationStack {
        ScriptEditorView(script: nil)
            .modelContainer(for: Script.self, inMemory: true)
    }
}

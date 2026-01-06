//
//  ScriptListView.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import SwiftUI
import SwiftData

struct ScriptListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Script.updatedAt, order: .reverse) private var scripts: [Script]
    
    @State private var searchText = ""
    @State private var showingNewScript = false
    
    var filteredScripts: [Script] {
        if searchText.isEmpty {
            return scripts
        }
        return scripts.filter { script in
            script.title.localizedCaseInsensitiveContains(searchText) ||
            script.content.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if scripts.isEmpty {
                    List {
                        NavigationLink {
                            ScriptEditorView(script: .demo)
                        } label: {
                            ScriptDemoRowView(script: .demo)
                        }
                    }
                    .frame(maxHeight: 150.0)

                    ContentUnavailableView(
                        "No Scripts",
                        systemImage: "doc.text",
                        description: Text(searchText.isEmpty ? "Tap + to create your first script\nOr try the demo script" : "No scripts match your search")
                    )
                    .frame(maxHeight: 200.0)
                    
                    Spacer()
                    
                    
                } else if filteredScripts.isEmpty {
                    ContentUnavailableView(
                        "No Scripts",
                        systemImage: "doc.text",
                        description: Text(searchText.isEmpty ? "Tap + to create your first script" : "No scripts match your search")
                    )
                } else {
                    List {
                        ForEach(filteredScripts) { script in
                            NavigationLink {
                                ScriptEditorView(script: script)
                            } label: {
                                ScriptRowView(script: script)
                            }
                        }
                        .onDelete(perform: deleteScripts)
                    }
                }
            }
            .navigationTitle("Scripts")
            .searchable(text: $searchText, prompt: "Search scripts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewScript = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewScript) {
                NavigationStack {
                    ScriptEditorView(script: nil)
                }
            }
        }
    }
    
    private func deleteScripts(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(filteredScripts[index])
            }
        }
    }
}

struct ScriptRowView: View {
    let script: Script
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(script.title)
                .font(.headline)
            
            HStack {
                Label("\(script.wordCount) words", systemImage: "doc.text")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(formatDuration(script.estimatedDuration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

struct ScriptDemoRowView: View {
    let script: Script
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(script.title)
                    .font(.headline)
                
                Spacer()
                
                Text("DEMO")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
            }
            
            HStack {
                Label("\(script.wordCount) words", systemImage: "doc.text")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(formatDuration(script.estimatedDuration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

#Preview {
    ScriptListView()
        .modelContainer(for: Script.self, inMemory: true)
}


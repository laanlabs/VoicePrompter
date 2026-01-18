//
//  SettingsView.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings = AppSettings()
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    VStack(alignment: .leading) {
                        Text("Font Size: \(Int(settings.fontSize))pt")
                        Slider(value: $settings.fontSize, in: 18...72, step: 1)
                    }
                    
                    ColorPicker("Text Color", selection: $settings.textColor)
                    ColorPicker("Background Color", selection: $settings.backgroundColor)
                    
                    VStack(alignment: .leading) {
                        Text("Line Spacing: \(String(format: "%.1f", settings.lineSpacing))")
                        Slider(value: $settings.lineSpacing, in: 1.0...2.5, step: 0.1)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Horizontal Margin: \(Int(settings.horizontalMargin))pt")
                        Slider(value: $settings.horizontalMargin, in: 20...100, step: 5)
                    }
                    
                    Toggle("Highlight Current Line", isOn: $settings.highlightCurrentLine)
                    Toggle("Mirror Mode", isOn: $settings.mirrorMode)
                }
                
                Section("VoiceTrack") {
                    Picker("Scroll Mode", selection: $settings.scrollMode) {
                        ForEach(ScrollMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    if settings.scrollMode == .fixedSpeed {
                        VStack(alignment: .leading) {
                            Text("Scroll Speed: \(String(format: "%.1f", settings.fixedScrollSpeed)) lines/sec")
                            Slider(value: $settings.fixedScrollSpeed, in: 0.5...5.0, step: 0.1)
                        }
                    }

                    Picker("Tracking Mode", selection: $settings.trackingMode) {
                        ForEach(TrackingMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Text(settings.trackingMode.description)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Show Mic Level", isOn: $settings.showMicLevel)
                }

                Section("Microphone") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Mic Boost")
                            Spacer()
                            Text("\(String(format: "%.1f", settings.micBoost))x")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.micBoost, in: 1.0...4.0, step: 0.5)
                        Text("Increase for distant speaking. May introduce noise at high levels.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Voice Isolation", isOn: $settings.voiceIsolation)
                    Text("Reduces background noise and focuses on speech. Requires restart of VoiceTrack.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}


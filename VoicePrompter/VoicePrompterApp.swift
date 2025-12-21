//
//  VoicePrompterApp.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import SwiftUI
import SwiftData

@main
struct VoicePrompterApp: App {
    var body: some Scene {
        WindowGroup {
            ScriptListView()
        }
        .modelContainer(for: Script.self)
    }
}

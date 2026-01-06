//
//  Script+Demo.swift
//  VoicePrompter
//
//  Created by Antigravity on 1/5/26.
//

import Foundation

extension Script {
    static var demo: Script {
        let content = """
        Four score and seven years ago our fathers brought forth on this continent, a new nation, conceived in Liberty, and dedicated to the proposition that all men are created equal.

        Now we are engaged in a great civil war, testing whether that nation, or any nation so conceived and so dedicated, can long endure.
        """
        let script = Script(title: "Gettysburg Address (Demo)", content: content)
        script.isDemo = true
        return script
    }
}

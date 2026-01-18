//
//  AppSettings.swift
//  VoicePrompter
//
//  Created by jclaan on 12/21/25.
//

import SwiftUI
import Combine

enum ScrollMode: String, CaseIterable {
    case voiceTrack = "Voice Track"
    case fixedSpeed = "Fixed Speed"
    case manual = "Manual"
}

class AppSettings: ObservableObject {
    @AppStorage("fontSize") var fontSize: Double = 32
    @AppStorage("textColor") var textColorData: Data = try! JSONEncoder().encode(CodableColor.white)
    @AppStorage("backgroundColor") var backgroundColorData: Data = try! JSONEncoder().encode(CodableColor.black)
    @AppStorage("lineSpacing") var lineSpacing: Double = 1.4
    @AppStorage("horizontalMargin") var horizontalMargin: Double = 40
    @AppStorage("highlightCurrentLine") var highlightCurrentLine: Bool = true
    @AppStorage("mirrorMode") var mirrorMode: Bool = false
    @AppStorage("scrollMode") var scrollModeRaw: String = ScrollMode.voiceTrack.rawValue
    @AppStorage("fixedScrollSpeed") var fixedScrollSpeed: Double = 2.0
    @AppStorage("showMicLevel") var showMicLevel: Bool = true
    @AppStorage("micBoost") var micBoost: Double = 1.0  // 1.0 to 4.0x gain
    @AppStorage("voiceIsolation") var voiceIsolation: Bool = false
    
    var textColor: Color {
        get {
            if let codableColor = try? JSONDecoder().decode(CodableColor.self, from: textColorData) {
                return codableColor.color
            }
            return .white
        }
        set {
            textColorData = (try? JSONEncoder().encode(CodableColor(newValue))) ?? textColorData
        }
    }
    
    var backgroundColor: Color {
        get {
            if let codableColor = try? JSONDecoder().decode(CodableColor.self, from: backgroundColorData) {
                return codableColor.color
            }
            return .black
        }
        set {
            backgroundColorData = (try? JSONEncoder().encode(CodableColor(newValue))) ?? backgroundColorData
        }
    }
    
    var scrollMode: ScrollMode {
        get {
            ScrollMode(rawValue: scrollModeRaw) ?? .voiceTrack
        }
        set {
            scrollModeRaw = newValue.rawValue
        }
    }
}

// Custom Codable wrapper for Color
struct CodableColor: Codable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    
    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
    
    init(_ color: Color) {
        let uiColor = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.alpha = Double(a)
    }
    
    static let white = CodableColor(Color.white)
    static let black = CodableColor(Color.black)
}

// Color Codable extension (retroactive conformance)
extension Color: @retroactive Encodable, @retroactive Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let components = try container.decode([Double].self)
        self = Color(
            red: components[0],
            green: components[1],
            blue: components[2],
            opacity: components.count > 3 ? components[3] : 1.0
        )
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        try container.encode([Double(red), Double(green), Double(blue), Double(alpha)])
    }
}


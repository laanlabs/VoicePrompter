# VoicePrompter

<div align="center">

**A native iOS teleprompter app with voice-activated scrolling**

VoicePrompter uses on-device Whisper speech recognition to automatically scroll your script as you speak, following your natural pace and handling improvisations seamlessly.

[Features](#features) • [Requirements](#requirements) • [Building](#building) • [Usage](#usage) • [Architecture](#architecture) • [Contributing](#contributing)

</div>

---

## Overview

VoicePrompter is a professional teleprompter application for iOS that revolutionizes script reading by automatically scrolling text in sync with your speech. Unlike traditional teleprompters that require manual control or fixed-speed scrolling, VoicePrompter listens to what you're saying and intelligently tracks your position in the script.

### Key Feature

**Voice-activated scrolling** that:
- Follows your natural speaking pace
- Pauses when you improvise or go off-script
- Automatically resumes when you return to the script
- Works entirely on-device for privacy and offline use

## Features

### Core Functionality
- 🎤 **VoiceTrack Mode** - Automatic scrolling synchronized with your speech
- 📝 **Markdown Support** - Write scripts in Markdown with full formatting support
- 📱 **Native iOS Experience** - Built with SwiftUI for smooth, native performance
- 🔒 **Privacy-First** - All speech recognition happens on-device, no internet required
- 💾 **Local Storage** - Scripts saved securely on your device with SwiftData

### Display Customization
- Adjustable font size (18-72pt)
- Custom text and background colors
- Line spacing and margin controls
- Current line highlighting
- Mirror mode for teleprompter hardware
- Multiple scroll modes (VoiceTrack, Fixed Speed, Manual)

### Advanced Features
- Real-time microphone level indicator
- Progress tracking and elapsed time
- Word count and estimated reading time
- Auto-save script editor
- Search and filter scripts
- Swipe-to-delete gestures

## Requirements

- **iOS 17.0+**
- **Xcode 15.0+** (for building from source)
- **Swift 5.9+**
- Device with microphone access

## Building

### Prerequisites

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/VoicePrompter.git
   cd VoicePrompter
   ```

2. Open the project in Xcode:
   ```bash
   open VoicePrompter.xcodeproj
   ```

3. Xcode will automatically resolve Swift Package dependencies (WhisperKit)

4. Select your target device or simulator and build:
   - Press `Cmd + R` or click the Run button

### First Launch

On first launch, the app will download the WhisperKit `small-en` model (~250MB). This is a one-time download that gets cached locally for future use.

**Note:** Make sure you have a stable internet connection for the initial model download.

## Usage

### Creating a Script

1. Tap the "+" button on the Script List screen
2. Enter your script content using Markdown formatting
3. The editor auto-saves as you type
4. View word count and estimated reading time at the bottom

### Presenting with VoiceTrack

1. Open a script and tap "Present"
2. Tap the microphone button to start VoiceTrack
3. Begin reading your script naturally
4. The teleprompter will automatically scroll to match your speech
5. If you go off-script, scrolling pauses until you return to the script text

### Settings

Access settings from the Script List screen to customize:
- Font size, colors, and spacing
- Scroll mode (VoiceTrack / Fixed Speed / Manual)
- Mirror mode toggle
- Microphone level display

## Architecture

VoicePrompter follows a clean MVVM architecture with async/await for concurrent operations.

### Project Structure

```
VoicePrompter/
├── Models/
│   ├── Script.swift              # SwiftData model for scripts
│   └── AppSettings.swift         # User preferences
├── Services/
│   ├── VoiceTrackEngine.swift    # Main coordinator for voice tracking
│   ├── AudioCaptureService.swift # Microphone capture via AVAudioEngine
│   ├── WhisperService.swift      # WhisperKit integration wrapper
│   ├── TextMatcher.swift         # Fuzzy matching algorithm
│   └── MarkdownParser.swift      # Markdown parsing and rendering
├── Views/
│   ├── ScriptListView.swift      # Main script list/home screen
│   ├── ScriptEditorView.swift    # Markdown editor
│   ├── TeleprompterView.swift    # Full-screen presentation view
│   └── SettingsView.swift        # Display and behavior settings
└── VoicePrompterApp.swift        # App entry point
```

### Key Components

#### VoiceTrackEngine
The core coordinator that orchestrates audio capture, speech recognition, and text matching. It maintains the current position in the script and emits state updates for the UI.

#### AudioCaptureService
Handles real-time microphone input using AVAudioEngine, resampling to 16kHz mono for Whisper, and calculating RMS levels for the mic meter.

#### WhisperService
Wrapper around WhisperKit that manages model loading, downloading, and transcription. Uses the `small-en` model for English speech recognition.

#### TextMatcher
Implements a fuzzy matching algorithm to locate the current spoken position in the script, handling transcription errors and variations.

#### MarkdownParser
Processes Markdown content for both rendering (with formatting) and plain text extraction (for voice matching).

### Dependencies

- **WhisperKit** - On-device Whisper speech recognition
  - Repository: `https://github.com/argmaxinc/WhisperKit.git`
  - Model: `openai_whisper-small.en` (~250MB)

### System Frameworks

- `AVFoundation` - Audio session management
- `AVFAudio` - AVAudioEngine for microphone capture
- `SwiftData` - Local script persistence
- `Accelerate` - Audio level calculations

## Performance

VoicePrompter is optimized for smooth, real-time performance:

- Speech-to-scroll latency: **< 500ms**
- Scroll animation: **60 fps**
- Battery life: **≥ 45 minutes** continuous VoiceTrack use
- Script loading: **< 1 second** for scripts up to 50,000 words

## Permissions

VoicePrompter requires microphone access to enable VoiceTrack functionality. The permission prompt explains that the app uses your microphone to follow along as you speak and automatically scroll the teleprompter.

All audio processing happens entirely on-device - no audio is transmitted over the network.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

### Development Setup

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Code Style

- Follow Swift API Design Guidelines
- Use SwiftUI best practices
- Maintain MVVM architecture patterns
- Add comments for complex logic
- Keep async/await usage clear and readable

## License

[Add your license here]

## Acknowledgments

- **WhisperKit** by Argmax Inc. for the excellent on-device speech recognition framework
- **OpenAI Whisper** for the underlying speech recognition model

## Support

If you encounter any issues or have questions, please [open an issue](https://github.com/yourusername/VoicePrompter/issues) on GitHub.

---

Made with ❤️ for content creators, speakers, and performers


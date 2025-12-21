# VoicePrompter Setup Instructions

## Adding WhisperKit Package Dependency

The app requires the WhisperKit Swift Package. To add it:

1. Open `VoicePrompter.xcodeproj` in Xcode
2. Select the project in the navigator
3. Select the "VoicePrompter" target
4. Go to the "Package Dependencies" tab
5. Click the "+" button
6. Enter the package URL: `https://github.com/argmaxinc/WhisperKit.git`
7. Click "Add Package"
8. Select the latest version and click "Add Package" again

Alternatively, you can add it via the menu:
- File → Add Package Dependencies...
- Enter: `https://github.com/argmaxinc/WhisperKit.git`
- Click "Add Package"

## Project Configuration

The following has been configured:
- ✅ iOS Deployment Target: 17.0
- ✅ Microphone Permission: Added to Info.plist
- ✅ SwiftData: Configured for Script model
- ✅ SwiftUI: All views implemented

## Building and Running

1. Open the project in Xcode
2. Select a simulator or device (iOS 17.0+)
3. Build and run (⌘R)

## First Launch

On first launch, the app will:
1. Download the Whisper `small-en` model (~250MB)
2. Show download progress
3. Cache the model locally for future use

## Features Implemented

### Phase 1: Core MVP ✅
- ✅ Script data model with SwiftData
- ✅ Script List view with search and CRUD
- ✅ Script Editor with markdown support and auto-save
- ✅ Markdown parser for rendering and plain text extraction
- ✅ Teleprompter view with rendered markdown
- ✅ WhisperKit integration with model download
- ✅ Audio capture service
- ✅ Text matcher with fuzzy matching
- ✅ VoiceTrack engine coordinator
- ✅ VoiceTrack status indicator
- ✅ Settings view

### Additional Features
- ✅ Word count and estimated duration
- ✅ Progress indicator and elapsed time
- ✅ Mic level meter
- ✅ Mirror mode support
- ✅ Customizable display settings

## Notes

- The WhisperKit API may vary by version. If you encounter compilation errors, check the WhisperKit documentation for the current API.
- The app requires microphone permission on first use.
- Model download requires internet connection on first launch.


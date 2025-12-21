# VoicePrompter — Agent Implementation Specification

## Overview

Build a native iOS teleprompter app that automatically scrolls text in sync with the user's speech. The app uses on-device Whisper speech recognition to track spoken words and scroll the script accordingly.

**Key Feature:** Voice-activated scrolling that follows the speaker's natural pace, pauses when they improvise, and resumes when they return to the script.

---

## Technical Requirements

- **Platform:** iOS 17.0+
- **Language:** Swift 5.9+
- **UI Framework:** SwiftUI
- **Architecture:** MVVM with async/await
- **Speech Recognition:** WhisperKit (`small-en` model, ~250MB)
- **Persistence:** SwiftData
- **Script Format:** Markdown only

---

## Dependencies

### Swift Packages

| Package | URL | Purpose |
|---------|-----|---------|
| WhisperKit | `https://github.com/argmaxinc/WhisperKit.git` | On-device Whisper speech recognition |

### System Frameworks

- `AVFoundation` — Audio session management
- `AVFAudio` — AVAudioEngine for microphone capture
- `SwiftData` — Local script storage
- `Accelerate` — Audio level calculations

---

## Required Permissions

Add to `Info.plist`:

| Key | Value |
|-----|-------|
| `NSMicrophoneUsageDescription` | "VoicePrompter uses your microphone to follow along as you speak, automatically scrolling the teleprompter." |

---

## Data Models

### Script

Stored locally with SwiftData.

| Property | Type | Description |
|----------|------|-------------|
| id | UUID | Unique identifier |
| title | String | Script name |
| content | String | Markdown content |
| createdAt | Date | Creation timestamp |
| updatedAt | Date | Last modified timestamp |
| wordCount | Int | Computed from content (excluding markdown syntax) |
| estimatedDuration | TimeInterval | Based on 150 WPM average |

### AppSettings

User preferences stored in UserDefaults or AppStorage.

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| fontSize | CGFloat | 32 | Teleprompter text size (range: 18–72) |
| textColor | Color | .white | Script text color |
| backgroundColor | Color | .black | Teleprompter background |
| lineSpacing | CGFloat | 1.4 | Line height multiplier |
| horizontalMargin | CGFloat | 40 | Side padding to reduce eye movement |
| highlightCurrentLine | Bool | true | Highlight active line |
| mirrorMode | Bool | false | Flip text horizontally for beam-splitter hardware |
| scrollMode | Enum | .voiceTrack | voiceTrack, fixedSpeed, or manual |
| fixedScrollSpeed | Double | 2.0 | Lines per second (for fixed speed mode) |
| showMicLevel | Bool | true | Display microphone input meter |

---

## App Screens

### 1. Script List (Home)

The main screen showing all saved scripts.

**Features:**
- List or grid view of scripts sorted by last modified
- Display title, word count, estimated duration for each script
- Swipe to delete
- Tap to open in editor
- "Present" button to go directly to teleprompter
- Add new script button
- Search/filter scripts

### 2. Script Editor

Create and edit markdown script content.

**Features:**
- Markdown text editor
- Auto-save on changes (debounced)
- Word count display (plain text, excluding markdown syntax)
- Estimated reading time display
- "Present" button to launch teleprompter with current script
- Delete script option
- Basic markdown preview toggle (optional)

### 3. Teleprompter (Presentation Mode)

Full-screen script display with voice tracking.

**Features:**
- Full-screen rendered markdown display
- Text scrolls automatically based on voice recognition
- Current line/section highlighting
- VoiceTrack status indicator showing: listening, matched, paused (off-script), or error
- Optional microphone level meter
- Tap to pause/resume VoiceTrack
- Swipe up/down for manual scroll adjustment
- Settings gear icon for quick access to display settings
- Exit button to return to script list
- Mirror mode support (horizontal flip)
- Progress indicator (percentage or word position)
- Elapsed time display

**Markdown Rendering in Teleprompter:**
- Render headings with appropriate sizing
- Render bold, italic, and other inline formatting
- Render lists properly
- Strip or ignore code blocks, links, images (not relevant for speech)
- Extract plain text for VoiceTrack matching

**VoiceTrack Status States:**
- `idle` — Not started
- `listening` — Actively listening for speech
- `matched` — Successfully tracking speech position
- `paused` — User went off-script, waiting for return
- `error` — Recognition error occurred

### 4. Settings

Display and behavior preferences.

**Features:**
- Font size slider (18–72pt)
- Text color picker
- Background color picker
- Line spacing adjustment
- Margin width adjustment
- Toggle: highlight current line
- Toggle: mirror mode
- Toggle: show mic level
- Scroll mode picker (VoiceTrack / Fixed Speed / Manual)
- Fixed scroll speed slider (when applicable)
- About/app info

---

## Core Services

### VoiceTrackEngine

The main coordinator that ties together audio capture, speech recognition, and text matching.

**Responsibilities:**
- Load markdown content and extract plain text for matching
- Tokenize into word array
- Coordinate audio capture and Whisper transcription
- Track current position in script
- Emit state updates for UI binding
- Handle start, stop, pause, reset operations

**State Properties:**
- `state` — Current VoiceTrack status (idle/listening/matched/paused/error)
- `currentWordIndex` — Position in script word array
- `micLevel` — Current microphone input level (0.0–1.0)

**Methods:**
- `loadScript(content: String)` — Parse markdown, extract plain text, tokenize
- `start()` async throws — Begin listening and tracking
- `stop()` — Stop audio capture and recognition
- `reset()` — Return to beginning of script

### AudioCaptureService

Handles microphone input via AVAudioEngine.

**Responsibilities:**
- Configure audio session for recording
- Capture microphone audio in real-time
- Resample to 16kHz mono (required by Whisper)
- Calculate RMS level for mic meter
- Provide audio buffers via callback

**Audio Format:**
- Sample rate: 16000 Hz
- Channels: 1 (mono)
- Format: Float32
- Buffer size: ~1 second of audio

### WhisperService

Wrapper for WhisperKit integration.

**Responsibilities:**
- Download and load `small-en` model on first use
- Show download progress to user (~250MB)
- Cache model locally after download
- Transcribe audio buffers to text
- Handle model loading errors gracefully

**Model Details:**
- Model: `openai_whisper-small.en`
- Size: ~250MB
- Language: English only
- Processing: Fully on-device, no internet required after download

### TextMatcher

Fuzzy matching algorithm to find current position in script.

**Responsibilities:**
- Maintain normalized word array from script (plain text extracted from markdown)
- Match transcribed text against script words
- Use sliding window search from current position
- Calculate confidence score for matches
- Handle minor transcription errors via Levenshtein distance
- Allow slight backtracking for correction

**Matching Algorithm:**
1. Normalize transcribed text (lowercase, remove punctuation)
2. Split into word array
3. Search within window: current position ± buffer (e.g., -2 to +10 words)
4. Compare using exact match or Levenshtein distance ≤ 2
5. Return best match if confidence > threshold (e.g., 50%)
6. Return nil if no good match (user likely off-script)

### MarkdownParser

Handles markdown content processing.

**Responsibilities:**
- Parse markdown content for rendering in teleprompter
- Extract plain text (stripping markdown syntax) for VoiceTrack matching
- Map word positions between plain text and rendered markdown for scroll synchronization
- Handle headings, bold, italic, lists, blockquotes
- Ignore/strip code blocks, links, images

---

## Markdown Support Details

### Supported Markdown Elements

| Element | Rendering | Voice Matching |
|---------|-----------|----------------|
| Headings (#, ##, ###) | Larger/bold text | Include text, ignore # symbols |
| Bold (**text**) | Bold styling | Include text only |
| Italic (*text*) | Italic styling | Include text only |
| Lists (-, *, 1.) | Bulleted/numbered display | Include text, ignore markers |
| Blockquotes (>) | Indented/styled | Include text, ignore > |
| Paragraphs | Normal text blocks | Include all text |
| Code blocks (```) | Skip/hide | Exclude from matching |
| Inline code (`code`) | Skip/hide | Exclude from matching |
| Links ([text](url)) | Show text only | Include link text only |
| Images (![alt](url)) | Skip/hide | Exclude from matching |

### Position Mapping

When VoiceTrack identifies a word position in the plain text, the app must map that position back to the corresponding location in the rendered markdown view for accurate scrolling.

---

## UI/UX Guidelines

### Teleprompter Display

- Default to dark background with white text (reduces eye strain)
- Large, readable font by default (32pt+)
- Generous line spacing for easy reading
- Narrow margins option to reduce side-to-side eye movement
- Smooth scrolling animation (target 60fps)
- Current line should remain in consistent vertical position (e.g., top third of screen)
- Subtle highlight on current line/paragraph
- Markdown formatting should enhance readability (headings stand out, etc.)

### VoiceTrack Feedback

- Clear visual indicator of current state
- Green = actively matched and tracking
- Yellow/Orange = listening but not matched (off-script)
- Mic level meter should be subtle, not distracting
- Provide haptic feedback on state changes (optional)

### Error Handling

- If Whisper model fails to load, offer retry or fallback to manual mode
- If microphone permission denied, show clear instructions
- If recognition consistently fails, suggest checking microphone or environment

---

## Performance Targets

| Metric | Target |
|--------|--------|
| Speech-to-scroll latency | < 500ms |
| App launch to ready | < 3 seconds |
| Script loading | < 1 second (up to 50,000 words) |
| Scroll animation | 60 fps |
| Battery life | ≥ 45 minutes continuous VoiceTrack |

---

## Implementation Phases

### Phase 1: Core MVP

1. Set up Xcode project with SwiftUI and SwiftData
2. Implement Script data model and basic CRUD
3. Build Script List view
4. Build Script Editor view with markdown input and auto-save
5. Implement MarkdownParser for rendering and plain text extraction
6. Build basic Teleprompter view with rendered markdown and manual scrolling
7. Integrate WhisperKit with model download and progress UI
8. Implement AudioCaptureService
9. Implement TextMatcher
10. Build VoiceTrackEngine coordinator
11. Connect VoiceTrack to Teleprompter scrolling with position mapping
12. Add VoiceTrack status indicator

### Phase 2: Polish

1. Add display customization settings
2. Implement Settings view
3. Add mirror mode
4. Add fixed-speed scroll mode
5. Add mic level meter
6. Add progress indicator and timer
7. Polish animations and transitions
8. Add markdown preview toggle in editor (optional)

### Phase 3: Final

1. Handle edge cases and error states
2. Optimize performance and battery
3. Test on various devices (iPhone 12+, iPads)
4. Prepare App Store assets
5. Submit to App Store

---

## Testing Considerations

- Test VoiceTrack with various accents and speaking speeds
- Test in noisy environments
- Test with long scripts (10,000+ words)
- Test mirror mode with actual teleprompter hardware
- Test offline functionality
- Test model download interruption and resume
- Memory usage during long sessions
- Verify markdown rendering matches word position mapping

---

## Notes for Implementation

1. **Model Download:** The Whisper `small-en` model is ~250MB. Download on first launch with progress UI. Cache locally so subsequent launches are instant.

2. **Audio Pipeline:** Use a circular buffer or sliding window approach for audio. Process chunks of ~1-3 seconds for best latency/accuracy tradeoff.

3. **Scroll Behavior:** When VoiceTrack finds a match, animate scroll smoothly to position the matched text at a consistent location (e.g., top third of screen). Don't jump abruptly.

4. **Off-Script Handling:** When user improvises, hold position and keep listening. As soon as you detect words matching the script again, resume tracking. This is a key differentiator.

5. **Battery Optimization:** Consider reducing Whisper inference frequency if user is speaking slowly. Use efficient audio processing with Accelerate framework.

6. **Markdown Position Sync:** Maintain a mapping between plain text word indices and rendered markdown view positions. This is critical for accurate scrolling when a match is found.

7. **Accessibility:** Support Dynamic Type in non-teleprompter screens. VoiceOver for navigation. High contrast mode option.
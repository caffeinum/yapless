# Voice-to-Text Project Context

## Project Overview
Lightweight voice-to-text CLI tool for macOS with nice animations, triggered via Raycast.

## Tech Decisions Made
- **Language**: Swift (native macOS integration)
- **Whisper**: Embedded library (whisper.cpp, not CLI subprocess)
- **Animation**: Configurable via JSON config (orb, waveform, glow, cursor styles)
- **Architecture**: Single binary (spawned by Raycast each time)

## Current State
- Project structure created at `~/Github/caffeinum/voice-to-text`
- Git initialized, needs to be pushed to GitHub
- Builds successfully with `make setup`
- Recording works with visual orb animation
- **Stop mechanism added**: Click anywhere or press Escape/Enter/Space to stop

## Key Files
```
Sources/VoiceToText/
├── main.swift              # CLI entry with ArgumentParser
├── AppController.swift     # Orchestrates recording/transcription/UI
├── OutputHandler.swift     # Clipboard/paste (uses UserNotifications)
├── Config/Config.swift     # JSON config for all settings
├── Audio/AudioCapture.swift # AVAudioEngine recording
├── Whisper/WhisperEngine.swift # Placeholder for whisper.cpp
└── Overlay/
    ├── OverlayWindow.swift      # Transparent window + event monitors
    ├── OrbAnimationView.swift   # Breathing orb animation
    ├── WaveformAnimationView.swift # Audio waveform viz
    └── GlowAnimationView.swift  # Screen edge glow
```

## Config File Location
`~/.config/voice-to-text/config.json`

## Build Commands
```bash
make setup      # Full setup: build, install, download model, raycast
make install    # Build and install to ~/.local/bin
make release    # Build release binary only
```

## Run Commands
```bash
voice-to-text -r              # Start recording immediately
voice-to-text -r --animation-style waveform  # Use waveform animation
```

## Next Steps / TODOs
1. [ ] Push to GitHub: `gh repo create caffeinum/voice-to-text --private --source=. --push`
2. [ ] Integrate actual whisper.cpp (currently placeholder)
3. [ ] Add voice activity detection (auto-stop on silence)
4. [ ] Test Raycast integration
5. [ ] Add cursor-following animation style
6. [ ] Consider adding haptic feedback

## Issues Fixed
- Removed `@main` attribute (was conflicting with top-level code)
- Replaced `CADisplayLink` with `Timer` (CADisplayLink requires macOS 14+)
- Replaced deprecated `NSUserNotification` with `UserNotifications` framework
- Added click/keyboard stop mechanism (was recording indefinitely)

## Environment Notes
- Claude runs in Ubuntu 22.04 VM (can't run Swift)
- Build/run must be done on user's Mac
- `gh` CLI not available in VM (proxy blocks GitHub releases)

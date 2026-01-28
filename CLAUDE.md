# yapless

swift macos voice-to-text app with visual overlay animations.

## architecture

```
Sources/VoiceToText/
├── main.swift              # cli entry point (ArgumentParser)
├── AppController.swift     # orchestrates recording → transcription → paste
├── Audio/
│   └── AudioCapture.swift  # AVAudioEngine recording, FFT spectrum, chunk extraction
├── Whisper/
│   └── WhisperEngine.swift # groq api, local whisper backends, retry logic
├── ChunkTranscriber.swift  # background 15s chunk transcription (safety net)
├── OutputHandler.swift     # clipboard, paste simulation, notifications
├── Config/
│   └── Config.swift        # json config, storage paths
└── Overlay/
    └── OverlayWindow.swift # transparent window, event tap, keyboard capture
```

## key behaviors

- audio writes directly to `~/.local/share/yapless/recordings/` (not /tmp)
- transcriptions save to `~/.local/share/yapless/transcriptions/`
- draft chunks save to `~/.local/share/yapless/drafts/` (requires GROQ_API_KEY)
- config at `~/.config/yapless/config.json`

## recording flow

1. start: overlay captures all keyboard/mouse events
2. stop (click/space/enter): releases recording, shows processing state
3. processing: releases keyboard/mouse control, keeps overlay visible, Esc cancels
4. complete: pastes text, exits

## transcription backends

priority: groq api (if GROQ_API_KEY) → local whisper → whisper-cpp → whisperkit

## safety net features

- audio saved immediately to permanent location (survives crashes)
- 15s chunk transcription during recording (draft preserved if final fails)
- 3 retries with exponential backoff for final transcription
- Esc during processing cancels but keeps audio + draft

## gotchas

- chunk transcription only works with groq (needs api key)
- event tap requires accessibility permission
- XCTest doesn't work with swift package manager on this project (pre-existing issue)

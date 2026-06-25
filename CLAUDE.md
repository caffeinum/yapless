# yapless

swift macos voice-to-text app with visual overlay animations.

## architecture

```
Sources/VoiceToText/
├── main.swift              # cli entry point (ArgumentParser)
├── AppController.swift     # orchestrates recording → transcription → paste
├── Audio/
│   └── AudioCapture.swift  # AVAudioEngine recording, FFT spectrum
├── Whisper/
│   └── WhisperEngine.swift # groq api, local whisper backends, retry logic
├── OutputHandler.swift     # clipboard, paste simulation, notifications
├── Config/
│   └── Config.swift        # json config, storage paths
└── Overlay/
    └── OverlayWindow.swift # transparent window, event tap, keyboard capture
```

## key behaviors

- audio writes directly to `~/.local/share/yapless/recordings/` (not /tmp)
- transcriptions save to `~/.local/share/yapless/transcriptions/`
- config at `~/.config/yapless/config.json`

## recording flow

1. start: overlay captures all keyboard/mouse events
2. stop (click/space/enter): releases recording, shows processing state
3. processing: releases keyboard/mouse control, keeps overlay visible, Esc cancels
4. complete: pastes text, exits

## transcription backends

`WhisperEngine` builds an ordered **fallback chain** at init (`providers: [WhisperVariant]`) and walks it until one succeeds:

- `auto`: groq (if key) → replicate (if token) → first local whisper found
- `groq`: groq (if key) → local
- `replicate`: replicate (if token) → local
- `local`/`openai`: local only (openai api not wired up yet, `.openai` == local)

local order: openai-whisper → whisper-cpp → whisperkit (first binary found wins).

cloud backends (groq, replicate) are retried 3× with exponential backoff (transient net/api errors); local backends are tried once each. if a cloud provider's key is missing OR the api fails (down, overdue billing, rate limit), it automatically falls through to the next link — no manual switch needed.

**replicate**: uses `vaibhavs10/incredibly-fast-whisper` (pinned version). audio is sent inline as a base64 `data:` URI (no upload step), then the prediction is polled until terminal (~3 min cap). token from `config.whisper.replicateApiToken` or `REPLICATE_API_TOKEN` env.

**groq**: `whisper-large-v3`. key from `config.whisper.groqApiKey` or `GROQ_API_KEY` env.

override the config backend per-run with `--backend auto|groq|replicate|local`.

## safety net features

- audio saved immediately to permanent location (survives crashes)
- 3 retries with exponential backoff on groq, then auto-fallback to local whisper
- Esc during processing cancels but keeps audio file

## animation styles

- `dot` (default): system cursor is hidden, replaced by a black dot that pulses with audio volume. blue while transcribing, green on complete, red on error. fullscreen transparent overlay.
- `glow`, `siri`: also fullscreen
- `orb`, `waveform`: small windowed
- `cursor`: orb that follows cursor

animation `AnimationState` enum: `.recording` / `.processing` / `.complete` / `.error`. error display is held ~1.2s before close. dot mode keeps cursor hidden through completion/error — only deinit unhides.

## gotchas

- event tap requires accessibility permission
- **mic permission**: `AVCaptureDevice.requestAccess` is called from `AppController.startRecording`. CLI binaries get silent denial unless granted in System Settings → Privacy & Security → Microphone. without it, AVAudioEngine returns zero buffers with no error.
- **AVAudioEngine + device binding**: AVAudioEngine.inputNode doesn't reliably follow the system default input. we explicitly bind it via CoreAudio `kAudioOutputUnitProperty_CurrentDevice` on the inputNode's AUHAL after creating the engine. without this, capture can silently land on a stale/virtual device.
- **WAV header**: `AVAudioFile` only finalizes the WAV header (audio-bytes field, etc.) on deinit. `stopRecording` must drop the `audioFile` reference before handing the URL to transcription — otherwise the file has 176KB of PCM but a header claiming 0 bytes, and Whisper hallucinates "you" from the silence.
- diagnostic logging in AudioCapture prints `Audio stats: N buffers, peak=X, avgRMS=Y` every ~1s; peak=0 means the mic is silent (perms or routing).
- XCTest doesn't work with swift package manager on this project (pre-existing issue)
- config was renamed from `~/.config/voice-to-text/` to `~/.config/yapless/` - migrate manually if needed

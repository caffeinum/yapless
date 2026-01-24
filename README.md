# Voice to Text

Lightweight voice-to-text for macOS with beautiful animations. No dock icon, no menu bar clutter – just pure voice input activated via Raycast.

## Features

- 🎤 **Local Whisper processing** - All transcription happens on-device using whisper.cpp
- ✨ **Beautiful animations** - Choose from orb, waveform, or screen edge glow effects
- 🚀 **Fast startup** - Under 200ms from trigger to recording
- 🔒 **Privacy-first** - No data leaves your machine
- ⌨️ **Raycast integration** - Quick activation with customizable hotkey

## Installation

### Prerequisites

1. Install whisper.cpp:
```bash
brew install whisper-cpp
```

2. Download a Whisper model:
```bash
mkdir -p ~/.local/share/whisper
cd ~/.local/share/whisper
curl -LO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

### Build from source

```bash
git clone https://github.com/caffeinum/voice-to-text.git
cd voice-to-text
swift build -c release
cp .build/release/voice-to-text ~/.local/bin/
```

### Raycast Setup

1. Open Raycast
2. Go to Extensions → Script Commands
3. Add the `raycast/` folder from this repo
4. Assign a hotkey (e.g., `⌥ + Space`)

## Usage

```bash
# Start recording (default: paste to active app)
voice-to-text --record --paste

# Copy to clipboard only
voice-to-text --record --clipboard --no-paste

# Use a specific animation style
voice-to-text --record --animation-style waveform

# Use a different Whisper model
voice-to-text --record --model small
```

## Configuration

Create `~/.config/voice-to-text/config.json`:

```json
{
  "animation": {
    "style": "orb",
    "primaryColor": "#007AFF",
    "secondaryColor": "#5856D6",
    "opacity": 0.9,
    "size": 120,
    "position": "center"
  },
  "whisper": {
    "model": "base",
    "language": null,
    "vadEnabled": true
  },
  "output": {
    "copyToClipboard": true,
    "pasteToActiveApp": true,
    "playCompletionSound": true
  }
}
```

### Animation Styles

| Style | Description |
|-------|-------------|
| `orb` | Simple breathing orb that pulses with audio levels |
| `waveform` | Real-time audio waveform visualization |
| `glow` | Screen edge glow effect (Dynamic Island style) |
| `cursor` | Small indicator that follows the cursor |

### Whisper Models

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| `tiny` | 75 MB | Fastest | Basic |
| `base` | 142 MB | Fast | Good |
| `small` | 466 MB | Medium | Better |
| `medium` | 1.5 GB | Slow | Great |
| `large` | 2.9 GB | Slowest | Best |

## Performance

- Startup to recording: < 200ms
- Idle memory: < 20MB
- Recording memory: < 100MB (excluding Whisper model)
- Transcription: Real-time or faster on Apple Silicon

## License

MIT

# yapless

voice-to-text that stays out of your way.

no menu bar icon. no dock clutter. no background daemon to babysit. just hit a hotkey, talk, and text appears in your active app.

## why yapless

most voice tools want to live in your system tray 24/7. they want windows, preferences panes, and "is it running?" anxiety.

yapless is different:
- **zero ui** - no icons, no windows, nothing to manage
- **instant-on** - works the first time, every time (just needs mic access once)
- **visual feedback** - animated overlay so you know it's listening
- **then it's gone** - transcribes, pastes, exits

open source alternative to superwhisper, wispr flow, and macwhisper.

## install

```bash
# clone and build
git clone https://github.com/caffeinum/yapless.git
cd yapless
swift build -c release
cp .build/release/yapless ~/.local/bin/

# add raycast script command
# Extensions → Script Commands → Add the raycast/ folder
# assign a hotkey (e.g., ⌥ + Space)
```

## backends

yapless auto-detects what you have:

| backend | setup | speed |
|---------|-------|-------|
| **groq** (cloud) | set `GROQ_API_KEY` | fastest |
| **whisper.cpp** (local) | `brew install whisper-cpp` | fast |
| **openai-whisper** (local) | `pip install openai-whisper` | medium |
| **whisperkit** (local) | apple native | medium |

groq is recommended - free tier, fast, accurate. local options for offline/privacy.

## usage

```bash
# start recording, paste to active app
yapless --record --paste

# clipboard only
yapless --record --clipboard --no-paste

# different animation
yapless --record --animation-style waveform
```

## config

`~/.config/yapless/config.json`:

```json
{
  "animation": {
    "style": "orb",
    "position": "center"
  },
  "whisper": {
    "backend": "auto",
    "model": "base",
    "language": null
  },
  "output": {
    "pasteToActiveApp": true,
    "copyToClipboard": true
  }
}
```

### animations

| style | description |
|-------|-------------|
| `orb` | breathing orb that pulses with audio |
| `waveform` | real-time audio visualization |
| `glow` | screen edge glow (dynamic island vibes) |

## how it works

1. raycast triggers `yapless --record`
2. overlay appears, recording starts
3. you talk
4. click overlay or hit hotkey again to stop
5. audio goes to whisper (cloud or local)
6. text pastes into your active app
7. yapless exits

no daemon. no persistence. summoned when needed, gone when done.

## license

MIT

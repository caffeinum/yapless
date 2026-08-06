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

- `auto`: groq → deepinfra → fireworks → replicate → fal (each if credentialed) → first local whisper found
- `groq`/`deepinfra`/`fireworks`/`fal`/`replicate`: that provider (if credentialed) → local
- `local`/`openai`: local only (openai api not wired up yet, `.openai` == local)

local order: openai-whisper → whisper-cpp → whisperkit (first binary found wins).

cloud backends are retried 3× with exponential backoff (transient net/api errors); local backends are tried once each. if a cloud provider's key is missing OR the api fails (down, overdue billing, rate limit), it automatically falls through to the next link — no manual switch needed. `isCloudVariant()` gates the retry behavior.

all models are **whisper-large / v3** (not turbo), chosen for accuracy:

| provider | model | endpoint | shape | credential |
|---|---|---|---|---|
| groq | `whisper-large-v3` | `api.groq.com/openai/v1/audio/transcriptions` | OpenAI multipart | `groqApiKey` / `GROQ_API_KEY` |
| deepinfra | `openai/whisper-large-v3` | `api.deepinfra.com/v1/openai/audio/transcriptions` | OpenAI multipart | `deepInfraApiKey` / `DEEPINFRA_API_KEY` |
| fireworks | `whisper-v3` | `audio-prod.us-virginia-1.direct.fireworks.ai/v1/audio/transcriptions` | OpenAI multipart | `fireworksApiKey` / `FIREWORKS_API_KEY` |
| fal | wizper `version:"3"` | `fal.run/fal-ai/wizper` | JSON, `audio_url` data URI, `Authorization: Key` | `falApiKey` / `FAL_KEY` |
| replicate | `incredibly-fast-whisper` | `api.replicate.com/v1/predictions` | create+poll, `audio` data URI | `replicateApiToken` / `REPLICATE_API_TOKEN` |

groq/deepinfra/fireworks share `transcribeOpenAICompatible(endpoint:apiKey:model:)` — they differ only by base URL, key, and model name. fal & replicate upload audio inline as base64 `data:` URIs (no separate upload step).

override the config backend per-run with `--backend auto|groq|deepinfra|fireworks|fal|replicate|local`.

## vocabulary / initial prompt

`whisper.vocabulary` (array) and `whisper.prompt` (string) become whisper's **initial prompt** — the sentence the decoder conditions on, which biases spelling toward those words. built in `WhisperEngine.initialPrompt`, sent as the `prompt` multipart field to groq/deepinfra/fireworks, `--initial_prompt` to openai-whisper, `--prompt` to whisper-cpp. **not** supported by replicate (incredibly-fast-whisper takes no prompt), fal, or whisperkit — those silently ignore it.

## detached runs

`--detach` re-spawns the binary via `posix_spawn` with `POSIX_SPAWN_SETSID` (own session) and exits immediately, so a launcher that times out — Raycast kills a script command at 60s — can't take the recording down with it. child stdio goes to `~/.local/share/yapless/detached.log`, not the launcher's pipes: writing to a closed pipe would SIGPIPE the run mid-transcription (observed). `raycast/*.sh` use it.

## silence guard

`audio.minVoicedSeconds` (default 0.4) + `audio.silenceFloor` (default 0.01 raw RMS): a recording with less than that much voice-level audio is **refused before transcription** — nothing transcribed, nothing pasted, nothing sent to `output.command`. 0 disables it.

Why here and not in a text filter: whisper invents well-formed sentences from silence ("Thank you for watching!"). Nothing downstream can tell that from speech — the only evidence is the flat audio underneath, which only yapless can see.

Why duration and not level: measured over 527 recordings, **peak level does not separate** (hallucinations reach peak 0.168, real dictations go down to 0.039 — including a 59s genuine one at 0.057). Voiced *duration* does, because hallucinations come from brief noise bursts. 0.01/0.4s catches 13/30 hallucinations and refuses 1/157 real dictations; 0.02/0.2s catches 28/30 and refuses 4/157.

Two constraints, both deliberate:
- **Record path only.** `--transcribe` never reaches it, so naming a recording explicitly always overrides the heuristic — that's also the documented recovery, since the wav is saved before transcription.
- **Refusals announce themselves** (sound + overlay error + log). An invisible refusal is indistinguishable from a bug and would survive for weeks.

`audioCapture.voicedSeconds` is logged on every run, accepted or not, so the threshold can be re-tuned from real data. Note `calculateRMS` returns a *display* level (`rms * 5`); the guard uses raw RMS.

## output sink

`output.command` (config) / `--output-command` (CLI) hands the final transcript to a shell command **on stdin** — never argv or env, because dictation contains quotes and newlines and argv is visible in `ps`. `YAPLESS_TRANSCRIPT_LENGTH` is set for cheap sanity checks. It is **additive**: clipboard and paste still happen, so the transcript can land in the editor *and* go somewhere else.

yapless exits right after output, so `OutputHandler.runOutputCommand` **waits** on the child up to `output.commandTimeout` (default 5s) and kills it past that — a sink that spawns and forgets would die mid-flight. Paste runs first so typing stays instant; only the exit waits. `--transcribe` feeds the sink too, otherwise whether it fires would depend on which entry point you used.

Nothing about any particular destination lives in yapless: point it at a script.

When a sink is set, `OverlayWindow.setSinkLabel` shows the destination while recording (`→ paw dm voice`, executable basename + args, `-` stripped). Which hotkey you pressed is not something anyone recalls mid-sentence, and the difference between "typed here" and "sent to an agent" matters.

`--paste`/`--no-paste` and `--clipboard`/`--no-clipboard` are `Bool?`: nil means unspecified, so config stays authoritative unless a flag is actually present. They were previously declared but **never applied to the record path**, and `paste` had no `inversion`, so `--no-paste` failed to parse at all — which silently broke any launcher script using it.

## safety net features

- audio saved immediately to permanent location (survives crashes)
- 3 retries with exponential backoff on groq, then auto-fallback to local whisper
- Esc during processing cancels but keeps audio file

## animation styles

- `dot` (default): system cursor is hidden, replaced by a black dot that pulses with audio volume. blue while transcribing, green on complete, red on error. fullscreen transparent overlay.
- `glow`, `siri`: also fullscreen
- `orb`, `waveform`: small windowed
- `cursor`: orb that follows cursor
- `pill` / `equalizer`: same floating white capsule, two readings of the voice. `pill` = 29 bars of **scrolling loudness** (`AnimationModel.levelHistory`, ~1.7s sampled every 35ms, oldest left / live right). `equalizer` = 15 **fixed frequency bands** that rise and fall in place, no scrolling, one bar per FFT band, gated by overall level so room noise doesn't draw a full display. `PillMode` picks between them; `animation.shellColor` sets the capsule fill (dark values flip the rim from shaded to lit, giving the terminal look); everything else (capsule, shadow margin, colors, states) is shared. small windowed — `OverlayWindow.calculateFrame` gives it a wide capsule frame (`size * 2.4` × `size * 0.62`) instead of a square. bars read `AnimationModel.smoothedSpectrum` (14 FFT bands, linearly interpolated across bars), colored primary→secondary center→edge; state recolors the whole pill (blue processing sweep, green complete, red error). live color studies: `mockups/pill-equalizer.html` (open it, it mirrors the Swift geometry 1:1).

animation `AnimationState` enum: `.recording` / `.processing` / `.complete` / `.error`. error display is held ~1.2s before close. dot mode keeps cursor hidden through completion/error — only deinit unhides.

## gotchas

- event tap requires accessibility permission
- **mic permission**: `AVCaptureDevice.requestAccess` is called from `AppController.startRecording`. CLI binaries get silent denial unless granted in System Settings → Privacy & Security → Microphone. without it, AVAudioEngine returns zero buffers with no error.
- **AVAudioEngine + device binding**: `AVAudioEngine.inputNode` is bound to the **system default input** at engine init and there is no supported way to repoint it afterwards without disturbing the tap. so `--input` works by swapping `kAudioHardwarePropertyDefaultInputDevice` *before* creating the engine (`AudioCapture.swift:69-103`), then restoring it in `stopRecording` (`restoreSystemDefaultIfNeeded`). consequences: the swap is global (every app sees it) and **not crash-safe** — there's no atexit/signal handler, so a `kill -9` mid-recording leaves the user's default input changed. we do NOT use `kAudioOutputUnitProperty_CurrentDevice` anywhere despite what this file used to claim.
## input device selection

`AudioCapture.resolveInputDevice(config:)` decides which mic to open, reading properties only — nothing is opened until the engine starts. precedence:

1. `--input <query>` — explicit, wins even if bluetooth (logs a warning)
2. `config.audio.inputPriority` — an ordered **allow-list**, first present entry wins. if it's non-empty, nothing off the list is ever opened; when none are connected yapless aborts with the device list rather than falling back (so AirPods left off the list are never touched, even as system default)
3. `config.audio.inputDevice` — single device, or the literal `"default"` for the system default
4. nothing configured → the system default, exactly as macOS reports it

nothing is inferred. `config.audio.excludeInputs` (name/UID substrings) marks devices that must never be opened; if the system default is excluded, yapless **aborts and says which rule stopped it** rather than substituting a device the user never named. exclusions apply to the system-default paths only — naming a device in `inputPriority`/`inputDevice`/`--input` means you want it.

`avoidBluetoothInput` (default **false**) is a hidden escape hatch that excludes every bluetooth input without naming any. deliberately not the default: it acts on devices the user never mentioned, which is the kind of magic this config exists to replace.

matching is case-insensitive, exact name first, then substring on name or UID. `InputDeviceInfo.transportType` comes from `kAudioDevicePropertyTransportType`; `isBluetooth`/`isVirtual`/`transportLabel` derive from it and `--list-inputs` prints the transport plus a ⚠︎ on bluetooth rows.

- **bluetooth input hijack**: with no `--input` and no audio config, yapless opens whatever is the system default — if that's AirPods, starting IO forces the bidirectional bluetooth link (24kHz input stream), which degrades playback and steals the AirPods away from any iPhone/iPad using them. reading device properties (`--list-inputs`) is safe; only starting IO triggers it. there is no CoreAudio API for "never use this device for input", and `AVAudioSession` (which has `bluetoothHighQualityRecording`) is unavailable on macOS. `Config.swift` has no audio/input section, so the preference can't be persisted — `--input` is CLI-only.
- **WAV header**: `AVAudioFile` only finalizes the WAV header (audio-bytes field, etc.) on deinit. `stopRecording` must drop the `audioFile` reference before handing the URL to transcription — otherwise the file has 176KB of PCM but a header claiming 0 bytes, and Whisper hallucinates "you" from the silence.
- diagnostic logging in AudioCapture prints `Audio stats: N buffers, peak=X, avgRMS=Y` every ~1s; peak=0 means the mic is silent (perms or routing).
- XCTest doesn't work with swift package manager on this project (pre-existing issue)
- config was renamed from `~/.config/voice-to-text/` to `~/.config/yapless/` - migrate manually if needed

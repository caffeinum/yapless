# yapless

swift macos voice-to-text app with visual overlay animations.

## architecture

```
Sources/VoiceToText/
├── main.swift              # cli entry point (ArgumentParser)
├── AppController.swift     # orchestrates recording → transcription → paste
├── Audio/
│   └── AudioCapture.swift  # AUHAL capture bound to a device ID, FFT spectrum
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

- `auto`: **local whisper first** (measured faster than every cloud provider — 0.5s vs 1.2-9s wall), then groq → deepinfra → fireworks → replicate → fal (each if credentialed) as fallback
- `groq`/`deepinfra`/`fireworks`/`fal`/`replicate`: that provider (if credentialed) → local
- `local`/`openai`: local only (openai api not wired up yet, `.openai` == local)
- `parakeet`: parakeet-cli → local whisper (see below)

local order: whisper-cpp → whisperkit (first binary found wins). whisper-cpp is discovered as `whisper-cli` first — homebrew renamed the binary in 1.9.x — then the old `whisper-cpp` name. It runs on **Metal**: 0.53s wall / 0.16s cpu on a 4.2s clip, ~10x faster than the CPU-only openai-whisper it replaced (4.92s / 9.10s) and than whisperkit (5.49s / 0.91s). openai-whisper was removed; PyTorch has no MPS path for whisper, so it was always CPU.

Alternatives measured on the same clip and rejected: `parakeet-mlx` 2.42s warm (679s first run — HF download) and it verbalizes alphanumerics ("Cr two hundred twenty two" where whisper gives "CR222"); it is also English-only. Published benchmarks that rank parakeet above whisper.cpp measure warm in-process inference — yapless pays process startup on every run, which is where the difference goes. whisper.cpp 1.9.2 ships its own `parakeet-cli` on the same Metal runtime if this is worth revisiting.

### parakeet backend

`--backend parakeet` / `whisper.backend: "parakeet"` runs NVIDIA parakeet-tdt-0.6b-v3 through whisper.cpp's `parakeet-cli` (ships with whisper.cpp ≥1.9, Metal), with local whisper as fallback. Model: `ggml-parakeet-<whisper.parakeetModel>.bin` in `~/.local/share/parakeet/` (default `tdt-0.6b-v3-q8_0`, from huggingface.co/ggml-org/parakeet-GGUF), or an absolute path. A missing binary or model is announced and skipped, like a missing cloud key.

Measured 2026-11-02 against whisper large-v3 as reference, 14 saved dictations: parakeet 12.6% WER vs whisper base 15.2%. It gets proper nouns base misses (Vercel, GitHub, E2B), auto-detects Russian, and outputs nothing on silence. Costs: ~1.1s wall on short clips vs ~0.55s for base (it loads a 669MB model per run; on 85s clips it wins, 3.3s vs 7.9s), it **ignores `whisper.vocabulary`** (no prompt flag), and it sometimes spells numbers ("Thirteen seventy two"). So it's opt-in, not in `auto`. parakeet-cli is offline only — no streaming mode, and chunking an offline model wrecks WER.

### streaming research (2026-11-02, notes kept local in `experiments/streaming/`, gitignored — they quote private dictations)

For live typing into the focused field the best engine measured is **FluidAudio parakeet-unified streaming** (Swift, CoreML on the ANE): 320ms chunks show a word ~0.18s after it's spoken at 13.1% WER and ~5% of a core; 1120ms chunks give 11.8%. It is append-only (never revises), writes digits, needs 1s of silence padded at stop, and its first load compiles for 30-90s (0.2-0.5s after). Apple SpeechTranscriber (no auth prompt, model preinstalled) is 14.7% but rewrites its tail; DictationTranscriber is 18.5% and revises 55% of words. Nemotron streaming verbalizes numbers. The current LiveCaptioner is **not safe to type from**: in replays it repeated sentences, committed `[BLANK_AUDIO]`, and stalled after long pauses.

cloud backends are retried 3× with exponential backoff (transient net/api errors); local backends are tried once each. if a cloud provider's key is missing OR the api fails (down, overdue billing, rate limit), it automatically falls through to the next link — no manual switch needed. `isCloudVariant()` gates the retry behavior.

all models are **whisper-large / v3** (not turbo), chosen for accuracy:

| provider | model | endpoint | shape | credential |
|---|---|---|---|---|
| groq | `whisper-large-v3` | `api.groq.com/openai/v1/audio/transcriptions` | OpenAI multipart | `groqApiKey` / `GROQ_API_KEY` |
| deepinfra | `openai/whisper-large-v3` | `api.deepinfra.com/v1/openai/audio/transcriptions` | OpenAI multipart | `deepInfraApiKey` / `DEEPINFRA_API_KEY` |
| fireworks | `whisper-v3` | `audio-prod.us-virginia-1.direct.fireworks.ai/v1/audio/transcriptions` | OpenAI multipart | `fireworksApiKey` / `FIREWORKS_API_KEY` |
| fal | wizper `version:"3"` | `fal.run/fal-ai/wizper` | JSON, `audio_url` data URI, `Authorization: Key` | `falApiKey` / `FAL_KEY` |
| replicate | `incredibly-fast-whisper` | `api.replicate.com/v1/predictions` | create+poll, `audio` data URI | `replicateApiToken` / `REPLICATE_API_TOKEN` |
| elevenlabs | Scribe `scribe_v2` | `api.elevenlabs.io/v1/speech-to-text` | multipart, `xi-api-key`, `no_verbatim=true`, `vocabulary` → repeated `keyterms` | `elevenLabsApiKey` / `ELEVENLABS_API_KEY` |

groq/deepinfra/fireworks share `transcribeOpenAICompatible(endpoint:apiKey:model:)` — they differ only by base URL, key, and model name. fal & replicate upload audio inline as base64 `data:` URIs (no separate upload step).

override the config backend per-run with `--backend auto|groq|deepinfra|fireworks|fal|replicate|elevenlabs|local|parakeet`.

## model comparison (bench/asr)

`bench/asr/` holds a re-runnable WER/speed/RAM bench: 6 English dictation-style clips full of jargon ("2027-queue", "cotal", "groq", "AVAudioConverter", money/time) + 2 Russian, ElevenLabs TTS, each in three conditions — clean, pink noise at ~1dB SNR, and a cheap-mic chain (300-3400Hz, -20dB, 8kHz, 16kbps mp3). `gen.sh` builds it, `bench.py` runs engines (wall includes process start + model load, i.e. what yapless pays), `score.py` scores with whisper's normalizer. Measured 2026-10-13, M1 Pro 16GB, load avg 20-60. Pooled English WER % (clean / noisy / cheap), median wall per clip, max RSS:

| engine | clean | noisy | cheap | wall | RSS |
|---|---|---|---|---|---|
| whisper.cpp base (old local default) | 6.6 | **15.8** | 8.3 | 0.95s | 0.37GB |
| whisper.cpp small | 5.7 | 11.8 | 6.1 | 1.5s | 0.83GB |
| whisper.cpp large-v3-turbo q5_0 | 4.8 | 5.3 | 4.8 | 2-4s (10s cold under load) | 0.81GB |
| whisper.cpp large-v3-turbo f16 | 4.8 | 5.7 | 4.8 | 9.3s | 1.84GB |
| parakeet-tdt-0.6b-v3 q8 (`parakeet-cli`, whisper.cpp 1.9.5) | 7.0 | 7.5 | 9.2 | 1.1s | 0.73GB |
| Apple SpeechAnalyzer (`SpeechTranscriber`, in-OS) | 8.3 | 11.0 | 6.1 | 0.67s | ~0 (system daemon) |
| groq whisper-large-v3 (cloud) | 5.7 | 7.0 | 5.3 | 0.55s | — |
| groq whisper-large-v3-turbo | 5.7 | 6.1 | 5.3 | 0.38s | — |
| **ElevenLabs Scribe v2** | **4.4** | **4.8** | **3.1** | 0.96s | — |

~240 words per condition, so ±1 word ≈ ±0.4 points; the base→turbo noisy gap is real, the groq/turbo/scribe spread is a few words. Russian: everything but base/apple scored 2-4%.

What it changed: local `model` is now `large-v3-turbo-q5_0` in the operator's config (base was what actually got pasted — with `raceLocal` it won the race), live captions keep `base` via `whisper.captionModel` because turbo can't finish inside the 1s pass. Scribe v2 added as a backend: best on every condition, and `keyterms` fixed "cotal"/"groq" even at 1dB SNR where every whisper wrote "total"/"grok". Without `no_verbatim` it transcribes every "uh" and false start — wrong for dictation.

Rejected: parakeet v3 — fast but worse than turbo here, no vocabulary biasing, mangles numbers ("$4,250" → "$450"). Apple SpeechAnalyzer — zero load cost but the least accurate, no Russian (`SpeechTranscriber` has no ru-RU; only `DictationTranscriber` does). Qwen3-ASR/Canary/Granite rank well on the Open ASR leaderboard but have no ggml/Metal CLI path, so they'd pay a Python/MLX runtime start per run.

Note `whisper-cli` defaults to `-l en` and yapless passes no `-l` unless `whisper.language` is set, so local Russian dictation is decoded as English. `-l auto` costs a whole extra encoder pass (~1.2s on turbo).

## racing local against cloud

`whisper.raceLocal` (default **false**) runs the cloud chain and local whisper **at the same time** and takes whichever finishes first, instead of only reaching local after the cloud chain is exhausted.

`WhisperEngine.race` splits `providers` into cloud and local lanes and calls `walk` on each. A serial `gate` queue makes the first success win exactly once; the losing lane keeps running and its result is discarded (killing it mid-write is worse than wasting the CPU). Failure is only reported once BOTH lanes are out, so a dead cloud can't mask a working local.

Local is ~10x slower than groq, so on a healthy network the cloud always wins and this costs only CPU — it earns its keep when the network is slow or gone, which is exactly when sequential fallback hurts most. Opt-in for that reason.

## live captions

`whisper.liveCaptions` (default **false**) shows closed captions while recording: every 1.0s the last ~12s of audio is re-transcribed with local whisper-cli using `whisper.captionModel` (default `base`, not `model`) and the result feeds a fixed-size caption bar at the bottom of the screen (`CaptionWindow`, separate from the animation overlay so it works with the pill too). **Preview only** — the pasted text always comes from the full transcription at stop.

Three pieces:
- `AudioCapture.tailWAVData(seconds:)` — in-memory ring buffer of the converted 16k samples (Float32 → Int16 on append; until the AUHAL port it read `int16ChannelData` off a Float32 buffer, which is always nil, so captions never got audio). The wav on disk can't be read mid-write (header says 0 bytes until finalize), so captions read from here.
- `LiveCaptioner` — timer on a utility queue, one whisper-cli process per pass, skips a tick if the previous is still running. Requires whisper-cli; whisperKit is too slow to start per-pass, so no binary → captions silently off (logged).
- **LocalAgreement-2** in `LiveCaptioner.merge`: a word is only displayed once two consecutive passes agree on it, and the committed text is append-only — the caption never rewrites itself, it lags ~1 pass instead. The **pending tail is shown too, dimmed** — words appear near-instantly in gray and turn white once confirmed; only gray text may shift. Confirmed-word latency ≈ interval + agreement pass + ~0.5s transcribe ≈ 1.5-2.5s. The alignment tolerates up to 6 mangled words at the window's leading edge (`skip`) and up to 3 committed words that a later pass drops (`drop`) — without the drop tolerance one vanished "yes," stalled captions for the rest of the recording (measured on a real 64s dictation: 27 words committed without it, 64 with, append-only both ways).

The caption label uses `.byTruncatingHead` in a fixed frame: newest words at the right edge, old ones slide off, no reflow.

## live insertion (streaming dictation)

`output.liveInsert` (default **false**) / `--live` types words into the focused field **while you talk**, like Apple Dictation. Engine: FluidAudio (`exact: 0.17.7`, CoreML on the ANE) running `output.liveModel` (default `parakeet-unified-1120ms`; the operator picked it over 320ms on a live A/B, where 320ms garbled a sentence that 1120ms got right).

Pieces:
- `StreamingDictation` — owns one FluidAudio streaming manager per recording, fed from `AudioCapture.onConvertedBuffer` (16k mono, audio thread) through an AsyncStream. Audio before the model is loaded queues, so no words are lost to load time (0.27s warm; 10-90s the first time on a machine while CoreML compiles). A word is **committed** only once a later word follows it (the last word of a partial can be mid-token, "sc" → "screen"); committed words are append-only, and if a partial ever stops starting with them, committing stops and stop-time reconcile finishes the job. At stop it pads 1s of silence (otherwise the last word or two never decode) and `finish()`es; that text **is** the transcript — the batch engine only runs if streaming failed or came back empty.
- Startup order: `StreamingDictation` is created and started **before** `startRecordingInBackground` (so `onConvertedBuffer` never sees nil for early buffers); the focused target and caption window are attached after AppKit comes up, right before `showOverlay`. Callbacks hop to main, so wiring them after `start()` loses nothing.
- `LiveInsertion.swift` — `FocusedTarget` is captured in `beginRecording` **before** the overlay exists. `AXInserter` (set `kAXSelectedText`, every write verified by the character-count delta, since web/Electron fields often return success and do nothing) is tried first; a first failed write demotes to `KeystrokeInserter` (Unicode payload on virtual key 0, posted to the HID tap, tagged `0x7961706c` so OverlayWindow's blocking tap passes it). An active IME disables keystrokes. Any focus change stops insertion — it never types into "whatever is focused now". Nothing is ever deleted.
- At stop: an AX run that is still byte-identical gets swapped for the final text in one write; a keystroke target gets the words after the last ≥1-word anchor appended. Then clipboard, enter and `output.command` run as usual (`OutputHandler.handle(alreadyInserted:)` skips only the paste). Nothing typed live → normal paste.
- In live mode the overlay is shown with `showRecordingState(activate: false)`: yapless must not take focus from the field it's typing into. The session event tap still catches space/enter/esc. No live indicator and no caption bar while a target is being typed into — the words in the field are the feedback, and a caption bar showed them twice. The caption bar (committed white, tentative gray) only appears when there is no target and the text will be pasted at the end; which inserter is in use goes to the log only.

`--stream-file <wav>` replays a recording through the same streaming path at real-time pace and prints each commit with its timing — types nothing, opens no mic. Measured: commits land ~0.1-1s behind the audio fed; final arrives 0.24-0.36s after the stream ends.

## vocabulary / initial prompt

`whisper.vocabulary` (array) and `whisper.prompt` (string) become whisper's **initial prompt** — the sentence the decoder conditions on, which biases spelling toward those words. built in `WhisperEngine.initialPrompt`, sent as the `prompt` multipart field to groq/deepinfra/fireworks, `--prompt` to whisper-cpp. **not** supported by replicate (incredibly-fast-whisper takes no prompt), fal, or whisperkit — those silently ignore it.

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
- **mic permission**: `AVCaptureDevice.requestAccess` is called from `AppController.startRecording`. CLI binaries get silent denial unless granted in System Settings → Privacy & Security → Microphone. without it, CoreAudio still delivers buffers — all zeros, no error. agent shells under tmux are not authorized (status notDetermined, yapless refuses); a cmux workspace is, so real-audio tests run there (`cmux new-workspace --focus false --command ...`).
- **device binding — why AUHAL, not AVAudioEngine**: capture is a raw `kAudioUnitSubType_HALOutput` unit, input bus 1 enabled, output bus 0 disabled, `kAudioOutputUnitProperty_CurrentDevice` set to the chosen device's ID. the system default input is **never touched**. AVAudioEngine can't do this: on this macOS its input node captures through a private `CADefaultDeviceAggregate` built from the **system default input** + default output, and setting `CurrentDevice` on `inputNode.audioUnit` before reading the format is silently overridden — measured: it bound an aggregate containing the bluetooth default (WH-1000XM6) instead of the requested mic, and delivered zero buffers. so the old code swapped the global default before creating the engine and restored it on stop: every app saw it, a `kill -9` left it swapped, two concurrent runs could "restore" each other's swap, and it cost 300-1350ms per start on a bluetooth default.
- AUHAL won't resample on the input side: the client format is mono Float32 at the device rate; one `AVAudioConverter` per recording does → 16k (one per buffer would reset the resampler's filter state at every ~10ms slice). the IO callback only renders and queues; levels/FFT/file/tail run on `processingQueue`, which `stop` drains (plus a converter flush) before dropping the `AVAudioFile`.
- slices are ~10ms (≈94/s); `gather` collects them back into ~100ms blocks before `processAudioBuffer`, because the silence guard's per-buffer RMS (`voicedSeconds`), the level/spectrum callbacks and the stats were all tuned on the engine's ~100ms buffers — 10ms windows would count short noise bursts as voice. `First audio buffer` is logged per slice, not per block. Slices the IO thread can't render are counted and reported at stop ("audio slices dropped"), never silently lost.
## cold start

~380-430ms median from exec to first audio buffer under load avg 20-95, interleaved 8x against the older builds: AVAudioEngine + swap 827 (no swap) / 927 (swap); AUHAL alone 534 / 533; AUHAL + the reorder below 432 / 378. Earlier idle-machine figure was ~330ms. Real-run slow tail before this (detached.log): 0.6-2.0s in-process, the slowest being default-input swaps away from bluetooth headphones. Measured, not estimated — timestamp each log line relative to spawn.

Where it goes now: ~47ms process + framework + config, ~88ms first touch of AVFoundation (`AudioCapture.init`), ~45ms AUHAL create + bind + format read, ~145ms file + `AudioUnitInitialize` + `AudioOutputUnitStart`, ~10ms to the first slice (the engine took ~100ms to its first 100ms buffer). Moving WAV creation off the critical path (onto the processing queue) was measured and gained nothing — not worth the async failure path. The overlay (~100ms of SwiftUI) is fully hidden behind the audio work.

What was removed: `WhisperEngine` is `lazy` (credential + local-binary discovery happens after the recording, not before it); the resolved input device is cached in `~/.local/share/yapless/input-device-cache.json` and validated with ONE property read instead of ~85; the default-input swap (and its settle sleep) is gone entirely.

Startup order is mic-first: `MicAuthorization.prefetch()` (TCC XPC, 25-40ms) runs on a background queue from the top of `run()`, overlapping device resolution's CoreAudio first touch (~100-360ms — this, not AVFoundation, is the "config → Input device (cached)" gap). `NSApplication.setActivationPolicy(.accessory)` (60-145ms first touch of AppKit) happens **after** the capture is dispatched, as do `frontmostApplication` and the cursor push. The log clock is `strftime`, not `DateFormatter` (ICU load, 5-38ms on the first line). The start sound plays on `onFirstBuffer`, so the cue means the mic is live — a slow start is late, never lossy. Measured and NOT worth it: dyld/framework load (the whole framework set is ~1ms over Foundation — the cost is first *use*), dropping SwiftUI, `exec` in the raycast scripts (≤2ms). `--detach` costs ~30-75ms (dyld twice); it spawns with `POSIX_SPAWN_CLOEXEC_DEFAULT` so stray launcher fds don't ride along with the recording.

`startRecordingInBackground` runs CoreAudio setup off the main thread while the overlay draws. A `controlQueue` serialises start/stop, and the completion hops back to main — everything downstream touches UI.

**Launch priority.** A hotkey launcher (Raycast) is a background app, and a process it spawns can inherit darwin background scheduling. Measured under load (loadavg ~30-70): `taskpolicy -b` start took ~3.0s to first buffer vs ~1.1s normal. `raiseLaunchPriority()` (Log.swift) clears `PRIO_DARWIN_PROCESS` and sets user-interactive QoS first thing in `run()`; `--detach` spawns the child with `QOS_CLASS_USER_INTERACTIVE`; `controlQueue` is `.userInteractive`. After the fix a background launch measured ~1.06s. The pre-`main` exec under background policy (~0.5s observed) is outside our reach. A background launch is logged ("Launched with background priority — cleared").

**Every log line is timestamped**: `HH:mm:ss.SSS +<ms since launch>`. `print` is shadowed module-wide in `Log.swift`; launch = the process's kernel start time, or the parent's via `YAPLESS_LAUNCH_TIME` across `--detach`. `First audio buffer` marks when the mic is actually live — read slow starts out of `detached.log` instead of reproducing them.

**Sub-100ms is not reachable this way.** ~190ms of that is AUHAL setup and start plus AVFoundation load, i.e. framework code, paid per process. Getting under 100ms means a resident warm process holding an initialised engine — a daemon, which is what the README promises yapless isn't.

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

# note-taker

A macOS menu bar app for real-time speech transcription, powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Everything runs locally on your machine — no cloud, no API keys, no data leaving your computer.

Two modes in one app:

- **Dictation** — hold a hotkey, speak, release. Transcribed text is injected at your cursor position in any app.
- **Session Recording** — click Start, have a meeting or lecture, click Stop. Get a timestamped JSON + plain text transcript saved to disk.

Both modes share a single Whisper model loaded in memory. Metal GPU acceleration is supported on Apple Silicon.

---

## Requirements

- macOS 11+
- CMake 3.22+
- Xcode (full app, not just Command Line Tools)
- **Metal Toolchain** — required for the default Metal build used by `scripts/build.sh`. Open Xcode → Settings → Components and install **Metal Toolchain** under "Other Components". For a CPU-only build, pass `-DGGML_METAL=OFF` to CMake.
- ~1.5–3.1 GB disk space for the model

## Quick Start

```sh
# Clone with submodules
git clone --recurse-submodules https://github.com/geovansb/note-taker-cpp.git
cd note-taker-cpp

# Download a model (see "Choosing a Model" below)
./scripts/download_model.sh large-v3-turbo

# Build
./scripts/build.sh

# Launch
./scripts/start.sh
```

macOS permissions are requested as the app needs them:

1. **Accessibility** — needed for the dictation hotkey and text injection. Grant it in System Settings > Privacy & Security > Accessibility. If it is not granted at launch, the app shows its own instructions and retries in the background after you enable it.
2. **Microphone** — needed to capture audio. macOS prompts for it the first time you start dictation or a recording session. Grant it in System Settings > Privacy & Security > Microphone.

If you deny either, the app will show a dialog with a button to open the relevant settings page. Recording sessions work without Accessibility; only dictation requires it.

---

## Choosing a Model

| Model | Size | Speed | Quality | Best for |
|-------|------|-------|---------|----------|
| `large-v3` | ~3.1 GB | Slower | Highest accuracy, best multilingual | Long recordings where accuracy matters |
| `large-v3-turbo` | ~1.5 GB | ~2-3x faster | Slightly lower than large-v3, still excellent | Dictation and real-time use |

**Recommendation:** Start with `large-v3-turbo`. It's fast enough for real-time dictation with near-identical quality for most languages. Switch to `large-v3` if you notice accuracy issues with rare languages or heavily accented speech.

Both models support the same languages. The turbo variant uses a distilled decoder (4 layers instead of 32) which trades a small amount of accuracy for significantly faster inference.

```sh
./scripts/download_model.sh large-v3-turbo   # ~1.5 GB download
./scripts/download_model.sh large-v3          # ~3.1 GB download
```

You can switch models from the menu bar at any time. The change takes effect after restarting the app.

---

## How It Works

### Dictation Mode

1. Hold the hotkey (Right Option by default)
2. Speak
3. Release the hotkey
4. The app transcribes your audio and pastes the text at your cursor

The text is injected with Unicode keyboard events, so normal dictation does not use the system clipboard.

If **Save Last 9 Dictations** is enabled in **Settings → Privacy**, the app keeps recent dictations in memory until it quits. Use **Recent Dictations** in the menu bar to copy a previous dictation to the clipboard explicitly.

Minimum captured dictation length is 0.2 seconds to filter out accidental key taps.

### Session Recording Mode

1. Click **Start Recording** (or press Cmd+R)
2. The app listens continuously and detects speech using VAD (Voice Activity Detection)
3. When speech is detected, audio is buffered into chunks
4. Each chunk is transcribed and appended to the output files in real time
5. Click **Stop Recording** (or press Cmd+Shift+R) to finalize

Output files are saved to `~/notes/`:

- `note_YYYYMMDD_HHMMSS.json` — structured data with per-segment timestamps
- `note_YYYYMMDD_HHMMSS.txt` — plain text transcript, one segment per line

Files are written atomically (via temp file + rename) after every chunk, so even if the app crashes, you won't lose completed segments.

---

## Settings

Click **Settings…** from the menu bar icon to open a preferences window with General, Recording, Privacy, and About sections. Settings persist across restarts unless noted otherwise.

### General

#### Language

Choose the transcription language or leave it on **Auto** for automatic detection. Changing the language takes effect immediately — no restart needed.

Available: Auto, Português, English, Español.

#### Dictation Hotkey

Choose which key triggers dictation: Right Option (default), Left Option, Right Command, or Fn.

#### Model

Shows the currently loaded model. Select a different one to queue it for the next restart. If a model isn't downloaded yet, the app will show download instructions.

#### Log Level

Choose how much diagnostic information is written to the app log. Available levels are **DEBUG**, **INFO**, **WARN** (default), and **ERROR**. Changes take effect immediately.

### Recording

#### VAD Sensitivity

Controls how easily the app detects speech during session recording. This setting does **not** affect dictation mode (which records everything while the hotkey is held).

| Level | Behavior |
|-------|----------|
| **Low** | Only loud, clear speech triggers recording. Good for noisy environments — reduces false positives from background noise, keyboard typing, or distant conversations. |
| **Medium** (default) | Balanced. Works well in typical office or home settings. |
| **High** | Picks up quiet speech and soft-spoken speakers. May also pick up ambient noise in loud environments. |

Technically, this adjusts two parameters: the RMS energy threshold and the input gain applied before VAD analysis. Higher sensitivity = lower threshold + higher gain.

#### Silence Timeout

How many seconds of silence the app waits before ending a speech chunk during session recording. Only affects session recording, not dictation.

| Value | Effect |
|-------|--------|
| **2s** | Aggressive chunking. Splits on short pauses. Produces more, shorter segments. Good for fast-paced conversations with clear turn-taking. |
| **3s** | Moderate. |
| **5s** (default) | Tolerant of natural pauses. Good for lectures, presentations, or speakers who pause to think. |
| **8–10s** | Very tolerant. Use when the speaker takes long pauses but you want continuous segments. |

Shorter timeouts mean chunks are sent to Whisper sooner (lower latency for the transcript to appear), but may split sentences mid-thought. Longer timeouts produce more coherent segments but delay output.

#### Notes Folder

Choose where session transcripts and logs are stored. The default is `~/notes/`. The app can open the folder from Settings and validates that a new folder is writable before using it.

### Privacy

**Save Last 9 Dictations** is off by default. When enabled, it keeps recent dictation texts only in app memory and exposes them through **Recent Dictations** in the menu bar. Clicking an item copies the full text to the clipboard. Recording sessions are not added to this history because they are already saved as files.

### About

Shows app version, active model, and local transcription information.

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+R | Start Recording |
| Shift+Cmd+R | Stop Recording |
| Cmd+Q | Quit |

---

## Architecture

```
Hotkey / menu action
  └─ AppController
       ├─ starts/stops AudioCapture on demand
       ├─ DICTATING  → in-memory audio buffer
       └─ RECORDING  → ChunkAssembler (VAD state machine)
                           └─ WhisperWorker (dedicated thread)
                                ├─ Dictation path → TextInjector
                                └─ Session path   → OutputWriter → JSON + TXT
```

Key design decisions:

- **AudioCapture starts on demand** — the microphone starts when dictation or session recording begins and stops when it ends. Dictation starts the mic asynchronously on key-down so the global hotkey run loop stays responsive, while avoiding a permanently open microphone, the orange mic indicator, and Bluetooth headset HFP mode when idle.
- **Single model, single worker thread** — `whisper_full()` is blocking and not thread-safe. One dedicated thread processes a bounded queue. If the queue fills up (64 items), the oldest chunk is dropped.
- **Modes are mutually exclusive** — you can't dictate while recording a session. The hotkey is ignored during recording, and Start Recording is disabled during dictation.

---

## Troubleshooting

**Where are logs written?**
Logs are stored inside the configured Notes Folder, under `logs/note-taker-bar.log`. For the default Notes Folder, run:

```sh
tail -f ~/notes/logs/note-taker-bar.log
```

If you changed the Notes Folder in Settings, use that folder instead of `~/notes`.

**"Accessibility permission required" on every rebuild**
After rebuilding, the ad-hoc code signature changes, which invalidates the macOS TCC permission cache. The `build.sh` script runs `tccutil reset` automatically, but you'll need to re-grant Accessibility permission in System Settings. This only happens during development.

**Dictation hotkey doesn't work**
Check that Accessibility is granted in System Settings > Privacy & Security > Accessibility. The app must be launched via `open build/note-taker-bar.app` (not by running the binary directly) for permissions to be attributed correctly.

**Model loads slowly**
First load takes 3–5 seconds for large-v3-turbo, longer for large-v3. The status shows "Loading model…" during this time. Subsequent transcriptions reuse the loaded model.

**Transcription is inaccurate**
Try switching to `large-v3` for better accuracy. Explicitly setting the language (instead of Auto) can also help, especially for non-English languages.

**No audio detected during recording**
Increase VAD Sensitivity to High. If using an external microphone, check that it's selected as the system input device.

---

## Building from Source

```sh
# CPU-only build
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=OFF
cmake --build build --parallel

# With Metal GPU acceleration (Apple Silicon, default used by scripts/build.sh)
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
cmake --build build --parallel
```

The build produces `build/note-taker-bar.app` — the menu bar app bundle.

Release builds derive `CFBundleShortVersionString` and `CFBundleVersion` from the latest Git tag. Create the release tag first, using the `vX.Y.Z` format, then build from that tag so the app's About screen and the GitHub release version match.

---

## License

This project uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (MIT License).

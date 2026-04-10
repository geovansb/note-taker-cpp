# note-taker — Project Tracking

> macOS menu bar app: CoreAudio capture → RMS VAD → whisper.cpp → text injection / JSON+TXT output.

---

## Repository Layout

```
note-taker/
├── CMakeLists.txt
├── .gitmodules
├── .gitignore
├── project.md
├── whisper.cpp/                  ← git submodule (ggerganov/whisper.cpp)
├── src/
│   ├── main.cpp                  ← CLI entry point (note-taker binary)
│   ├── bar_main.mm               ← App bundle entry point (note-taker-bar)
│   ├── constants.h               ← all constexpr numeric constants
│   ├── audio_capture.mm/h        ← AVAudioEngine, 16kHz mono float32
│   ├── vad.cpp/h                 ← stateless RMS VAD
│   ├── chunk_assembler.cpp/h     ← LISTENING/RECORDING state machine
│   ├── whisper_worker.cpp/h      ← whisper_full on dedicated thread
│   ├── output_writer.cpp/h       ← atomic JSON+TXT flush
│   ├── wav_writer.cpp/h          ← RIFF WAV writer
│   ├── app_controller.cpp/h      ← M4: central controller, owns pipeline
│   ├── app_delegate.mm/h         ← M4: NSStatusItem, menu, settings
│   ├── event_tap.mm/h            ← M4: CGEventTap on CFRunLoop thread
│   └── text_injector.mm/h        ← M4: NSPasteboard + Cmd+V injection
├── bar/
│   ├── Info.plist                ← LSUIElement=YES bundle plist
│   └── entitlements.plist        ← audio-input entitlement
├── tests/
│   ├── vad_test.cpp
│   └── chunk_assembler_test.cpp
├── scripts/
│   ├── download_model.sh         ← wraps whisper.cpp model downloader
│   ├── build.sh                  ← cmake + Metal + tccutil reset
│   └── start.sh                  ← open build/note-taker-bar.app
├── third_party/
│   ├── CLI11.hpp
│   └── nlohmann/json.hpp
└── models/                       ← gitignored; place ggml-*.bin here
```

---

## Milestone Overview

| M | Goal | Status |
|---|------|--------|
| M1 | CoreAudio capture + RMS VAD + ChunkAssembler | ✅ |
| M2 | whisper.cpp submodule + WhisperWorker + terminal output | ✅ |
| M3 | Full CLI flags + JSON/TXT output + optional WAV save | ✅ |
| M4 | Menu bar app: dictation + session recording | ✅ |
| M5 | Hardening & UX polish (H1–H12) | ✅ |

---

## M1 — Audio Capture + VAD + ChunkAssembler ✅

**Acceptance met:** `./note-taker` prints `[CHUNK] duration=<ms>ms` on speech detection, exits cleanly on Ctrl-C.

### Tasks

- [x] **T1.1** Repository scaffolding: `CMakeLists.txt`, `.gitignore`
- [x] **T1.2** `src/constants.h` — all hardcoded values as `constexpr`
- [x] **T1.3** `src/audio_capture.mm/h` — AVAudioEngine + mic permission
- [x] **T1.4** `src/vad.cpp/h` — RMS VAD; `vad_test` passes
- [x] **T1.5** `src/chunk_assembler.cpp/h` — LISTENING/RECORDING state machine
- [x] **T1.6** `src/main.cpp` M1 harness
- [x] **T1.7** CMake: framework linking + `vad_test` target

---

## M2 — Whisper Integration ✅

**Acceptance met:** Speech → transcriptions in terminal with `[HH:MM:SS]` prefix.

### Tasks

- [x] **T2.1** whisper.cpp git submodule
- [x] **T2.2** CMake: `add_subdirectory(whisper.cpp)`, Metal option
- [x] **T2.3** `src/whisper_worker.cpp/h` — bounded queue, drop-oldest, `whisper_free`
- [x] **T2.4** Wire WhisperWorker into `main.cpp`
- [x] **T2.5** `scripts/download_model.sh`

---

## M3 — Output + Full CLI ✅

**Acceptance met:** All CLI flags functional. Produces `notes/note_<timestamp>.json` + `.txt`. Ctrl-C writes complete output.

### Tasks

- [x] **T3.1** `third_party/CLI11.hpp`
- [x] **T3.2** `third_party/nlohmann/json.hpp`
- [x] **T3.3** Full CLI parsing (`--model`, `--output-dir`, `--language`, `--translate`, `--chunk-seconds`, `--metal`, `--list-devices`, `--save-wav`)
- [x] **T3.4** `src/output_writer.cpp/h` — atomic JSON+TXT via `.tmp` → `rename()`
- [x] **T3.5** `src/wav_writer.cpp/h` — RIFF + 16-bit PCM
- [x] **T3.6** `--chunk-seconds` configurable in ChunkAssembler
- [x] **T3.7** Wire OutputWriter + WAV into pipeline

---

## M4 — Menu Bar App ✅

**Acceptance met:** App lives in menu bar. Hold Right Option → dictation → text injected at cursor. Start/Stop Recording → produces `notes/note_*.json` + `.txt`. Language and model persisted across restarts.

### Architecture

```
main thread      →  [NSApp run] → NSStatusItem, menu callbacks
CFRunLoop thread →  CGEventTap  → AppController::onHotkeyDown/Up()
audio thread     →  AVAudioEngine tap → AppController routes by mode
worker thread    →  WhisperWorker → injectText() OR OutputWriter
```

**Modes (mutually exclusive):**
- `IDLE` — audio discarded; Start Recording enabled
- `DICTATING` — audio buffered; hotkey held
- `TRANSCRIBING` — whisper processing dictation buffer; injects result at cursor
- `RECORDING` — VAD-based session; chunks enqueued to WhisperWorker → OutputWriter

### Tasks

- [x] **T4.1** App bundle + basic menu bar skeleton (`bar/Info.plist`, `bar/entitlements.plist`, `bar_main.mm`, `app_delegate.mm/h`)
- [x] **T4.2** `src/event_tap.mm/h` — CGEventTap on CFRunLoop thread; Right Option hotkey; `kCGEventFlagsChanged` mask
- [x] **T4.3** `src/app_controller.cpp/h` — owns pipeline; state machine; hotkey + session APIs
- [x] **T4.4** `src/text_injector.mm/h` — NSPasteboard save/restore + simulated Cmd+V
- [x] **T4.5** Language submenu (auto/pt/en/es) + Model submenu (large-v3/large-v3-turbo) + dynamic menu bar icon + NSUserDefaults persistence
- [~] **T4.6** Start at Login — **deferred** (prototype phase; use `scripts/start.sh` instead)

### Key implementation notes

- `AXIsProcessTrustedWithOptions` must be called on the main thread (UI dialog requirement)
- EventTap lives in AppDelegate (main thread); AppController has no EventTap dependency
- AudioCapture is always-on; mode atomic controls routing (avoids ~300ms AVAudioEngine restart)
- ggml Metal resources (`default.metallib`, `ggml-metal.metal`) must be in `Contents/Resources/` — copied by CMake post-build step
- Always launch via `open build/note-taker-bar.app` (not direct binary) for correct TCC attribution
- Ad-hoc re-signing invalidates TCC CDHash entry — run `tccutil reset Accessibility com.local.note-taker-bar` after each rebuild (automated in `scripts/build.sh`)

---

## Build & Run

```sh
# Build (includes tccutil reset)
./scripts/build.sh

# Launch
./scripts/start.sh

# Download models
./scripts/download_model.sh large-v3        # ~3.1 GB
./scripts/download_model.sh large-v3-turbo  # ~1.5 GB

# CLI tool (M1–M3)
./build/note-taker --model models/ggml-large-v3.bin
./build/note-taker --list-devices

# Unit tests
./build/vad_test
./build/chunk_assembler_test
```

---

## M4 Acceptance Checklist

- [ ] App icon appears in menu bar after `./scripts/start.sh`
- [ ] Status transitions: `● Idle` → `⏳ Loading model…` → `● Idle`
- [ ] Menu bar icon changes: `mic.fill` (idle) / `waveform` (loading) / `mic` (dictating) / `record.circle.fill` (recording)
- [ ] Hold Right Option → status shows `⏺ Dictating…` → release → `⏳ Transcribing…` → text injected at cursor → `● Idle`
- [ ] Start Recording → `🔴 Recording` → speech produces `notes/note_*.json` + `.txt` → Stop Recording → `● Idle`
- [ ] Language selection persists after Quit + relaunch
- [ ] Model selection persists after Quit + relaunch
- [ ] Open Notes Folder opens `~/notes` in Finder (creates dir if absent)
- [ ] Quit cleanly drains WhisperWorker before exit

---

## M5 — Hardening & UX Polish

### Tier 1 — Silent errors → visible feedback

| # | Issue | File(s) | Status |
|---|-------|---------|--------|
| H1 | NSAlert for mic denied | app_delegate.mm, app_controller.cpp | ✅ |
| H2 | NSAlert for accessibility denied | app_delegate.mm | ✅ |
| H3 | Notify user on transcription error (whisper_full failure) | whisper_worker.cpp, app_controller.cpp | ✅ |
| H4 | Notify user on queue overflow (drop-oldest) | whisper_worker.cpp, app_controller.cpp | ✅ (H3 covers both — on_error_ callback) |
| H5 | `@autoreleasepool` in audio tap callback | audio_capture.mm | ✅ |

### Tier 2 — UX polish

| # | Issue | File(s) | Status |
|---|-------|---------|--------|
| H6 | Model menu header doesn't update after selection | app_delegate.mm | ✅ |
| H7 | Keyboard shortcuts for Start/Stop/Open Folder | app_delegate.mm | ✅ |
| H8 | Status hint for FINALIZING mode (both buttons disabled, no explanation) | app_delegate.mm | ✅ |
| H9 | Check fwrite return in output_writer and wav_writer | output_writer.cpp, wav_writer.cpp | ✅ |

### Tier 3 — Nice to have

| # | Issue | File(s) | Status |
|---|-------|---------|--------|
| H10 | VoiceOver accessibility labels on status button | app_delegate.mm | ✅ |
| H11 | Configurable hotkey (setHotkey exists, needs UI) | event_tap.mm, app_delegate.mm | ✅ |
| H12 | Show current lang/model in main menu | app_delegate.mm | ✅ |

---

## Backlog

- **Start at Login** — LaunchAgent plist; add "Start at Login" checkbox to menu (T4.6)
- **VAD threshold tuning** — expose `VAD_RMS_THRESHOLD` and `SILENCE_TIMEOUT_S` as menu settings or `NSUserDefaults` keys
- **Notifications** — `NSUserNotification` / `UNUserNotificationCenter` when session file is written
- **HuggingFace token support** — accept `HF_TOKEN` in download_model.sh for authenticated downloads

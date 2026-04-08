# note-taker — Project Tracking

> macOS CLI meeting recorder: CoreAudio capture → RMS VAD → whisper.cpp → JSON/TXT output.

---

## Repository Layout (target)

```
note-taker/
├── CMakeLists.txt
├── .gitmodules
├── .gitignore
├── project.md
├── whisper.cpp/                  ← git submodule
├── src/
│   ├── main.cpp
│   ├── constants.h
│   ├── audio_capture.mm
│   ├── audio_capture.h
│   ├── vad.cpp
│   ├── vad.h
│   ├── chunk_assembler.cpp
│   ├── chunk_assembler.h
│   ├── whisper_worker.cpp
│   ├── whisper_worker.h
│   ├── output_writer.cpp
│   ├── output_writer.h
│   ├── wav_writer.cpp
│   └── wav_writer.h
├── tests/
│   └── vad_test.cpp
├── scripts/
│   └── download_model.sh
├── third_party/
│   ├── CLI11.hpp
│   └── nlohmann/json.hpp
└── models/                       ← gitignored, download ggml-*.bin here
```

---

## Milestone Overview

| M | Phase | Goal | Status |
|---|-------|------|--------|
| M1 | 1 | CoreAudio capture + RMS VAD + ChunkAssembler (no Whisper) | [x] |
| M2 | 2 | whisper.cpp submodule + WhisperWorker + terminal output | [x] |
| M3 | 3 | Full CLI flags + JSON/TXT output + optional WAV save | [x] |
| M4+ | 4 | Dictation Service: hotkey, text injection, menu bar | [ ] |

---

## M1 — Audio Capture + VAD + ChunkAssembler

**Goal:** Record mic audio. Print `[CHUNK] duration=<ms>ms samples=<n>` on speech detection. No Whisper dependency.

### Tasks

- [x] **T1.1** Repository scaffolding: `CMakeLists.txt`, `.gitignore`
  - `cmake_minimum_required(3.22)`, `project(note-taker CXX OBJCXX)`, `CMAKE_CXX_STANDARD 17`
  - Acceptance: `cmake -B build && cmake --build build` compiles Hello World

- [x] **T1.2** `src/constants.h` — all hardcoded values as `constexpr`
  ```cpp
  constexpr float  VAD_RMS_THRESHOLD    = 0.015f;
  constexpr float  SILENCE_TIMEOUT_S    = 5.0f;
  constexpr int    MIN_CHUNK_MS         = 2000;
  constexpr float  DEFAULT_CHUNK_S      = 15.0f;
  constexpr int    CAPTURE_SAMPLE_RATE  = 16000;
  constexpr int    WHISPER_SAMPLE_RATE  = 16000;
  constexpr float  INPUT_GAIN           = 1.3f;
  constexpr int    RAW_QUEUE_MAX_BLOCKS = 512;
  constexpr int    PROCESSING_QUEUE_MAX = 64;
  ```

- [x] **T1.3** `src/audio_capture.h` + `src/audio_capture.mm`
  - `bool start(std::function<void(const float*, size_t)> on_block)`
  - `void stop()`
  - `static std::vector<std::string> listDevices()`
  - AVAudioEngine `installTap` at 16kHz mono float32
  - Request mic permission via `AVCaptureDevice.requestAccess` at startup
  - Acceptance: `--list-devices` prints device list and exits

- [x] **T1.4** `src/vad.h` + `src/vad.cpp`
  - `bool isSpeech(const float* samples, size_t n)`
  - RMS = `sqrt(sum(x^2)/n)`, apply `INPUT_GAIN` first
  - Acceptance: `vad_test`: silent buffer → false, loud buffer → true

- [x] **T1.5** `src/chunk_assembler.h` + `src/chunk_assembler.cpp`
  - `ChunkAssembler(Vad&, float max_chunk_s, on_chunk_cb)`
  - State machine: LISTENING ↔ RECORDING
    - → RECORDING: VAD true
    - → LISTENING: silence ≥ `SILENCE_TIMEOUT_S` AND chunk ≥ `MIN_CHUNK_MS`
  - Hard flush at `max_chunk_s`
  - `std::mutex` protecting sample buffer (`feed()` is called from tap thread)
  - Acceptance: synthetic test emits correctly-timed chunks

- [x] **T1.6** `src/main.cpp` (M1 harness)
  - Simple `argv` scan for `--list-devices`
  - Wire: `AudioCapture` → `ChunkAssembler::feed()` → `on_chunk` prints chunk info
  - `SIGINT` handler: `AudioCapture::stop()` + clean join

- [x] **T1.7** CMake: framework linking + `vad_test` target
  - Link: `-framework AVFoundation -framework CoreAudio -framework Foundation`
  - `vad_test` target: `tests/vad_test.cpp` + `vad.cpp`

### Design Notes

- AVAudioEngine `installTap` handles format conversion to float32 16kHz internally (no manual `AudioConverter`)
- Tap callback: **only `memcpy`** — never block the audio thread
- State flags: `std::atomic<bool>`; mutex only for the sample deque

---

## M2 — Whisper Integration

**Goal:** Speak into mic → transcriptions printed to terminal with `[HH:MM:SS]` prefix.

### Tasks

- [x] **T2.1** Add whisper.cpp as git submodule, pin to latest stable tag
  - Acceptance: `whisper.cpp/whisper.h` present

- [x] **T2.2** CMake: integrate whisper submodule
  - `add_subdirectory(whisper.cpp)` with `WHISPER_BUILD_EXAMPLES OFF`
  - `option(WHISPER_METAL "Enable Metal" OFF)`
  - `target_link_libraries(note-taker PRIVATE whisper)`

- [x] **T2.3** `src/whisper_worker.h` + `src/whisper_worker.cpp`
  - Constructor: `(model_path, use_metal, language, translate)`
  - `void start()` / `void stop()` / `void enqueue(std::vector<float>)`
  - Bounded queue (`PROCESSING_QUEUE_MAX`), drop-oldest on overflow
  - `whisper_full_params`: `WHISPER_SAMPLING_GREEDY`, `no_context=true`
  - Metal: `whisper_context_params.use_gpu = true`
  - Destructor: `whisper_free(ctx)`

- [x] **T2.4** Wire WhisperWorker into `main.cpp`
  - Replace `on_chunk` print with `whisper_worker.enqueue(chunk)`
  - Temporary `--model` parsing via `argv` scan
  - Shutdown order: `AudioCapture::stop()` → flush assembler → `WhisperWorker::stop()`

- [x] **T2.5** `scripts/download_model.sh`
  - Wrapper around `whisper.cpp/models/download-ggml-model.sh`
  - Usage: `./scripts/download_model.sh base`

### Design Notes

- `whisper_full()` is blocking (2–10s for medium chunks) → dedicated `std::thread`, not GCD
- One `whisper_context*` per WhisperWorker — not thread-safe for sharing

---

## M3 — Output + Full CLI

**Goal:** All CLI flags functional. Produces `notes/note_<timestamp>.json` + `.txt`. Ctrl-C always writes complete output.

### Tasks

- [x] **T3.1** Add `third_party/CLI11.hpp` (single-header)
- [x] **T3.2** Add `third_party/nlohmann/json.hpp` (single-header)

- [x] **T3.3** Full CLI parsing in `main.cpp` via CLI11
  - `--model <path>` (default: `models/ggml-medium.bin`)
  - `--output-dir <path>` (default: `./notes`)
  - `--language <code>` (default: `auto`)
  - `--translate` (flag)
  - `--chunk-seconds <float>` (default: `15.0`)
  - `--metal` (flag)
  - `--list-devices` (flag, exit after)
  - `--save-wav` (flag)

- [x] **T3.4** `src/output_writer.h` + `src/output_writer.cpp`
  - `void addSegment(int64_t start_ms, int64_t end_ms, const std::string& text)`
  - `void flush()` — atomic write via `.tmp` → `rename()`
  - JSON: `{ session_id, model, language, segments: [{start_ms, end_ms, text}] }`
  - Flush after every chunk (crash safety)

- [x] **T3.5** `src/wav_writer.h` + `src/wav_writer.cpp`
  - `void writeWav(path, samples, n, sample_rate)` — RIFF + 16-bit PCM
  - Only called when `--save-wav`

- [x] **T3.6** Make `--chunk-seconds` configurable in ChunkAssembler
  - Clamp if < `MIN_CHUNK_MS/1000` (with stderr warning)

- [x] **T3.7** Wire OutputWriter + WAV into pipeline
  - Pass `OutputWriter*` to `WhisperWorker`
  - Add wall-clock offset to whisper centisecond timestamps in OutputWriter

### Pitfalls

| Pitfall | Mitigation |
|---------|------------|
| Mic permission silently denied on macOS 12+ | Request via `AVCaptureDevice.requestAccess` before engine start |
| `whisper_full` timestamps are centiseconds from chunk start | Add wall-clock offset in OutputWriter, not in WhisperWorker |
| JSON corrupted on crash | Atomic write: `.tmp` → `rename()` |
| Metal crashes on Intel Mac | `sysctlbyname("hw.optional.arm64")` guard |
| `--chunk-seconds` < `MIN_CHUNK_MS/1000` | Clamp + warn |

### M3 Acceptance Checklist

- [ ] `--list-devices` prints devices and exits
- [ ] Default run transcribes to terminal and writes `notes/note_*.json`
- [ ] `--language pt` transcribes Portuguese correctly
- [ ] `--translate` outputs English regardless of spoken language
- [ ] `--chunk-seconds 5` produces short chunks
- [ ] `--metal` uses GPU (verify via `sudo powermetrics --show-process-gpu-time`)
- [ ] `--save-wav` writes `chunk_*.wav` playable in QuickTime
- [ ] Ctrl-C produces complete JSON (no truncation)
- [ ] `--output-dir /tmp/test_notes` writes to correct path

---

## M4+ — Backlog: Dictation Service

> Out of current scope. Requires Accessibility permission + persistent NSApplication run loop.

- [ ] **B4.1** CGEventTap global hotkey prototype (logs key events globally)
- [ ] **B4.2** AXUIElement text injection helper with CGEvent keystroke fallback
- [ ] **B4.3** NSApplication + NSStatusBar main loop alongside background threads
- [ ] **B4.4** Push-to-talk state machine (KEY_DOWN = start capture, KEY_UP = flush+transcribe+inject)
- [ ] **B4.5** Menu bar icon with status indicator (idle / recording / transcribing)
- [ ] **B4.6** Preferences: configurable hotkey, model, language from menu bar
- [ ] **B4.7** Entitlements plist + code signing for Accessibility
- [ ] **B4.8** App bundle + launchd plist for auto-start at login

---

## Build & Run Reference

```sh
# Configure
cmake -B build -DCMAKE_BUILD_TYPE=Release

# Configure with Metal (Apple Silicon only)
cmake -B build -DCMAKE_BUILD_TYPE=Release -DWHISPER_METAL=ON

# Build
cmake --build build --parallel

# Download model
./scripts/download_model.sh base     # ~150MB
./scripts/download_model.sh medium   # ~1.5GB

# Run
./build/note-taker --model models/ggml-base.bin
./build/note-taker --list-devices

# VAD unit test
./build/vad_test
```

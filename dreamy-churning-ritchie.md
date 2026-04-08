# note-taker — Implementation Plan

## Context

Building a macOS C++ CLI meeting recorder from a clean repository. The user provided a design document describing two eventual products (Meeting Recorder + Dictation Service) and wants to start with the simpler MVP: Meeting Recorder only.

The plan was refined collaboratively. Implementation will be tracked via a `project.md` file committed to the repo.

---

## Current Focus: T4.1 Cleanup + T4.2 (EventTap)

**Status:** M1–M3 complete. T4.1 partially done — app launches, icon appears, but menu was stripped to "Quit only" during crash debugging and must be restored. T4.2 not started.

### T4.1 Cleanup — Restore full menu skeleton in `src/app_delegate.mm`

Replace the minimal one-item menu with the full skeleton. All functional items grayed out (no AppController yet); only Quit is enabled.

**Menu structure (with NSMenuItem tags for future programmatic access):**
```objc
NSMenu* menu = [[NSMenu alloc] init];

// tag 1 — dynamic status string, updated by AppController via setStatusTitle:
NSMenuItem* statusItem = [[NSMenuItem alloc] initWithTitle:@"● Idle"
                          action:nil keyEquivalent:@""];
statusItem.tag = 1;
statusItem.enabled = NO;
[menu addItem:statusItem];

[menu addItem:[NSMenuItem separatorItem]];

// Dictation hint (informational, always disabled)
NSMenuItem* hint = [[NSMenuItem alloc] initWithTitle:@"Hold ⌥ Right Option to dictate"
                    action:nil keyEquivalent:@""];
hint.enabled = NO;
[menu addItem:hint];

[menu addItem:[NSMenuItem separatorItem]];

// tag 2 — Start Recording (enabled by AppController when IDLE)
NSMenuItem* startRec = [[NSMenuItem alloc] initWithTitle:@"▶ Start Recording"
                         action:@selector(startRecording:) keyEquivalent:@""];
startRec.tag = 2;
startRec.enabled = NO;   // disabled until AppController wired
[menu addItem:startRec];

// tag 3 — Stop Recording (enabled only when RECORDING)
NSMenuItem* stopRec = [[NSMenuItem alloc] initWithTitle:@"■ Stop Recording"
                        action:@selector(stopRecording:) keyEquivalent:@""];
stopRec.tag = 3;
stopRec.enabled = NO;
[menu addItem:stopRec];

// Open Notes Folder (tag 4)
NSMenuItem* openFolder = [[NSMenuItem alloc] initWithTitle:@"📂 Open Notes Folder"
                           action:@selector(openNotesFolder:) keyEquivalent:@""];
openFolder.tag = 4;
openFolder.enabled = NO;   // enabled in T4.5
[menu addItem:openFolder];

[menu addItem:[NSMenuItem separatorItem]];

// Quit — always enabled
[menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];

_statusItem.menu = menu;
```

**Stub selectors needed in `app_delegate.mm`** (no-ops until AppController wired):
```objc
- (void)startRecording:(id)__unused sender {}
- (void)stopRecording:(id)__unused sender {}
- (void)openNotesFolder:(id)__unused sender {}
```

**`app_delegate.h`** — add declarations for the three stub selectors (or keep them private; they'll be overridden in T4.3).

**Files changed:** `src/app_delegate.mm`, `src/app_delegate.h`

**Acceptance:** Menu shows full skeleton; Start/Stop/Open grayed; Quit works.

---

### T4.2 — EventTap: global hotkey (Right Option)

**New files:** `src/event_tap.h`, `src/event_tap.mm`

**`src/event_tap.h`:**
```cpp
#pragma once
#include <functional>

// CGEventTap wrapper. Runs its own CFRunLoop thread.
// Default hotkey: Right Option (kVK_RightOption = 0x3D).
// Requires Accessibility permission (AXIsProcessTrustedWithOptions).
class EventTap {
public:
    EventTap();
    ~EventTap();

    // Call before start(). Defaults to Right Option (0x3D).
    void setHotkey(int keycode);

    // Start monitoring. on_down/on_up called on the CFRunLoop thread.
    // Returns false if Accessibility permission denied.
    bool start(std::function<void()> on_down, std::function<void()> on_up);

    void stop();

private:
    struct Impl;
    Impl* impl_;
};
```

**`src/event_tap.mm` key design points:**
- `CGEventTapCreate` with `kCGSessionEventTap`, `kCGHeadInsertEventTap`, `kCGEventTapOptionListenOnly`
  - Listen-only (passive): does NOT intercept keys, no latency added to the system
  - `kCGEventMaskBit(kCGEventKeyDown) | kCGEventMaskBit(kCGEventKeyUp)`
- Callback: check `CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode)` against hotkey keycode
- Dedicated `std::thread` running `CFRunLoopRun()` (tap must run on its own CFRunLoop)
- `CFMachPortRef tap_` + `CFRunLoopSourceRef src_` stored in `Impl`
- `stop()`: `CGEventTapEnable(tap_, false)` → `CFRunLoopStop(run_loop_)` → thread.join()
- Accessibility guard: call `AXIsProcessTrustedWithOptions(NULL)` before creating tap; if false, print stderr warning and return false (NSAlert shown from `bar_main.mm` at launch separately)

**Wire into `app_delegate.mm` for T4.2 acceptance test:**
- Instantiate `EventTap` as `_eventTap` ivar in `AppDelegate`
- In `applicationDidFinishLaunching:`, call `_eventTap.start(on_down, on_up)` where callbacks print to stderr:
  ```
  debug: hotkey DOWN
  debug: hotkey UP
  ```
- `applicationWillTerminate:` → `_eventTap.stop()`
- EventTap stored by value or pointer in AppDelegate; ownership transferred to AppController in T4.3

**CMakeLists.txt changes:**
- Add `src/event_tap.mm` to `note-taker-bar` sources
- Add `-framework Carbon` to `target_link_libraries(note-taker-bar ...)` (provides `kVK_RightOption` via `<Carbon/Carbon.h>`)

**Acceptance:** Hold Right Option → `debug: hotkey DOWN` in stderr; release → `debug: hotkey UP`. Other keys are unaffected. No crash if Accessibility is denied (just a warning printed).

---

## Phase 0 — First Action (DONE)

Create `project.md` in the repo root (see content below) as a living tracking document. Commit it as the first commit.

---

## Milestone Summary

| M | Phase | Goal |
|---|-------|------|
| M1 | 1 | CoreAudio capture + RMS VAD + ChunkAssembler — no Whisper, print chunk durations |
| M2 | 2 | whisper.cpp submodule + WhisperWorker thread — print transcriptions to terminal |
| M3 | 3 | Full CLI flags (CLI11) + JSON/TXT output (nlohmann/json) + optional WAV save |
| M4+ | future | Dictation Service: hotkey, text injection, menu bar app |

---

## Critical Files

- `CMakeLists.txt` — build system, framework linking, Metal flag, whisper submodule
- `src/audio_capture.mm` — AVAudioEngine lifecycle, tap callback, device enumeration (Obj-C++)
- `src/chunk_assembler.cpp` — LISTENING/RECORDING state machine, VAD integration, chunk dispatch
- `src/whisper_worker.cpp` — whisper context, worker thread, bounded queue, segment emission
- `src/main.cpp` — CLI entry point, component wiring, startup/shutdown order
- `src/constants.h` — all hardcoded constants as `constexpr` (shared across modules)

---

## M1 — Audio Capture + VAD + ChunkAssembler

**Acceptance:** Running `./note-taker` records mic audio, prints `[CHUNK] duration=<ms>ms` on speech detection, exits cleanly on Ctrl-C.

### Tasks

**T1.1 — Repository scaffolding**
- `CMakeLists.txt`: `cmake_minimum_required(3.22)`, `project(note-taker CXX OBJCXX)`, `CMAKE_CXX_STANDARD 17`, placeholder `add_executable`
- `.gitignore`: `build/`, `models/*.bin`, `*.o`, `*.dSYM`, `.DS_Store`
- Acceptance: `cmake -B build && cmake --build build` compiles Hello World

**T1.2 — `src/constants.h`**
- All hardcoded constants as `constexpr float/int`
- Shared by all modules — no magic numbers elsewhere

**T1.3 — `src/audio_capture.h` + `src/audio_capture.mm`**
- `AudioCapture` class: `bool start(callback)`, `void stop()`, `static listDevices()`
- AVAudioEngine `installTap` at 16kHz mono float32
- `--list-devices`: enumerates `AVCaptureDevice`, prints, exits
- Request mic permission via `AVCaptureDevice.requestAccess` at startup
- Acceptance: `--list-devices` prints at least one device; mic permission prompt appears

**T1.4 — `src/vad.h` + `src/vad.cpp`**
- `class Vad { bool isSpeech(const float*, size_t n); }`
- RMS = `sqrt(sum(x^2)/n)`, apply `INPUT_GAIN` before computing
- Acceptance: CMake `vad_test` target: silent buffer → false, loud buffer → true

**T1.5 — `src/chunk_assembler.h` + `src/chunk_assembler.cpp`**
- `ChunkAssembler(Vad&, float max_chunk_s, on_chunk_cb)`
- State machine: LISTENING → RECORDING (VAD true); RECORDING → LISTENING (silence ≥ SILENCE_TIMEOUT_S AND chunk ≥ MIN_CHUNK_MS)
- Hard flush at `max_chunk_s` to prevent unbounded growth
- `feed()` called from AVAudioEngine tap thread; protect sample buffer with `std::mutex`
- Acceptance: synthetic test emits correctly-timed chunks

**T1.6 — Wire `src/main.cpp` (M1 harness)**
- Parse `--list-devices` with simple `argv` loop (full parsing in M3)
- Instantiate `AudioCapture`, `Vad`, `ChunkAssembler`
- `on_chunk` prints `[CHUNK] duration=<ms>ms samples=<n>`
- `SIGINT` handler: `AudioCapture::stop()`, clean join

**T1.7 — CMake: link frameworks + vad_test**
- Link: `-framework AVFoundation -framework CoreAudio -framework Foundation`
- Add `vad_test` target: `tests/vad_test.cpp` + `vad.cpp`

### Key Design Decisions

- **AVAudioEngine over AudioQueue**: `installTap` handles format conversion to float32 16kHz internally; no manual `AudioConverter` needed
- **Tap callback discipline**: only `memcpy` in the callback; heavy work in ChunkAssembler on the assembler's side
- **State machine thread safety**: `std::atomic<bool>` for state flags, `std::mutex` only for sample buffer deque

---

## M2 — Whisper Integration

**Acceptance:** Speak into mic → transcriptions appear in terminal with timestamp prefix.

### Tasks

**T2.1 — Add whisper.cpp submodule**
- `git submodule add https://github.com/ggerganov/whisper.cpp.git`
- Pin to latest stable tag
- Acceptance: `whisper.cpp/whisper.h` present

**T2.2 — CMake: integrate whisper**
- `add_subdirectory(whisper.cpp)`
- `set(WHISPER_BUILD_EXAMPLES OFF)`
- `option(WHISPER_METAL "Enable Metal" OFF)`
- `target_link_libraries(note-taker PRIVATE whisper)`

**T2.3 — `src/whisper_worker.h` + `src/whisper_worker.cpp`**
- Constructor: `(model_path, use_metal, language, translate)`
- `void start()` — spawns worker thread
- `void enqueue(std::vector<float>)` — bounded queue (`PROCESSING_QUEUE_MAX`), drop-oldest on overflow
- `void stop()` — sets flag, notifies cv, joins thread, calls `whisper_free`
- Worker prints: `[HH:MM:SS] <text>`
- `whisper_full_params`: `WHISPER_SAMPLING_GREEDY`, `no_context=true`
- Metal: `whisper_context_params.use_gpu = true` when `--metal`

**T2.4 — Wire WhisperWorker into main.cpp**
- Replace `on_chunk` print with `whisper_worker.enqueue(chunk)`
- Temporary `--model` parsing via `argv` scan
- Shutdown order: `AudioCapture::stop()` → flush assembler → `WhisperWorker::stop()`

**T2.5 — `scripts/download_model.sh`**
- Wrapper around `whisper.cpp/models/download-ggml-model.sh`
- Usage: `./scripts/download_model.sh base`

### Key Design Decisions

- **Dedicated `std::thread`** (not GCD): blocking `whisper_full()` call makes back-pressure explicit; bounded queue with drop-oldest protects the tap thread
- **One context per WhisperWorker**: `whisper_full` is not thread-safe for shared contexts

---

## M3 — Output + Full CLI

**Acceptance:** All CLI flags work; `notes/note_<timestamp>.json` + `.txt` produced; Ctrl-C always produces complete output.

### Tasks

**T3.1 — Add CLI11 single-header** (`third_party/CLI11.hpp`)

**T3.2 — Add nlohmann/json single-header** (`third_party/nlohmann/json.hpp`)

**T3.3 — Full CLI parsing in main.cpp** (all flags from spec)

**T3.4 — `src/output_writer.h` + `src/output_writer.cpp`**
- `addSegment(start_ms, end_ms, text)` — accumulates in memory
- `flush()` — writes `.json` + `.txt` atomically via `rename()` from `.tmp`
- JSON schema: `{ session_id, model, language, segments: [{start_ms, end_ms, text}] }`
- Flush after every chunk (crash safety)

**T3.5 — `src/wav_writer.h` + `src/wav_writer.cpp`**
- `writeWav(path, samples, n, sample_rate)` — RIFF header + 16-bit PCM
- Only invoked when `--save-wav`

**T3.6 — `--chunk-seconds` made configurable in ChunkAssembler**
- Pass value from main; clamp if < `MIN_CHUNK_MS/1000` (with warning)

**T3.7 — Wire OutputWriter + WAV into pipeline**
- Pass `OutputWriter*` to `WhisperWorker`
- Add wall-clock offset to whisper centisecond timestamps when building segments

### Pitfalls

| Pitfall | Mitigation |
|---------|------------|
| Mic permission silently denied on macOS 12+ | Explicitly request before engine start |
| `whisper_full` segments use centiseconds from chunk start | Add wall-clock offset in OutputWriter |
| JSON corrupted on crash | Atomic write via `.tmp` + `rename()` |
| Metal on Intel Mac crashes | Check `hw.optional.arm64` via `sysctlbyname` |

---

## M4 — Unified Menu Bar App

**Context:** M1–M3 complete as CLI tool (`note-taker`). M4 replaces the CLI as the primary product with a single macOS menu bar app (`note-taker-bar`) that has two mutually exclusive modes:

- **Dictation** — push-to-talk: hold hotkey → speak → release → text injected at cursor. No file output.
- **Record Session** — VAD-based recording: same pipeline as M1–M3, produces `notes/note_*.json` + `.txt`.

Single process, single WhisperWorker, single model loaded. Eliminates resource contention. CLI `note-taker` kept as secondary build target for power users / scripting.

**Stack:** C++/Objective-C++ throughout. No Swift.

---

### Thread model

```
main thread      →  [NSApp run]  →  NSStatusItem, menu callbacks
CFRunLoop thread →  CGEventTap   →  AppController::onKeyDown/Up()
audio thread     →  AVAudioEngine tap  →  AppController routes to mode
worker thread    →  WhisperWorker  →  on_result (inject) OR OutputWriter (session)
```

---

### Menu structure

```
● note-taker                      ← dynamic: ● idle · ⏺ dictating · 🔴 recording · ⏳ transcribing
───────────────────────────────────
  Hold ⌥ Right Option to dictate  ← informational, grayed out
───────────────────────────────────
  ▶ Start Recording
  ■ Stop Recording                 ← grayed when idle
  📂 Open Notes Folder
───────────────────────────────────
  Language ▶  [Auto · pt · en · es · fr · de]
  Model ▶     [large-v3 · medium · base]
  Start at Login  [checkbox]
───────────────────────────────────
  Quit
```

---

### New files

| File | Purpose |
|------|---------|
| `bar/Info.plist` | Bundle plist: LSUIElement=YES, NSPrincipalClass=NSApplication |
| `bar/entitlements.plist` | audio-input (Accessibility is TCC, no entitlement needed) |
| `src/bar_main.mm` | Entry point: Accessibility check → NSApplicationMain |
| `src/app_delegate.mm/h` | NSApplicationDelegate, NSStatusItem, menu construction, icon updates |
| `src/app_controller.mm/h` | Central controller: owns AudioCapture, WhisperWorker, ChunkAssembler, OutputWriter, EventTap; routes audio by mode; state machine |
| `src/event_tap.mm/h` | CGEventTap on dedicated CFRunLoop thread; key down/up callbacks |
| `src/text_injector.mm/h` | NSPasteboard + simulated Cmd+V via CGEvent |

**Existing files modified:**
- `src/whisper_worker.h/cpp` — add `setOnResult(std::function<void(std::string)>)` callback for inject path; OutputWriter remains for session path
- `CMakeLists.txt` — add `note-taker-bar` MACOSX_BUNDLE target

---

### AppController state machine

```
IDLE ──[hotkey down]──────────────► DICTATING
  │    [menu: Start Recording]──►  RECORDING
  │
DICTATING ──[hotkey up]──────────► TRANSCRIBING_DICT ──[on_result]──► IDLE (inject text)
                                                                             │
RECORDING ──[menu: Stop]─────────► IDLE (flush + final write)        TextInjector
           ──[chunk ready]───────► WhisperWorker (async, stays RECORDING)
```

Modes are **mutually exclusive**: hotkey ignored while RECORDING; Start Recording grayed while DICTATING or TRANSCRIBING.

---

### Audio routing in AppController

AudioCapture is started once at app launch and never stopped (avoids ~300ms AVAudioEngine restart latency). The `on_block` callback routes samples based on current mode:

```cpp
capture_.start([this](const float* s, size_t n) {
    switch (mode_.load()) {
        case Mode::DICTATING:  appendToBuffer(s, n);  break;
        case Mode::RECORDING:  assembler_.feed(s, n); break;
        default:               /* discard */
    }
});
```

---

### Tasks

**T4.1 — App bundle + basic menu bar**
- `bar/Info.plist`: LSUIElement=YES, NSPrincipalClass, NSMicrophoneUsageDescription
- `bar/entitlements.plist`: audio-input only
- CMake: `add_executable(note-taker-bar MACOSX_BUNDLE ...)` linking AppKit + CoreGraphics + ApplicationServices
- `src/bar_main.mm`: `AXIsProcessTrustedWithOptions` check → NSAlert if denied → NSApplicationMain
- `src/app_delegate.mm/h`: NSStatusItem `●`, Quit item
- Acceptance: app builds; icon appears in menu bar; Quit works; denied Accessibility shows helpful alert

**T4.2 — EventTap (global hotkey)**
- `src/event_tap.mm/h`: `EventTap::start(on_down, on_up)` / `stop()`
- Dedicated `std::thread` running `CFRunLoopRun()`; CGEventTap filter: keyDown + keyUp
- Default: Right Option (`kVK_RightOption` = 0x3D); configurable via NSUserDefaults `hotkey_keycode`
- Callbacks are lightweight — just forward to AppController
- Acceptance: key events logged to stderr; other keys unaffected

**T4.3 — AppController (unified audio routing + state machine)**
- `src/app_controller.mm/h`: owns all pipeline components; starts them at construction
- `setOnResult` added to WhisperWorker: in DICTATING path calls TextInjector; in RECORDING path calls OutputWriter
- Dictation: `onKeyDown()` → reset buffer + `mode_=DICTATING`; `onKeyUp()` → snapshot + enqueue + `mode_=TRANSCRIBING_DICT`; hard cap 30s
- Session: `startSession()` → create new OutputWriter with fresh session_id + `mode_=RECORDING`; `stopSession()` → flush writer + `mode_=IDLE`
- All icon updates: `dispatch_async(dispatch_get_main_queue(), …)` via delegate callback
- Acceptance: hold key → speak → release → transcription in console; Start/Stop Recording works end-to-end

**T4.4 — Text injection**
- `src/text_injector.mm/h`: `void injectText(const std::string& utf8)`
  1. Save NSPasteboard contents
  2. Write text to `NSPasteboardTypeString`
  3. Post Cmd+V via `CGEventCreateKeyboardEvent` (`kVK_ANSI_V` + `kCGEventFlagMaskCommand`)
  4. Restore original pasteboard after 200ms (dispatch_after)
- Acceptance: transcribed text appears at cursor in TextEdit, Notes, Safari address bar

**T4.5 — Full menu UX + settings persistence**
- Dynamic status title: `●` / `⏺` / `🔴` / `⏳` / `⚠`
- Language submenu with checkmark; Start/Stop Recording enable/disable by state
- "Open Notes Folder": `[[NSWorkspace sharedWorkspace] openFile:output_dir]`
- Model submenu: changes model path, requires Quit+relaunch to take effect (shown in menu item subtitle)
- All settings persisted to NSUserDefaults; loaded at AppController init
- Acceptance: settings survive restart; menu items gray/enable correctly per state

**T4.6 — Start at Login**
- LaunchAgent plist: `~/Library/LaunchAgents/com.local.note-taker-bar.plist`
- ProgramArguments: resolved path to `note-taker-bar.app/Contents/MacOS/note-taker-bar`
- Menu toggle: writes plist (`launchctl load`) on enable, removes (`launchctl unload`) on disable
- Acceptance: after enable, app relaunches after logout/login

---

### Key design decisions

| Decision | Rationale |
|----------|-----------|
| Single process, two modes | Eliminates GPU memory contention; one 3GB model loaded once |
| Modes mutually exclusive | Simplifies state machine; one AudioCapture routing at a time |
| AudioCapture always-on | ~300ms AVAudioEngine init avoided on each dictation keypress |
| Dictation: inject only | No file clutter for quick in-context use; session mode handles persistence |
| Session: OutputWriter unchanged | Reuses M3 atomic JSON/TXT writer without modification |
| NSPasteboard + Cmd+V | Works universally (browsers, Electron, terminals); AXUIElement unreliable |
| CFRunLoop thread for CGEventTap | Must return fast; blocking would delay all keyboard events system-wide |

---

### Permissions (user must grant once)

1. **Microphone** — AVAudioEngine prompts automatically on first use
2. **Accessibility** — System Settings → Privacy & Security → Accessibility → enable `note-taker-bar`. Checked at launch via `AXIsProcessTrustedWithOptions`; app shows NSAlert with instructions if denied.

---

## Verification (M4)

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
cmake --build build --parallel

open build/note-taker-bar.app   # first run: grant Accessibility + Mic permissions

# Dictation mode:
# 1. Open TextEdit, click into document
# 2. Hold Right Option, speak a sentence, release
# 3. Verify text injected at cursor (no file written)

# Session mode:
# 1. Click menu → Start Recording
# 2. Speak for ~30s, click Stop Recording
# 3. Click Open Notes Folder → verify note_*.json + .txt present

# Verify:
# - Icon transitions: ● → ⏺ → ⏳ → ● (dictation) / ● → 🔴 → ● (session)
# - Start Recording grayed while dictating
# - Language/model settings survive Quit + relaunch
# - Quit drains WhisperWorker queue before exit
```

---

## project.md Content (to be created in repo root on first commit)

See below — this is the canonical tracking document for across sessions.

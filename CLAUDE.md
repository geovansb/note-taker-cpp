# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

```sh
# Configure (no Metal)
cmake -B build -DCMAKE_BUILD_TYPE=Release

# Configure with Metal GPU (Apple Silicon only — guard with hw.optional.arm64 check)
cmake -B build -DCMAKE_BUILD_TYPE=Release -DWHISPER_METAL=ON

# Build all targets
cmake --build build --parallel

# Run
./build/note-taker
./build/note-taker --list-devices
```

## Tests

Each module has its own standalone test binary — no test framework, plain assertions.

```sh
./build/vad_test
./build/chunk_assembler_test
```

Tests are built automatically alongside the main binary. To add a new test, add a new `add_executable` block in `CMakeLists.txt` following the existing `vad_test` pattern and include `target_include_directories(... PRIVATE src)`.

## Architecture

The audio pipeline is a straight chain of components, each in its own file pair:

```
CoreAudio tap (audio thread)
  └─ AudioCapture::on_block callback
       └─ ChunkAssembler::feed()     ← state machine, mutex-protected
            └─ on_chunk callback     ← called outside the mutex
                 └─ WhisperWorker::enqueue()   [M2]
                      └─ OutputWriter::addSegment() + flush()  [M3]
```

**`src/audio_capture.mm`** (Objective-C++) — the only `.mm` file. Owns `AVAudioEngine`. macOS requires the `installTap` format to match the hardware's native format exactly; format conversion to 16kHz mono float32 is done explicitly with `AVAudioConverter` inside the tap callback. Call `[engine prepare]` before querying `inputNode.outputFormatForBus:0` — querying before prepare returns invalid formats on macOS.

**`src/chunk_assembler.cpp`** — LISTENING/RECORDING state machine. `feed()` is called from the AVAudioEngine audio thread; it acquires a `std::mutex` only for buffer operations, then calls `on_chunk` outside the lock (never hold the lock across the callback). Hard flush at `max_chunk_s` prevents unbounded buffer growth when speaker doesn't pause.

**`src/vad.cpp`** — stateless RMS computation. Applies `INPUT_GAIN` before comparing to `VAD_RMS_THRESHOLD`. No state — safe to call from any thread.

**`src/constants.h`** — single source of truth for all numeric constants. All are `constexpr`. No magic numbers anywhere else.

**`src/whisper_worker.cpp`** [M2, not yet implemented] — owns one `whisper_context*` (not thread-safe, never share). Uses a bounded `std::queue` + `std::condition_variable`. Drop-oldest policy on overflow to protect the audio thread from ever blocking.

**`src/output_writer.cpp`** [M3, not yet implemented] — accumulates segments in memory, writes JSON + TXT atomically via `.tmp` → `rename()` after every chunk.

## Key constraints

- `audio_capture.mm` is the only file that may import ObjC frameworks. All other `.cpp` files are pure C++.
- ObjC types must not leak into `.h` headers — use PIMPL (`struct Impl` defined only in `.mm`).
- The AVAudioEngine tap callback runs on a dedicated audio thread. Never do heavy work there: only copy samples and call `ChunkAssembler::feed()`.
- `whisper_full()` [M2] is blocking and not thread-safe for a shared context — always call from the dedicated WhisperWorker thread.
- JSON writes use atomic rename to survive Ctrl-C mid-write.

## Project status

See `project.md` for milestone tracking (M1–M4+). Currently in M1 (audio capture + VAD, no Whisper yet).

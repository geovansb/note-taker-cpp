# Distributing note-taker to another Mac

## Build

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

The default build produces a portable Apple Silicon binary with Metal GPU acceleration.
No `-march=native` — runs on any Apple Silicon Mac (M1, M2, M3, M4, ...).

## What to copy

### CLI app (`note-taker`)

| File | Description |
|------|-------------|
| `build/note-taker` | The binary (~10 MB) |
| `models/ggml-large-v3-turbo.bin` | Whisper model (~1.6 GB) |

### Menu bar app (`note-taker-bar`)

| File | Description |
|------|-------------|
| `build/note-taker-bar.app/` | The app bundle (includes Metal shaders) |
| `models/ggml-large-v3-turbo.bin` | Whisper model (~1.6 GB) |

The bar app expects the `models/` directory to be at `../models/` relative to the `.app` bundle.

### Recommended layout on the target Mac

```
~/note-taker/
  note-taker              # or note-taker-bar.app/
  models/
    ggml-large-v3-turbo.bin
```

## Downloading model files

If you prefer to download models directly on the target Mac instead of copying:

```bash
./scripts/download_model.sh large-v3-turbo
```

Available models and approximate sizes:

| Model | Size |
|-------|------|
| `tiny` | ~75 MB |
| `base` | ~142 MB |
| `small` | ~466 MB |
| `medium` | ~1.5 GB |
| `large-v3-turbo` | ~1.6 GB |
| `large-v3` | ~3.1 GB |

## Target Mac requirements

- **macOS 11** (Big Sur) or later
- **Apple Silicon** (M1, M2, M3, M4, ...)
- **Microphone permission** — the system will prompt on first launch
- **Accessibility permission** (bar app only) — required for the global hotkey and text injection. Grant in System Settings > Privacy & Security > Accessibility

No Xcode, CMake, or any build toolchain is needed on the target Mac.

## Optional: CPU-specific optimization

If you want maximum performance on a specific machine, rebuild with:

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release -DNOTETAKER_NATIVE_ARCH=ON
```

The performance difference is marginal on Apple Silicon for whisper inference workloads.

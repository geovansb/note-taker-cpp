#pragma once

constexpr float VAD_RMS_THRESHOLD    = 0.015f;
constexpr float SILENCE_TIMEOUT_S    = 5.0f;
constexpr int   MIN_CHUNK_MS         = 2000;
constexpr float DEFAULT_CHUNK_S      = 15.0f;
constexpr int   CAPTURE_SAMPLE_RATE  = 16000;
constexpr int   WHISPER_SAMPLE_RATE  = 16000;
constexpr float INPUT_GAIN           = 1.3f;
constexpr int   RAW_QUEUE_MAX_BLOCKS = 512;
constexpr int   PROCESSING_QUEUE_MAX = 64;

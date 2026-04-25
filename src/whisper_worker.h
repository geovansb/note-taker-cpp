#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

class OutputWriter;

// ── Transcription abstraction ─────────────────────────────────────────────────

struct TranscribeSegment {
    int64_t     t0;    // centiseconds from chunk start (whisper native unit)
    int64_t     t1;
    std::string text;
};

struct TranscribeResult {
    bool                          ok = false;
    std::vector<TranscribeSegment> segments;
};

// Signature for the transcription function injected into WhisperWorker.
// (samples, n_samples, language, translate) → TranscribeResult
using TranscribeFunc = std::function<TranscribeResult(
    const float* samples, int n_samples,
    const std::string& language, bool translate)>;

// ── WhisperWorker ─────────────────────────────────────────────────────────────

// Owns a dedicated worker thread that dequeues audio chunks and transcribes
// them via an injected TranscribeFunc. Results go to the dictation callback and,
// optionally, to an OutputWriter for persistent JSON/TXT output.
// Thread-safe: enqueue() may be called from any thread.
class WhisperWorker {
public:
    // Production constructor — loads a whisper model in start().
    WhisperWorker(const std::string& model_path,
                  bool               use_metal,
                  const std::string& language,
                  bool               translate);

    // Test constructor — uses a caller-provided transcribe function.
    // start() skips model loading and just spawns the worker thread.
    WhisperWorker(TranscribeFunc     transcribe,
                  const std::string& language,
                  bool               translate);

    ~WhisperWorker();

    WhisperWorker(const WhisperWorker&) = delete;
    WhisperWorker& operator=(const WhisperWorker&) = delete;

    // Optional: attach an OutputWriter before calling start().
    // Thread-safe: acquires internal mutex so the worker thread sees a
    // consistent pointer.
    void setOutputWriter(std::shared_ptr<OutputWriter> writer);

    // Optional: enable WAV saving. wav_dir must exist (or be created by caller).
    void setSaveWav(bool enable, const std::string& wav_dir);

    // Optional: callback invoked after each *dictation* chunk is transcribed.
    // Receives the concatenated text of all non-empty segments.
    // Called on the worker thread — not the main thread.
    void setOnResult(std::function<void(const std::string&)> cb);

    // Optional: callback invoked when whisper_full fails or the queue overflows.
    // Receives a short error description. Called on the worker thread.
    void setOnError(std::function<void(const std::string&)> cb);

    // Optional: callback invoked once when the queue empties after all pending
    // session chunks have been processed. Set this before forceFlush() so the
    // worker can fire it even when no new items arrive after forceFlush.
    // Cleared after the first invocation. Called on the worker thread.
    void setOnSessionDone(std::function<void()> cb);

    // Change the transcription language at runtime. Takes effect on the next
    // chunk processed. Pass "auto" to restore automatic detection.
    void setLanguage(const std::string& lang);

    // Enable/disable translation to English at runtime. When true, output is
    // always in English regardless of the spoken language.
    void setTranslate(bool translate);

    // Load model (production) or just start worker thread (test).
    // Returns false on model load failure (production only).
    bool start();

    // Enqueue a chunk for transcription. chunk_start_ms is the wall-clock time
    // (ms since Unix epoch) when the chunk began. Bounded by PROCESSING_QUEUE_MAX:
    // drops the oldest pending chunk if full (never blocks the caller).
    // is_dictation=true: on_result callback fires; OutputWriter is skipped.
    void enqueue(std::vector<float> chunk, int64_t chunk_start_ms,
                 bool is_dictation = false);

    // Signal stop, wait for in-flight transcription to finish, then join.
    void stop();

private:
    void workerLoop();

    struct Impl;
    Impl* impl_;
};

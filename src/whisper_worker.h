#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

class OutputWriter;

// Owns a whisper_context and a dedicated worker thread.
// Accepts audio chunks via enqueue() and writes transcriptions to stdout
// and, optionally, to an OutputWriter for persistent JSON/TXT output.
// Thread-safe: enqueue() may be called from any thread.
class WhisperWorker {
public:
    WhisperWorker(const std::string& model_path,
                  bool               use_metal,
                  const std::string& language,
                  bool               translate);
    ~WhisperWorker();

    WhisperWorker(const WhisperWorker&) = delete;
    WhisperWorker& operator=(const WhisperWorker&) = delete;

    // Optional: attach an OutputWriter before calling start().
    // Thread-safe: acquires internal mutex so the worker thread sees a
    // consistent pointer.
    void setOutputWriter(OutputWriter* writer);

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

    // Load model and start worker thread. Returns false on model load failure.
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

#pragma once
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <utility>
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
    void setOutputWriter(OutputWriter* writer) { output_writer_ = writer; }

    // Optional: enable WAV saving. wav_dir must exist (or be created by caller).
    void setSaveWav(bool enable, const std::string& wav_dir) {
        save_wav_ = enable;
        wav_dir_  = wav_dir;
    }

    // Load model and start worker thread. Returns false on model load failure.
    bool start();

    // Enqueue a chunk for transcription. chunk_start_ms is the wall-clock time
    // (ms since Unix epoch) when the chunk began. Bounded by PROCESSING_QUEUE_MAX:
    // drops the oldest pending chunk if full (never blocks the caller).
    void enqueue(std::vector<float> chunk, int64_t chunk_start_ms);

    // Signal stop, wait for in-flight transcription to finish, then join.
    void stop();

private:
    void workerLoop();

    struct ChunkItem {
        std::vector<float> samples;
        int64_t            start_ms;  // wall-clock ms (Unix epoch) when chunk was captured
    };

    std::string    model_path_;
    bool           use_metal_;
    std::string    language_;
    bool           translate_;
    OutputWriter*  output_writer_ = nullptr;
    bool           save_wav_      = false;
    std::string    wav_dir_;
    int64_t        session_start_ms_ = 0;
    int            wav_chunk_idx_    = 0;

    struct whisper_context* ctx_ = nullptr;

    std::thread             thread_;
    std::mutex              mutex_;
    std::condition_variable cv_;
    std::queue<ChunkItem>   queue_;
    bool stop_flag_ = false;
};

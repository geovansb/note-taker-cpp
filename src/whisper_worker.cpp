#include "whisper_worker.h"
#include "constants.h"
#include "output_writer.h"
#include "wav_writer.h"
#include "whisper.h"
#include <chrono>
#include <cstdio>
#include <ctime>
#include <utility>

WhisperWorker::WhisperWorker(const std::string& model_path,
                             bool               use_metal,
                             const std::string& language,
                             bool               translate)
    : model_path_(model_path)
    , use_metal_(use_metal)
    , language_(language)
    , translate_(translate)
{}

WhisperWorker::~WhisperWorker() {
    stop();
}

bool WhisperWorker::start() {
    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = use_metal_;

    fprintf(stderr, "info: loading model %s ...\n", model_path_.c_str());
    ctx_ = whisper_init_from_file_with_params(model_path_.c_str(), cparams);
    if (!ctx_) {
        fprintf(stderr, "error: failed to load model: %s\n", model_path_.c_str());
        return false;
    }
    fprintf(stderr, "info: model loaded\n");

    session_start_ms_ =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();

    stop_flag_ = false;
    thread_ = std::thread(&WhisperWorker::workerLoop, this);
    return true;
}

void WhisperWorker::enqueue(std::vector<float> chunk, int64_t chunk_start_ms,
                            bool is_dictation) {
    std::lock_guard<std::mutex> lock(mutex_);
    if ((int)queue_.size() >= PROCESSING_QUEUE_MAX) {
        fprintf(stderr, "warn: transcription queue full, dropping oldest chunk\n");
        queue_.pop();
        if (on_error_) on_error_("Transcription queue full — audio chunk dropped");
    }
    queue_.push({std::move(chunk), chunk_start_ms, is_dictation});
    cv_.notify_one();
}

void WhisperWorker::setLanguage(const std::string& lang) {
    std::lock_guard<std::mutex> lock(mutex_);
    language_ = lang;
}

void WhisperWorker::setTranslate(bool translate) {
    std::lock_guard<std::mutex> lock(mutex_);
    translate_ = translate;
}

void WhisperWorker::setOnSessionDone(std::function<void()> cb) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        on_session_done_ = std::move(cb);
        // Wake the worker in case the queue is already empty — it will check
        // the callback and fire it without waiting for a new item to arrive.
        cv_.notify_one();
    }
}

void WhisperWorker::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stop_flag_ = true;
        cv_.notify_all();
    }
    if (thread_.joinable()) {
        thread_.join();
    }
    if (ctx_) {
        whisper_free(ctx_);
        ctx_ = nullptr;
    }
}

void WhisperWorker::workerLoop() {
    while (true) {
        ChunkItem item;
        std::string lang;
        bool        do_translate = false;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [this] {
                return stop_flag_ || !queue_.empty() || on_session_done_ != nullptr;
            });

            // If the queue is empty but on_session_done_ is set, all pending
            // session chunks have been processed — fire the callback and clear it.
            if (queue_.empty() && on_session_done_) {
                auto cb = std::move(on_session_done_);
                on_session_done_ = nullptr;
                lock.unlock();
                cb();
                continue;
            }

            if (stop_flag_ && queue_.empty()) break;
            item         = std::move(queue_.front());
            queue_.pop();
            lang         = language_;   // snapshot under mutex
            do_translate = translate_;
        }

        // Optional WAV save — before transcription so it's always complete.
        if (save_wav_ && !wav_dir_.empty()) {
            char wav_name[64];
            snprintf(wav_name, sizeof(wav_name), "/chunk_%03d.wav", wav_chunk_idx_++);
            writeWav(wav_dir_ + wav_name,
                     item.samples.data(), item.samples.size(),
                     WHISPER_SAMPLE_RATE);
        }

        whisper_full_params params =
            whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

        params.language         = lang.empty() ? "auto" : lang.c_str();
        params.translate        = do_translate;
        params.no_context       = true;
        params.print_progress   = false;
        params.print_realtime   = false;
        params.print_timestamps = false;
        params.print_special    = false;
        params.single_segment   = false;

        int rc = whisper_full(ctx_, params,
                              item.samples.data(),
                              static_cast<int>(item.samples.size()));
        if (rc != 0) {
            fprintf(stderr, "warn: whisper_full returned %d\n", rc);
            if (on_error_) on_error_("Transcription failed (whisper error " + std::to_string(rc) + ")");
            continue;
        }

        // Wall-clock prefix for terminal output (time when chunk was captured).
        time_t chunk_t = static_cast<time_t>(item.start_ms / 1000);
        struct tm tm_info;
        localtime_r(&chunk_t, &tm_info);
        char ts[16];
        strftime(ts, sizeof(ts), "%H:%M:%S", &tm_info);

        // Offset of chunk start relative to session start (for OutputWriter).
        int64_t chunk_offset_ms = item.start_ms - session_start_ms_;

        int         n         = whisper_full_n_segments(ctx_);
        std::string full_text;  // accumulates all segments (used for dictation callback)

        for (int i = 0; i < n; ++i) {
            const char* text = whisper_full_get_segment_text(ctx_, i);
            if (!text || text[0] == '\0') continue;

            full_text += text;

            fprintf(stdout, "[%s]%s\n", ts, text);
            fflush(stdout);

            // Session path: add to OutputWriter with absolute timestamps.
            if (!item.is_dictation && output_writer_) {
                int64_t t0_ms = chunk_offset_ms + whisper_full_get_segment_t0(ctx_, i) * 10;
                int64_t t1_ms = chunk_offset_ms + whisper_full_get_segment_t1(ctx_, i) * 10;
                output_writer_->addSegment(t0_ms, t1_ms, text);
            }
        }

        if (item.is_dictation) {
            // Dictation path: fire on_result callback (AppController resets mode to IDLE).
            if (on_result_ && !full_text.empty()) {
                on_result_(full_text);
            }
        } else {
            if (output_writer_) output_writer_->flush();

            // After flushing a session chunk, check if the queue is now empty
            // and a session-done callback is waiting.
            std::function<void()> done_cb;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (queue_.empty() && on_session_done_) {
                    done_cb = std::move(on_session_done_);
                    on_session_done_ = nullptr;
                }
            }
            if (done_cb) done_cb();
        }
    }
}

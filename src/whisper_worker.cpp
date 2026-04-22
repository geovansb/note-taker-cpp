#include "whisper_worker.h"
#include "constants.h"
#include "output_writer.h"
#include "wav_writer.h"
#include "whisper.h"
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <ctime>
#include <mutex>
#include <queue>
#include <thread>
#include <utility>

// ── Impl ──────────────────────────────────────────────────────────────────────

struct WhisperWorker::Impl {
    struct ChunkItem {
        std::vector<float> samples;
        int64_t            start_ms;     // wall-clock ms (Unix epoch)
        bool               is_dictation; // true → call on_result, skip OutputWriter
    };

    // Config (set at construction)
    std::string    model_path;   // empty when using test constructor
    bool           use_metal  = false;
    std::string    language;
    bool           translate  = false;

    // Injected transcription function (set in start or constructor)
    TranscribeFunc transcribe;

    // Runtime state
    std::shared_ptr<OutputWriter> output_writer;
    bool           save_wav      = false;
    std::string    wav_dir;
    int64_t        session_start_ms = 0;
    int            wav_chunk_idx    = 0;

    // Callbacks (set before start, except on_session_done)
    std::function<void(const std::string&)> on_result;
    std::function<void(const std::string&)> on_error;
    std::function<void()>                   on_session_done;

    // Whisper context — null when using test constructor
    whisper_context* ctx = nullptr;

    // Threading
    std::thread             thread;
    std::mutex              mutex;
    std::condition_variable cv;
    std::queue<ChunkItem>   queue;
    bool                    stop_flag = false;
};

// ── Constructors ──────────────────────────────────────────────────────────────

WhisperWorker::WhisperWorker(const std::string& model_path,
                             bool               use_metal,
                             const std::string& language,
                             bool               translate)
    : impl_(new Impl{})
{
    impl_->model_path = model_path;
    impl_->use_metal  = use_metal;
    impl_->language   = language;
    impl_->translate  = translate;
}

WhisperWorker::WhisperWorker(TranscribeFunc     transcribe,
                             const std::string& language,
                             bool               translate)
    : impl_(new Impl{})
{
    impl_->transcribe = std::move(transcribe);
    impl_->language   = language;
    impl_->translate  = translate;
}

WhisperWorker::~WhisperWorker() {
    stop();
    delete impl_;
}

// ── Setters ───────────────────────────────────────────────────────────────────

void WhisperWorker::setSaveWav(bool enable, const std::string& wav_dir) {
    impl_->save_wav = enable;
    impl_->wav_dir  = wav_dir;
}

void WhisperWorker::setOnResult(std::function<void(const std::string&)> cb) {
    impl_->on_result = std::move(cb);
}

void WhisperWorker::setOnError(std::function<void(const std::string&)> cb) {
    impl_->on_error = std::move(cb);
}

void WhisperWorker::setOnSessionDone(std::function<void()> cb) {
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->on_session_done = std::move(cb);
        impl_->cv.notify_one();
    }
}

void WhisperWorker::setLanguage(const std::string& lang) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->language = lang;
}

void WhisperWorker::setTranslate(bool translate) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->translate = translate;
}

void WhisperWorker::setOutputWriter(std::shared_ptr<OutputWriter> writer) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->output_writer = std::move(writer);
}

// ── start / stop ──────────────────────────────────────────────────────────────

bool WhisperWorker::start() {
    // If no TranscribeFunc was provided (production path), load the model
    // and build the real whisper-based transcribe function.
    if (!impl_->transcribe) {
        whisper_context_params cparams = whisper_context_default_params();
        cparams.use_gpu = impl_->use_metal;

        fprintf(stderr, "info: loading model %s ...\n", impl_->model_path.c_str());
        impl_->ctx = whisper_init_from_file_with_params(impl_->model_path.c_str(), cparams);
        if (!impl_->ctx) {
            fprintf(stderr, "error: failed to load model: %s\n", impl_->model_path.c_str());
            return false;
        }
        fprintf(stderr, "info: model loaded\n");

        // Build TranscribeFunc that wraps the whisper C API.
        whisper_context* ctx = impl_->ctx;
        impl_->transcribe = [ctx](const float* samples, int n_samples,
                                  const std::string& lang, bool translate) -> TranscribeResult {
            whisper_full_params params =
                whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
            params.no_context       = true;
            params.print_progress   = false;
            params.print_realtime   = false;
            params.print_timestamps = false;
            params.print_special    = false;
            params.single_segment   = false;
            params.language         = lang.empty() ? "auto" : lang.c_str();
            params.translate        = translate;

            int rc = whisper_full(ctx, params, samples, n_samples);
            if (rc != 0) return {false, {}};

            TranscribeResult result;
            result.ok = true;
            int n = whisper_full_n_segments(ctx);
            for (int i = 0; i < n; ++i) {
                const char* text = whisper_full_get_segment_text(ctx, i);
                if (!text || text[0] == '\0') continue;
                result.segments.push_back({
                    whisper_full_get_segment_t0(ctx, i),
                    whisper_full_get_segment_t1(ctx, i),
                    text
                });
            }
            return result;
        };
    }

    impl_->session_start_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();

    impl_->stop_flag = false;
    impl_->thread = std::thread(&WhisperWorker::workerLoop, this);
    return true;
}

void WhisperWorker::enqueue(std::vector<float> chunk, int64_t chunk_start_ms,
                            bool is_dictation) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->queue.size() >= static_cast<size_t>(PROCESSING_QUEUE_MAX)) {
        fprintf(stderr, "warn: transcription queue full, dropping oldest chunk\n");
        impl_->queue.pop();
        if (impl_->on_error) impl_->on_error("Transcription queue full — audio chunk dropped");
    }
    impl_->queue.push({std::move(chunk), chunk_start_ms, is_dictation});
    impl_->cv.notify_one();
}

void WhisperWorker::stop() {
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->stop_flag = true;
        impl_->cv.notify_all();
    }
    if (impl_->thread.joinable()) {
        impl_->thread.join();
    }
    if (impl_->ctx) {
        whisper_free(impl_->ctx);
        impl_->ctx = nullptr;
    }
}

// ── Worker loop ───────────────────────────────────────────────────────────────

void WhisperWorker::workerLoop() {
    while (true) {
        Impl::ChunkItem item;
        std::string lang;
        bool           do_translate = false;
        std::shared_ptr<OutputWriter> ow;
        {
            std::unique_lock<std::mutex> lock(impl_->mutex);
            impl_->cv.wait(lock, [this] {
                return impl_->stop_flag || !impl_->queue.empty() || impl_->on_session_done != nullptr;
            });

            // If the queue is empty but on_session_done is set, all pending
            // session chunks have been processed — fire the callback and clear it.
            if (impl_->queue.empty() && impl_->on_session_done) {
                auto cb = std::move(impl_->on_session_done);
                impl_->on_session_done = nullptr;
                lock.unlock();
                cb();
                continue;
            }

            if (impl_->stop_flag && impl_->queue.empty()) break;
            item         = std::move(impl_->queue.front());
            impl_->queue.pop();
            lang         = impl_->language;
            do_translate = impl_->translate;
            ow           = impl_->output_writer;
        }

        // Optional WAV save — before transcription so it's always complete.
        if (impl_->save_wav && !impl_->wav_dir.empty()) {
            char wav_name[64];
            snprintf(wav_name, sizeof(wav_name), "/chunk_%03d.wav", impl_->wav_chunk_idx++);
            writeWav(impl_->wav_dir + wav_name,
                     item.samples.data(), item.samples.size(),
                     WHISPER_SAMPLE_RATE);
        }

        // Transcribe via the injected function.
        TranscribeResult result = impl_->transcribe(
            item.samples.data(), static_cast<int>(item.samples.size()),
            lang, do_translate);

        if (!result.ok) {
            fprintf(stderr, "warn: transcription failed\n");
            if (impl_->on_error) impl_->on_error("Transcription failed");
            continue;
        }

        // Wall-clock prefix for terminal output (time when chunk was captured).
        time_t chunk_t = static_cast<time_t>(item.start_ms / 1000);
        struct tm tm_info;
        localtime_r(&chunk_t, &tm_info);
        char ts[16];
        strftime(ts, sizeof(ts), "%H:%M:%S", &tm_info);

        // Offset of chunk start relative to session start (for OutputWriter).
        int64_t chunk_offset_ms = item.start_ms - impl_->session_start_ms;

        std::string full_text;

        for (const auto& seg : result.segments) {
            full_text += seg.text;

            fprintf(stdout, "[%s]%s\n", ts, seg.text.c_str());
            fflush(stdout);

            // Session path: add to OutputWriter with absolute timestamps.
            if (!item.is_dictation && ow) {
                int64_t t0_ms = chunk_offset_ms + seg.t0 * 10;
                int64_t t1_ms = chunk_offset_ms + seg.t1 * 10;
                ow->addSegment(t0_ms, t1_ms, seg.text);
            }
        }

        if (item.is_dictation) {
            if (impl_->on_result && !full_text.empty()) {
                impl_->on_result(full_text);
            }
        } else {
            if (ow) ow->flush();

            std::function<void()> done_cb;
            {
                std::lock_guard<std::mutex> lock(impl_->mutex);
                if (impl_->queue.empty() && impl_->on_session_done) {
                    done_cb = std::move(impl_->on_session_done);
                    impl_->on_session_done = nullptr;
                }
            }
            if (done_cb) done_cb();
        }
    }
}

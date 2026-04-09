#include "app_controller.h"
#include "audio_capture.h"
#include "chunk_assembler.h"
#include "constants.h"
#include "output_writer.h"
#include "vad.h"
#include "whisper_worker.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// ── Mode constants ────────────────────────────────────────────────────────────

static constexpr int MODE_IDLE         = 0;
static constexpr int MODE_DICTATING    = 1;
static constexpr int MODE_TRANSCRIBING = 2; // dictation chunk in flight
static constexpr int MODE_RECORDING    = 3;
static constexpr int MODE_FINALIZING   = 4; // stop requested; draining worker queue

// ── Impl ──────────────────────────────────────────────────────────────────────

struct AppController::Impl {
    // Config (set at construction)
    std::string model_path;
    bool        use_metal  = false;
    std::string language;
    std::string output_dir;

    // Mode state machine — atomic so the tap thread can read without a mutex
    std::atomic<int> mode { MODE_IDLE };

    // Pipeline components
    AudioCapture                    capture;
    Vad                             vad;
    std::unique_ptr<ChunkAssembler> assembler;
    std::unique_ptr<WhisperWorker>  worker;
    std::unique_ptr<OutputWriter>   session_writer;

    // Dictation audio accumulator (written on tap thread, read on hotkey-up)
    std::vector<float> dict_buffer;
    std::mutex         dict_mutex;

    // User-facing callbacks (set before start())
    std::function<void(std::string)> on_status;
    std::function<void(std::string)> on_dictation_result;

    // Back-pointer — valid for the lifetime of AppController
    AppController* owner = nullptr;

    bool started = false;

    void notifyStatus(const std::string& s) {
        if (on_status) on_status(s);
    }
};

// ── AppController ─────────────────────────────────────────────────────────────

AppController::AppController(const std::string& model_path,
                             bool               use_metal,
                             const std::string& language,
                             const std::string& output_dir)
    : impl_(new Impl{})
{
    impl_->model_path = model_path;
    impl_->use_metal  = use_metal;
    impl_->language   = language;
    impl_->output_dir = output_dir;
    impl_->owner      = this;
}

AppController::~AppController() {
    stop();
    delete impl_;
}

void AppController::setOnStatusChange(std::function<void(std::string)> cb) {
    impl_->on_status = std::move(cb);
}

void AppController::setOnDictationResult(std::function<void(std::string)> cb) {
    impl_->on_dictation_result = std::move(cb);
}

void AppController::setLanguage(const std::string& lang) {
    if (impl_->worker) impl_->worker->setLanguage(lang);
    impl_->language = lang;
}

void AppController::setTranslate(bool translate) {
    if (impl_->worker) impl_->worker->setTranslate(translate);
}

bool AppController::isRecording() const {
    return impl_->mode.load(std::memory_order_relaxed) == MODE_RECORDING;
}

bool AppController::start() {
    if (impl_->started) return true;

    impl_->notifyStatus("⏳ Loading model…");

    // ── WhisperWorker ─────────────────────────────────────────────────────────
    impl_->worker = std::make_unique<WhisperWorker>(
        impl_->model_path, impl_->use_metal, impl_->language, /*translate=*/false
    );

    // Surface transcription errors to the user via the status callback.
    impl_->worker->setOnError([this](const std::string& msg) {
        impl_->notifyStatus("⚠ " + msg);
    });

    // on_result fires (on worker thread) after every dictation chunk.
    impl_->worker->setOnResult([this](const std::string& text) {
        if (!text.empty() && impl_->on_dictation_result) {
            impl_->on_dictation_result(text);
        }
        impl_->mode.store(MODE_IDLE);
        impl_->notifyStatus("● Idle");
    });

    if (!impl_->worker->start()) {
        impl_->notifyStatus("⚠ Model not found");
        return false;
    }

    // ── ChunkAssembler (session mode) ─────────────────────────────────────────
    impl_->assembler = std::make_unique<ChunkAssembler>(
        impl_->vad, DEFAULT_CHUNK_S,
        [this](std::vector<float> chunk) {
            int64_t now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            impl_->worker->enqueue(std::move(chunk), now_ms, /*is_dictation=*/false);
        }
    );

    // ── AudioCapture ──────────────────────────────────────────────────────────
    // Started once and never stopped — eliminates the ~300ms AVAudioEngine
    // restart latency that would otherwise occur on every dictation keypress.
    bool mic_ok = impl_->capture.start([this](const float* s, size_t n) {
        int mode = impl_->mode.load(std::memory_order_relaxed);
        if (mode == MODE_DICTATING) {
            std::lock_guard<std::mutex> lock(impl_->dict_mutex);
            impl_->dict_buffer.insert(impl_->dict_buffer.end(), s, s + n);
        } else if (mode == MODE_RECORDING) {
            impl_->assembler->feed(s, n);
        }
        // IDLE and TRANSCRIBING: discard samples
    });

    if (!mic_ok) {
        impl_->notifyStatus("⚠ Mic denied");
        return false;
    }

    impl_->started = true;
    impl_->notifyStatus("● Idle");
    return true;
}

void AppController::stop() {
    if (!impl_->started) return;
    impl_->started = false;

    impl_->capture.stop();

    // Flush any active session before stopping the worker
    if (impl_->session_writer) {
        impl_->session_writer->flush();
        impl_->worker->setOutputWriter(nullptr);
        impl_->session_writer.reset();
    }

    impl_->worker->stop(); // drains queue, then joins
    impl_->mode.store(MODE_IDLE);
}

// ── Hotkey state machine ──────────────────────────────────────────────────────

void AppController::onHotkeyDown() {
    int expected = MODE_IDLE;
    if (!impl_->mode.compare_exchange_strong(expected, MODE_DICTATING))
        return; // only transition from IDLE (ignores key if RECORDING or TRANSCRIBING)

    {
        std::lock_guard<std::mutex> lock(impl_->dict_mutex);
        impl_->dict_buffer.clear();
    }
    impl_->notifyStatus("⏺ Dictating…");
}

void AppController::onHotkeyUp() {
    int expected = MODE_DICTATING;
    if (!impl_->mode.compare_exchange_strong(expected, MODE_TRANSCRIBING))
        return; // only if we were DICTATING

    std::vector<float> audio;
    {
        std::lock_guard<std::mutex> lock(impl_->dict_mutex);
        audio = std::move(impl_->dict_buffer);
    }

    // Require at least 0.5 s to avoid accidental taps
    if (audio.size() < static_cast<size_t>(CAPTURE_SAMPLE_RATE / 2)) {
        impl_->mode.store(MODE_IDLE);
        impl_->notifyStatus("● Idle");
        return;
    }

    impl_->notifyStatus("⏳ Transcribing…");

    int64_t now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    impl_->worker->enqueue(std::move(audio), now_ms, /*is_dictation=*/true);
    // Mode resets to IDLE inside the on_result callback.
}

// ── Session recording ─────────────────────────────────────────────────────────

void AppController::startSession() {
    int expected = MODE_IDLE;
    if (!impl_->mode.compare_exchange_strong(expected, MODE_RECORDING))
        return;

    // Build session ID: YYYYMMDD_HHMMSS
    time_t t = std::time(nullptr);
    struct tm tm_info;
    localtime_r(&t, &tm_info);
    char session_id[32];
    std::strftime(session_id, sizeof(session_id), "%Y%m%d_%H%M%S", &tm_info);

    impl_->session_writer = std::make_unique<OutputWriter>(
        impl_->output_dir, session_id, impl_->model_path, impl_->language
    );
    impl_->worker->setOutputWriter(impl_->session_writer.get());

    impl_->notifyStatus("🔴 Recording");
}

void AppController::stopSession() {
    int expected = MODE_RECORDING;
    if (!impl_->mode.compare_exchange_strong(expected, MODE_FINALIZING))
        return;

    impl_->notifyStatus("⏳ Finalizing…");

    // Register cleanup to run once the worker drains all queued session chunks.
    // The callback fires on the worker thread; dispatch UI updates to main queue
    // from within the callback (the caller — AppDelegate — will handle that via
    // the notifyStatus path which already dispatches to main queue).
    impl_->worker->setOnSessionDone([this] {
        impl_->worker->setOutputWriter(nullptr);
        if (impl_->session_writer) {
            impl_->session_writer->flush();
            impl_->session_writer.reset();
        }
        impl_->mode.store(MODE_IDLE);
        impl_->notifyStatus("● Idle");
    });

    // Flush any partial buffer still in the assembler (audio since last VAD flush).
    // This enqueues one more chunk to the worker before the queue drains.
    impl_->assembler->forceFlush();
    // setOnSessionDone() already notified the worker's cv; if the queue was
    // already empty (nothing was flushed, nothing was pending) the callback
    // fires immediately on the next worker loop iteration.
}

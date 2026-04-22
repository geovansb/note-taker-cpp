#include "app_controller.h"
#include "app_status.h"
#include "audio_capture.h"
#include "chunk_assembler.h"
#include "constants.h"
#include "mode_machine.h"
#include "output_writer.h"
#include "vad.h"
#include "whisper_worker.h"

#include <chrono>
#include <cstdio>
#include <ctime>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// ── Impl ──────────────────────────────────────────────────────────────────────

struct AppController::Impl {
    // Config (set at construction)
    std::string model_path;
    bool        use_metal  = false;
    std::string language;
    std::string output_dir;

    // Mode state machine — thread-safe, emits AppStatus via callback
    ModeMachine mode_machine;

    // Pipeline components
    AudioCapture                    capture;
    Vad                             vad;
    std::unique_ptr<ChunkAssembler> assembler;
    std::unique_ptr<WhisperWorker>  worker;
    std::shared_ptr<OutputWriter>   session_writer;

    // Dictation audio accumulator (written on tap thread, read on hotkey-up)
    std::vector<float> dict_buffer;
    std::mutex         dict_mutex;

    // User-facing callbacks (set before start())
    std::function<void(AppStatusEvent)> on_status;
    std::function<void(std::string)> on_dictation_result;

    // Back-pointer — valid for the lifetime of AppController
    AppController* owner = nullptr;

    bool started = false;

    void notifyStatus(AppStatus s) {
        if (on_status) on_status(AppStatusEvent(s));
    }
    void notifyStatus(AppStatus s, const std::string& detail) {
        if (on_status) on_status(AppStatusEvent(s, detail));
    }

    // Start/stop microphone on demand. Avoids keeping the mic always active,
    // which forces Bluetooth headphones into low-quality HFP telephony mode.
    bool startMic() {
        return capture.start([this](const float* s, size_t n) {
            Mode m = mode_machine.mode();
            if (m == Mode::Dictating) {
                std::lock_guard<std::mutex> lock(dict_mutex);
                dict_buffer.insert(dict_buffer.end(), s, s + n);
            } else if (m == Mode::Recording) {
                assembler->feed(s, n);
            }
        });
    }

    void stopMic() {
        capture.stop();
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
    impl_->mode_machine.setStatusCallback([this](AppStatus s) {
        impl_->notifyStatus(s);
    });
}

AppController::~AppController() {
    stop();
    delete impl_;
}

void AppController::setOnStatusChange(std::function<void(AppStatusEvent)> cb) {
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

void AppController::setOutputDir(const std::string& dir) {
    impl_->output_dir = dir;
}

void AppController::setVadSensitivity(float threshold, float gain) {
    impl_->vad.setThreshold(threshold);
    impl_->vad.setGain(gain);
}

void AppController::setSilenceTimeout(float seconds) {
    if (impl_->assembler) impl_->assembler->setSilenceTimeout(seconds);
}

bool AppController::isRecording() const {
    return impl_->mode_machine.isRecording();
}

bool AppController::start() {
    if (impl_->started) return true;

    impl_->notifyStatus(AppStatus::LoadingModel);

    // ── WhisperWorker ─────────────────────────────────────────────────────────
    impl_->worker = std::make_unique<WhisperWorker>(
        impl_->model_path, impl_->use_metal, impl_->language, /*translate=*/false
    );

    // Surface transcription errors to the user via the status callback.
    impl_->worker->setOnError([this](const std::string& msg) {
        impl_->notifyStatus(AppStatus::ErrorTranscription, msg);
    });

    // on_result fires (on worker thread) after every dictation chunk.
    impl_->worker->setOnResult([this](const std::string& text) {
        if (!text.empty() && impl_->on_dictation_result) {
            impl_->on_dictation_result(text);
        }
        impl_->mode_machine.transcriptionDone();
    });

    if (!impl_->worker->start()) {
        impl_->worker.reset(); // prevent enqueue() on a null whisper context
        impl_->notifyStatus(AppStatus::ErrorModelNotFound);
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
    impl_->assembler->setOnStateChange([this](bool capturing) {
        if (impl_->mode_machine.isRecording()) {
            impl_->notifyStatus(capturing ? AppStatus::RecordingCapturing
                                          : AppStatus::RecordingListening);
        }
    });

    // ── AudioCapture ──────────────────────────────────────────────────────────
    // Mic is started on-demand (dictation keypress / recording session start)
    // and stopped when done. This avoids keeping the mic always active, which
    // forces Bluetooth headphones into low-quality HFP telephony mode and
    // shows the orange mic indicator permanently.
    impl_->capture.setOnConfigChange([this] {
        impl_->notifyStatus(AppStatus::ErrorAudioDeviceChanged);
    });
    impl_->capture.setOnRecoveryFailed([this] {
        impl_->notifyStatus(AppStatus::ErrorGeneric,
                            "Audio recovery failed — restart required");
    });

    impl_->started = true;
    impl_->notifyStatus(AppStatus::Idle);
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
    impl_->mode_machine.reset();
}

// ── Hotkey state machine ──────────────────────────────────────────────────────

void AppController::onHotkeyDown() {
    // Reject if the controller hasn't fully started yet (model still loading).
    if (!impl_->started) return;

    {
        std::lock_guard<std::mutex> lock(impl_->dict_mutex);
        if (!impl_->mode_machine.tryDictate()) return; // emits Beep on rejection
        impl_->dict_buffer.clear();
        impl_->dict_buffer.reserve(30 * CAPTURE_SAMPLE_RATE); // 30s max dictation
    }

    // Start mic after setting mode — no audio thread is running yet,
    // so the buffer clear above doesn't need synchronisation with the tap.
    if (!impl_->startMic()) {
        impl_->mode_machine.cancelDictation(); // back to Idle
        impl_->notifyStatus(AppStatus::ErrorMicDenied);
        return;
    }
}

void AppController::onHotkeyUp() {
    if (!impl_->mode_machine.finishDictation())
        return; // only if we were DICTATING; emits Transcribing

    // Stop mic immediately — we have all the audio we need.
    impl_->stopMic();

    std::vector<float> audio;
    {
        std::lock_guard<std::mutex> lock(impl_->dict_mutex);
        audio = std::move(impl_->dict_buffer);
    }

    // Require at least 0.5 s to avoid accidental taps
    if (audio.size() < static_cast<size_t>(CAPTURE_SAMPLE_RATE / 2)) {
        impl_->mode_machine.transcriptionDone(); // back to Idle
        return;
    }

    int64_t now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    impl_->worker->enqueue(std::move(audio), now_ms, /*is_dictation=*/true);
    // Mode resets to IDLE inside the on_result callback.
}

// ── Session recording ─────────────────────────────────────────────────────────

void AppController::startSession() {
    // Build session ID and set OutputWriter BEFORE changing mode to RECORDING,
    // so the worker already has a writer when the first audio frames arrive.
    time_t t = std::time(nullptr);
    struct tm tm_info;
    localtime_r(&t, &tm_info);
    char session_id[32];
    std::strftime(session_id, sizeof(session_id), "%Y%m%d_%H%M%S", &tm_info);

    impl_->session_writer = std::make_shared<OutputWriter>(
        impl_->output_dir, session_id, impl_->model_path, impl_->language
    );
    impl_->session_writer->setOnError([this](const std::string& msg) {
        impl_->notifyStatus(AppStatus::ErrorGeneric, msg);
    });
    impl_->worker->setOutputWriter(impl_->session_writer);

    if (!impl_->mode_machine.tryRecord()) {
        // Another mode was active — roll back.
        impl_->worker->setOutputWriter(nullptr);
        impl_->session_writer.reset();
        return;
    }

    if (!impl_->startMic()) {
        impl_->mode_machine.reset(); // back to Idle
        impl_->worker->setOutputWriter(nullptr);
        impl_->session_writer.reset();
        impl_->notifyStatus(AppStatus::ErrorMicDenied);
        return;
    }
    // RecordingListening status emitted by ModeMachine
}

void AppController::stopSession() {
    if (!impl_->mode_machine.stopRecord())
        return; // Finalizing status emitted by ModeMachine

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
        impl_->mode_machine.finalizeDone(); // back to Idle
    });

    // Flush any partial buffer still in the assembler (audio since last VAD flush).
    // This enqueues one more chunk to the worker before the queue drains.
    impl_->assembler->forceFlush();

    // Release mic now — all audio has been captured and flushed.
    impl_->stopMic();
}

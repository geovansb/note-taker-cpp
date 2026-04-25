#include "app_controller.h"
#include "app_logger.h"
#include "app_status.h"
#include "audio_capture.h"
#include "chunk_assembler.h"
#include "constants.h"
#include "mode_machine.h"
#include "output_writer.h"
#include "vad.h"
#include "whisper_worker.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <ctime>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
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

    std::atomic<bool> started{false};

    // Guards async mic startup for dictation: set true in onHotkeyDown,
    // false in onHotkeyUp. The background thread checks before/after
    // startMic to avoid starting or leaving the mic active after the
    // user has already released the key.
    std::atomic<bool> mic_wanted{false};
    std::atomic<bool> shutting_down{false};
    std::mutex        mic_mutex;
    std::mutex        mic_request_mutex;
    std::condition_variable mic_cv;
    std::thread       mic_control_thread;
    bool              mic_start_requested = false;
    bool              mic_thread_stop = false;
    bool              mic_running = false;

    void notifyStatus(AppStatus s) {
        if (on_status) on_status(AppStatusEvent(s));
    }
    void notifyStatus(AppStatus s, const std::string& detail) {
        if (on_status) on_status(AppStatusEvent(s, detail));
    }

    void notifyMicStartFailure() {
        AudioStartError error = capture.lastStartError();
        if (error == AudioStartError::PermissionDenied) {
            NT_LOG_ERROR("audio", "microphone permission denied");
            notifyStatus(AppStatus::ErrorMicDenied);
            return;
        }

        const char* detail = "Microphone is allowed, but audio input failed to start";
        if (error == AudioStartError::InvalidDeviceFormat) {
            detail = "Audio input device is not ready";
        } else if (error == AudioStartError::ConverterFailed) {
            detail = "Audio format conversion could not be initialized";
        } else if (error == AudioStartError::TapInstallFailed) {
            detail = "Audio input tap could not be installed";
        } else if (error == AudioStartError::EngineStartFailed) {
            detail = "Audio engine could not be started";
        }
        NT_LOG_ERROR("audio", "%s", detail);
        notifyStatus(AppStatus::ErrorGeneric, detail);
    }

    // Start/stop microphone on demand. Avoids keeping the mic always active,
    // which forces Bluetooth headphones into low-quality HFP telephony mode.
    bool startMic() {
        std::lock_guard<std::mutex> lock(mic_mutex);
        if (mic_running) return true;

        bool started = capture.start([this](const float* s, size_t n) {
            Mode m = mode_machine.mode();
            if (m == Mode::Dictating) {
                std::lock_guard<std::mutex> lock(dict_mutex);
                dict_buffer.insert(dict_buffer.end(), s, s + n);
            } else if (m == Mode::Recording) {
                assembler->feed(s, n);
            }
        });
        mic_running = started;
        NT_LOG_DEBUG("audio", "microphone start requested result=%s", started ? "ok" : "failed");
        return started;
    }

    void stopMic() {
        std::lock_guard<std::mutex> lock(mic_mutex);
        if (!mic_running) return;
        capture.stop();
        mic_running = false;
        NT_LOG_DEBUG("audio", "microphone stopped");
    }

    void startMicControlThread() {
        {
            std::lock_guard<std::mutex> lock(mic_request_mutex);
            mic_thread_stop = false;
            mic_start_requested = false;
        }

        mic_control_thread = std::thread([this] {
            std::unique_lock<std::mutex> lock(mic_request_mutex);
            while (true) {
                mic_cv.wait(lock, [this] {
                    return mic_thread_stop || mic_start_requested;
                });

                if (mic_thread_stop) break;
                mic_start_requested = false;
                lock.unlock();

                if (!mic_wanted.load(std::memory_order_acquire) ||
                    shutting_down.load(std::memory_order_acquire)) {
                    lock.lock();
                    continue;
                }

                if (!startMic()) {
                    if (!shutting_down.load(std::memory_order_acquire) &&
                        mic_wanted.load(std::memory_order_acquire)) {
                        mode_machine.cancelDictation(); // back to Idle
                        notifyMicStartFailure();
                    }
                    lock.lock();
                    continue;
                }

                // If the key was released while startup was in flight, stop the
                // mic once startMic() returns instead of leaving capture active.
                if (!mic_wanted.load(std::memory_order_acquire) ||
                    shutting_down.load(std::memory_order_acquire)) {
                    stopMic();
                }

                lock.lock();
            }
        });
    }

    void stopMicControlThread() {
        {
            std::lock_guard<std::mutex> lock(mic_request_mutex);
            mic_thread_stop = true;
            mic_start_requested = false;
        }
        mic_cv.notify_all();

        if (mic_control_thread.joinable()) mic_control_thread.join();
    }

    void requestMicStartForDictation() {
        {
            std::lock_guard<std::mutex> lock(mic_request_mutex);
            mic_start_requested = true;
        }
        mic_cv.notify_one();
    }

    void flushSessionTail() {
        if (assembler) assembler->forceFlush();
    }

    void closeSessionWriter() {
        if (worker) worker->setOutputWriter(nullptr);
        if (session_writer) {
            session_writer->flush();
            session_writer.reset();
        }
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
    if (impl_->started.load(std::memory_order_acquire)) return true;
    NT_LOG_WARN("controller", "starting controller model=%s language=%s output_dir=%s metal=%s",
                impl_->model_path.c_str(), impl_->language.c_str(),
                impl_->output_dir.c_str(), impl_->use_metal ? "true" : "false");
    impl_->shutting_down.store(false, std::memory_order_release);
    impl_->startMicControlThread();

    impl_->notifyStatus(AppStatus::LoadingModel);

    // ── WhisperWorker ─────────────────────────────────────────────────────────
    impl_->worker = std::make_unique<WhisperWorker>(
        impl_->model_path, impl_->use_metal, impl_->language, /*translate=*/false
    );

    // Surface transcription errors to the user via the status callback.
    impl_->worker->setOnError([this](const std::string& msg) {
        NT_LOG_WARN("whisper", "worker error: %s", msg.c_str());
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
        impl_->stopMicControlThread();
        NT_LOG_ERROR("controller", "failed to start worker model=%s", impl_->model_path.c_str());
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
        NT_LOG_WARN("audio", "audio device configuration changed");
        impl_->notifyStatus(AppStatus::ErrorAudioDeviceChanged);
    });
    impl_->capture.setOnRecoveryFailed([this] {
        NT_LOG_ERROR("audio", "audio recovery failed; restart required");
        impl_->notifyStatus(AppStatus::ErrorGeneric,
                            "Audio recovery failed — restart required");
    });

    impl_->started.store(true, std::memory_order_release);
    NT_LOG_WARN("controller", "controller started");
    impl_->notifyStatus(AppStatus::Idle);
    return true;
}

void AppController::stop() {
    if (!impl_->started.exchange(false, std::memory_order_acq_rel)) return;
    NT_LOG_WARN("controller", "stopping controller");
    impl_->mic_wanted.store(false, std::memory_order_release);
    impl_->shutting_down.store(true, std::memory_order_release);
    impl_->stopMicControlThread();

    impl_->stopMic();

    // Stop any pending finalize callback first. During shutdown we want one
    // synchronous drain path, not a concurrent on_session_done callback racing
    // against teardown.
    if (impl_->worker) impl_->worker->setOnSessionDone({});

    // If a recording session is active or finalizing, push the last buffered
    // audio into the worker queue before draining it.
    if (impl_->session_writer) {
        impl_->flushSessionTail();
    }

    if (impl_->worker) {
        impl_->worker->stop(); // drains queue, then joins
    }
    impl_->closeSessionWriter();
    impl_->mode_machine.reset();
    NT_LOG_WARN("controller", "controller stopped");
}

// ── Hotkey state machine ──────────────────────────────────────────────────────

void AppController::onHotkeyDown() {
    // Reject if the controller hasn't fully started yet (model still loading).
    if (!impl_->started.load(std::memory_order_acquire)) return;
    NT_LOG_DEBUG("dictation", "hotkey down");

    {
        std::lock_guard<std::mutex> lock(impl_->dict_mutex);
        if (!impl_->mode_machine.tryDictate()) return; // emits Beep on rejection
        impl_->dict_buffer.clear();
        impl_->dict_buffer.reserve(30 * CAPTURE_SAMPLE_RATE); // 30s max dictation
    }

    // Start mic on a background thread so the EventTap run loop stays
    // responsive. If we blocked here (~300ms for AVAudioEngine init), the
    // key-up event would queue and fire immediately after, capturing zero audio.
    impl_->mic_wanted.store(true, std::memory_order_release);
    impl_->requestMicStartForDictation();
}

void AppController::onHotkeyUp() {
    if (!impl_->mode_machine.finishDictation())
        return; // only if we were DICTATING; emits Transcribing
    NT_LOG_DEBUG("dictation", "hotkey up");

    // Signal the background thread that we no longer need the mic.
    impl_->mic_wanted.store(false, std::memory_order_release);

    // Stop mic if it's already running (if the background thread finished
    // before we got here). If not started yet, the background thread will
    // see mic_wanted=false and clean up.
    impl_->stopMic();

    std::vector<float> audio;
    {
        std::lock_guard<std::mutex> lock(impl_->dict_mutex);
        audio = std::move(impl_->dict_buffer);
    }

    // Keep the accidental-tap filter, but lower it now that dictation starts
    // the mic on demand and pays the AVAudioEngine warm-up cost on key-down.
    if (audio.size() < static_cast<size_t>(CAPTURE_SAMPLE_RATE * MIN_DICTATION_S)) {
        NT_LOG_DEBUG("dictation", "discarded short dictation samples=%zu", audio.size());
        impl_->mode_machine.transcriptionDone(); // back to Idle
        return;
    }

    int64_t now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    NT_LOG_DEBUG("dictation", "queued dictation samples=%zu", audio.size());
    impl_->worker->enqueue(std::move(audio), now_ms, /*is_dictation=*/true);
    // Mode resets to IDLE inside the on_result callback.
}

// ── Session recording ─────────────────────────────────────────────────────────

void AppController::startSession() {
    impl_->mic_wanted.store(false, std::memory_order_release);
    NT_LOG_WARN("recording", "start session requested output_dir=%s", impl_->output_dir.c_str());

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
        NT_LOG_WARN("recording", "start session rejected by mode machine");
        impl_->worker->setOutputWriter(nullptr);
        impl_->session_writer.reset();
        return;
    }

    if (!impl_->startMic()) {
        NT_LOG_ERROR("recording", "failed to start microphone for recording session_id=%s", session_id);
        impl_->mode_machine.reset(); // back to Idle
        impl_->worker->setOutputWriter(nullptr);
        impl_->session_writer.reset();
        impl_->notifyMicStartFailure();
        return;
    }
    // RecordingListening status emitted by ModeMachine
}

void AppController::stopSession() {
    if (!impl_->mode_machine.stopRecord())
        return; // Finalizing status emitted by ModeMachine
    NT_LOG_WARN("recording", "stop session requested");

    // Stop the producer first so no more callbacks can append to the assembler
    // while we are flushing and waiting for the worker queue to drain.
    impl_->stopMic();

    // Flush any partial buffer still in the assembler (audio since last VAD flush)
    // before arming the drain callback. Otherwise the worker can observe an empty
    // queue and finalize the session before the tail chunk is enqueued.
    impl_->flushSessionTail();

    // Register cleanup to run once the worker drains all queued session chunks.
    // The callback fires on the worker thread; AppDelegate already dispatches
    // UI work to the main queue through notifyStatus.
    impl_->worker->setOnSessionDone([this] {
        NT_LOG_WARN("recording", "session worker queue drained");
        impl_->closeSessionWriter();
        impl_->mode_machine.finalizeDone(); // back to Idle
    });
}

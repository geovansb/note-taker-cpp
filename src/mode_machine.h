#pragma once
#include "app_status.h"
#include <atomic>
#include <functional>

enum class Mode {
    Idle         = 0,
    Dictating    = 1,
    Transcribing = 2,
    Recording    = 3,
    Finalizing   = 4,
};

// Pure state machine for the app's operating mode.
// Thread-safe: all transitions use atomic CAS.
// Emits AppStatus via callback on each successful transition (and Beep on
// rejected dictation attempts).
class ModeMachine {
public:
    using StatusCb = std::function<void(AppStatus)>;

    // Set the callback invoked on every state transition.
    // Must be called before any transition method.
    void setStatusCallback(StatusCb cb) { on_status_ = std::move(cb); }

    // IDLE → DICTATING. Returns false (+ Beep) if not IDLE.
    bool tryDictate();

    // DICTATING → IDLE. For short-buffer rejection.
    bool cancelDictation();

    // DICTATING → TRANSCRIBING.
    bool finishDictation();

    // TRANSCRIBING → IDLE. Called when on_result fires.
    void transcriptionDone();

    // IDLE → RECORDING.
    bool tryRecord();

    // RECORDING → FINALIZING.
    bool stopRecord();

    // FINALIZING → IDLE. Called when on_session_done fires.
    void finalizeDone();

    // Force to IDLE from any state. Used by stop().
    void reset();

    Mode mode() const { return static_cast<Mode>(state_.load(std::memory_order_relaxed)); }
    bool isRecording() const { return mode() == Mode::Recording; }
    bool isDictating() const { return mode() == Mode::Dictating; }

private:
    std::atomic<int> state_ { static_cast<int>(Mode::Idle) };
    StatusCb on_status_;

    void emit(AppStatus s) { if (on_status_) on_status_(s); }
};

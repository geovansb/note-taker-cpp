#pragma once
#include <functional>
#include <string>

// Central controller for note-taker-bar.
// Owns the full audio pipeline: AudioCapture → ChunkAssembler/dictation buffer
// → WhisperWorker → OutputWriter (session) / on_result callback (dictation).
// Also owns the EventTap for the Right Option push-to-talk hotkey.
//
// Thread model:
//   start() / stop() / startSession() / stopSession() — any thread (typically main)
//   EventTap callbacks → onHotkeyDown() / onHotkeyUp() — CFRunLoop thread
//   AudioCapture callback — AVAudioEngine tap thread
//   on_status / on_dictation_result — called from worker or tap thread; caller
//     is responsible for dispatching to main thread if UI updates are needed.
class AppController {
public:
    AppController(const std::string& model_path,
                  bool               use_metal,
                  const std::string& language,
                  const std::string& output_dir);
    ~AppController();

    AppController(const AppController&) = delete;
    AppController& operator=(const AppController&) = delete;

    // Load model, start AudioCapture and EventTap.
    // Calls on_status with "⏳ Loading model…" then "● Idle" (or "⚠ …" on failure).
    // Returns false on model load or mic permission failure.
    bool start();
    void stop();

    // Toggle session recording (VAD-based, writes JSON/TXT to output_dir).
    // startSession() is a no-op unless current mode is IDLE.
    // stopSession() is a no-op unless current mode is RECORDING.
    void startSession();
    void stopSession();

    // Called by AppDelegate to determine if recording is active.
    bool isRecording() const;

    // Hotkey callbacks — forwarded from AppDelegate's EventTap (CFRunLoop thread).
    void onHotkeyDown();
    void onHotkeyUp();

    // Status change callback — called from any thread with a UTF-8 status string.
    // Typical values: "● Idle", "⏺ Dictating…", "⏳ Transcribing…", "🔴 Recording",
    //                 "⏳ Loading model…", "⚠ Model not found", "⚠ Mic denied".
    void setOnStatusChange(std::function<void(std::string)> cb);

    // Dictation result callback — called from the worker thread with transcribed text.
    // AppDelegate uses this to invoke TextInjector (T4.4). Default: no-op.
    void setOnDictationResult(std::function<void(std::string)> cb);

private:
    struct Impl;
    Impl* impl_;
};

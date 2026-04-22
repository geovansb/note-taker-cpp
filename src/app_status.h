#pragma once
#include <string>

// Type-safe status for communication between AppController and AppDelegate.
// Replaces the previous magic-string protocol — all states are compile-time
// checked and the display label is produced in a single place.
enum class AppStatus {
    Idle,
    LoadingModel,
    Dictating,
    Transcribing,
    RecordingListening,   // session active, waiting for speech
    RecordingCapturing,   // session active, speech detected
    Finalizing,
    Beep,                 // synthetic: play error sound, don't change display
    RecordingSaved,       // transient: shown after session finalize → idle

    // Errors — carry an optional detail message via AppStatusEvent.
    ErrorModelNotFound,
    ErrorMicDenied,
    ErrorAudioDeviceChanged,
    ErrorTranscription,   // whisper_full failure or queue overflow
    ErrorGeneric,
};

// Bundles a status with an optional detail string (used for Error* states).
struct AppStatusEvent {
    AppStatus   status;
    std::string detail;   // empty for non-error states

    explicit AppStatusEvent(AppStatus s) : status(s) {}
    AppStatusEvent(AppStatus s, std::string d) : status(s), detail(std::move(d)) {}
};

// Human-readable label for display in the menu bar status item.
inline std::string statusLabel(AppStatus s) {
    switch (s) {
        case AppStatus::Idle:                  return "● Idle";
        case AppStatus::LoadingModel:          return "⏳ Loading model…";
        case AppStatus::Dictating:             return "⏺ Dictating…";
        case AppStatus::Transcribing:          return "⏳ Transcribing…";
        case AppStatus::RecordingListening:    return "🔴 Listening…";
        case AppStatus::RecordingCapturing:    return "🔴 Capturing…";
        case AppStatus::Finalizing:            return "⏳ Finalizing…";
        case AppStatus::Beep:                  return "";
        case AppStatus::RecordingSaved:        return "✓ Recording saved";
        case AppStatus::ErrorModelNotFound:    return "⚠ Model not found";
        case AppStatus::ErrorMicDenied:        return "⚠ Mic denied";
        case AppStatus::ErrorAudioDeviceChanged: return "⚠ Audio device changed";
        case AppStatus::ErrorTranscription:    return "⚠ Transcription error";
        case AppStatus::ErrorGeneric:          return "⚠ Error";
    }
    return "● Idle";
}

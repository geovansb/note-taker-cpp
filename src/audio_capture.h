#pragma once
#include <functional>
#include <string>
#include <vector>

// Captures microphone audio via AVAudioEngine.
// Delivers float32 mono samples at CAPTURE_SAMPLE_RATE to on_block callback.
// on_block is called from AVAudioEngine's internal audio thread — keep it fast.
class AudioCapture {
public:
    AudioCapture();
    ~AudioCapture();

    AudioCapture(const AudioCapture&) = delete;
    AudioCapture& operator=(const AudioCapture&) = delete;

    // Requests mic permission, starts engine, installs tap.
    // Returns false if permission denied or engine fails to start.
    bool start(std::function<void(const float*, size_t)> on_block);
    void stop();

    // Enumerates audio input devices. Format: "<idx>: <name> [<uid>]"
    static std::vector<std::string> listDevices();

private:
    struct Impl;
    Impl* impl_;
};

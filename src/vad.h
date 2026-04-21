#pragma once
#include <atomic>
#include <cstddef>

// Voice Activity Detection via RMS threshold.
// Applies input gain to samples before computing RMS.
// Thread-safe: setters may be called from any thread while isSpeech() runs
// on the audio thread.
class Vad {
public:
    bool isSpeech(const float* samples, size_t n) const;

    void setThreshold(float t) { threshold_.store(t, std::memory_order_relaxed); }
    void setGain(float g)      { gain_.store(g, std::memory_order_relaxed); }
    float threshold() const    { return threshold_.load(std::memory_order_relaxed); }
    float gain() const         { return gain_.load(std::memory_order_relaxed); }

private:
    std::atomic<float> threshold_ { 0.015f };  // default VAD_RMS_THRESHOLD
    std::atomic<float> gain_      { 1.3f };    // default INPUT_GAIN
};

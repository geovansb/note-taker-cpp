#pragma once
#include <cstddef>

// Voice Activity Detection via RMS threshold.
// Applies input gain to samples before computing RMS.
class Vad {
public:
    bool isSpeech(const float* samples, size_t n) const;

    void setThreshold(float t) { threshold_ = t; }
    void setGain(float g)      { gain_ = g; }
    float threshold() const    { return threshold_; }
    float gain() const         { return gain_; }

private:
    float threshold_ = 0.015f;  // default VAD_RMS_THRESHOLD
    float gain_      = 1.3f;    // default INPUT_GAIN
};

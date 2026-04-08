#pragma once
#include <cstddef>

// Voice Activity Detection via RMS threshold.
// Applies INPUT_GAIN to samples before computing RMS.
class Vad {
public:
    bool isSpeech(const float* samples, size_t n) const;
};

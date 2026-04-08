#pragma once
#include <cstddef>
#include <string>

// Writes a mono float32 sample buffer to a RIFF WAV file (16-bit PCM).
// Clamps samples to [-1.0, 1.0] before quantisation.
void writeWav(const std::string& path,
              const float*       samples,
              size_t             n,
              int                sample_rate);

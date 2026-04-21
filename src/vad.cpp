#include "vad.h"
#include <cmath>

bool Vad::isSpeech(const float* samples, size_t n) const {
    if (n == 0) return false;

    const float g = gain_.load(std::memory_order_relaxed);
    double sum = 0.0;
    for (size_t i = 0; i < n; ++i) {
        double s = samples[i] * g;
        sum += s * s;
    }
    float rms = static_cast<float>(std::sqrt(sum / n));
    return rms >= threshold_.load(std::memory_order_relaxed);
}

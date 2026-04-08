#include "vad.h"
#include "constants.h"
#include <cmath>

bool Vad::isSpeech(const float* samples, size_t n) const {
    if (n == 0) return false;

    double sum = 0.0;
    for (size_t i = 0; i < n; ++i) {
        double s = samples[i] * INPUT_GAIN;
        sum += s * s;
    }
    float rms = static_cast<float>(std::sqrt(sum / n));
    return rms >= VAD_RMS_THRESHOLD;
}

#include <cassert>
#include <cstdio>
#include <vector>
#include "vad.h"
#include "constants.h"

int main() {
    Vad vad;

    // Silent buffer: all zeros → RMS = 0 → no speech
    std::vector<float> silent(1024, 0.0f);
    assert(!vad.isSpeech(silent.data(), silent.size()) && "silent buffer must not be speech");

    // Loud buffer: constant value well above threshold (after gain)
    // Need RMS * INPUT_GAIN >= VAD_RMS_THRESHOLD
    // Use 0.1f which gives RMS = 0.1 * 1.3 = 0.13 >> 0.015
    std::vector<float> loud(1024, 0.1f);
    assert(vad.isSpeech(loud.data(), loud.size()) && "loud buffer must be speech");

    // Edge: empty buffer → no speech
    assert(!vad.isSpeech(nullptr, 0) && "empty buffer must not be speech");

    // Just below threshold: value that keeps RMS * gain just under threshold
    // VAD_RMS_THRESHOLD / INPUT_GAIN = 0.015 / 1.3 ≈ 0.01154
    // Use 0.01f → RMS = 0.01, after gain = 0.013 < 0.015 → no speech
    std::vector<float> quiet(1024, 0.01f);
    assert(!vad.isSpeech(quiet.data(), quiet.size()) && "sub-threshold buffer must not be speech");

    std::puts("vad_test: all assertions passed");
    return 0;
}

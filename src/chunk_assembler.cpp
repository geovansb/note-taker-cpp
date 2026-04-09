#include "chunk_assembler.h"
#include "constants.h"
#include <utility>

ChunkAssembler::ChunkAssembler(Vad& vad, float max_chunk_s, OnChunkCb on_chunk)
    : vad_(vad), max_chunk_s_(max_chunk_s), on_chunk_(std::move(on_chunk)) {}

void ChunkAssembler::feed(const float* samples, size_t n) {
    if (n == 0) return;

    bool is_speech = vad_.isSpeech(samples, n);
    std::vector<float> to_emit;

    {
        std::lock_guard<std::mutex> lock(mutex_);

        if (state_ == State::LISTENING) {
            if (is_speech) {
                state_ = State::RECORDING;
                silence_samples_ = 0;
                buffer_.insert(buffer_.end(), samples, samples + n);
            }
            // Discard non-speech blocks in LISTENING state.

        } else { // RECORDING
            buffer_.insert(buffer_.end(), samples, samples + n);

            if (is_speech) {
                silence_samples_ = 0;
            } else {
                silence_samples_ += n;
            }

            float total_s   = static_cast<float>(buffer_.size()) / CAPTURE_SAMPLE_RATE;
            float silence_s = static_cast<float>(silence_samples_) / CAPTURE_SAMPLE_RATE;
            float min_s     = static_cast<float>(MIN_CHUNK_MS) / 1000.0f;

            bool silence_flush = (silence_s >= silence_timeout_s_ && total_s >= min_s);
            bool hard_flush    = (total_s >= max_chunk_s_);

            if (silence_flush || hard_flush) {
                flush(to_emit);
            }
        }
    }

    if (!to_emit.empty()) {
        on_chunk_(std::move(to_emit));
    }
}

bool ChunkAssembler::forceFlush() {
    // Require at least ~0.5 s to avoid transcribing near-empty noise buffers.
    constexpr size_t kMinSamples = CAPTURE_SAMPLE_RATE / 2;
    std::vector<float> to_emit;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (buffer_.size() < kMinSamples) return false;
        flush(to_emit);
    }
    on_chunk_(std::move(to_emit));
    return true;
}

// Called with mutex held. Moves buffer into out and resets state.
void ChunkAssembler::flush(std::vector<float>& out) {
    out = std::move(buffer_);
    buffer_.clear();
    silence_samples_ = 0;
    state_ = State::LISTENING;
}

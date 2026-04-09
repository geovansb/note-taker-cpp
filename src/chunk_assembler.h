#pragma once
#include <functional>
#include <mutex>
#include <vector>
#include "vad.h"

// Assembles a stream of float32 audio blocks into speech chunks.
//
// State machine:
//   LISTENING → RECORDING  when VAD detects speech
//   RECORDING → LISTENING  when silence >= SILENCE_TIMEOUT_S
//                          AND chunk >= MIN_CHUNK_MS
//   RECORDING → LISTENING  (hard flush) when chunk >= max_chunk_s
//
// feed() is safe to call from the AVAudioEngine tap thread.
// on_chunk is invoked from feed() (i.e. on the tap thread) outside the mutex.
class ChunkAssembler {
public:
    using OnChunkCb = std::function<void(std::vector<float>)>;
    using OnStateCb = std::function<void(bool capturing)>;

    ChunkAssembler(Vad& vad, float max_chunk_s, OnChunkCb on_chunk);

    void feed(const float* samples, size_t n);

    void setSilenceTimeout(float seconds) { silence_timeout_s_ = seconds; }
    float silenceTimeout() const { return silence_timeout_s_; }

    // Called on the tap thread when state transitions between LISTENING ↔ RECORDING.
    void setOnStateChange(OnStateCb cb) { on_state_ = std::move(cb); }

    // Emit the current buffer immediately, regardless of VAD or silence state.
    // Useful when recording stops and a partial chunk would otherwise be lost.
    // Returns true if a chunk was emitted (buffer had enough samples), false if
    // the buffer was empty or below the minimum threshold (~0.5 s).
    bool forceFlush();

private:
    void flush(std::vector<float>& out);

    Vad&        vad_;
    float       max_chunk_s_;
    float       silence_timeout_s_ = 5.0f;  // default SILENCE_TIMEOUT_S
    OnChunkCb   on_chunk_;
    OnStateCb   on_state_;

    enum class State { LISTENING, RECORDING };
    State  state_           = State::LISTENING;
    size_t silence_samples_ = 0;

    std::vector<float> buffer_;
    std::mutex         mutex_;
};

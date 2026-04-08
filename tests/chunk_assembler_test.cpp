#include <cassert>
#include <cstdio>
#include <vector>
#include "chunk_assembler.h"
#include "constants.h"

// Fills a buffer with a value, feeds it to the assembler as blocks of block_size.
static void feedValue(ChunkAssembler& ca, float value, float duration_s,
                      size_t block_size = 512) {
    size_t total = static_cast<size_t>(duration_s * CAPTURE_SAMPLE_RATE);
    std::vector<float> block(block_size, value);
    for (size_t fed = 0; fed < total; fed += block_size) {
        size_t n = std::min(block_size, total - fed);
        block.assign(n, value);
        ca.feed(block.data(), n);
    }
}

int main() {
    Vad vad;

    // --- Test 1: speech followed by silence emits one chunk ---
    {
        std::vector<std::vector<float>> chunks;
        ChunkAssembler ca(vad, DEFAULT_CHUNK_S,
                          [&](std::vector<float> c) { chunks.push_back(std::move(c)); });

        feedValue(ca, 0.1f, 1.0f);  // 1s of speech (loud)
        feedValue(ca, 0.0f, SILENCE_TIMEOUT_S + 0.1f); // silence > timeout

        assert(chunks.size() == 1 && "expected exactly one chunk");
        float dur_s = static_cast<float>(chunks[0].size()) / CAPTURE_SAMPLE_RATE;
        // Chunk should be ~1s speech + silence tail
        assert(dur_s >= 1.0f && "chunk too short");
        printf("test1: chunk duration = %.2fs  OK\n", dur_s);
    }

    // --- Test 2: short silence does NOT flush before MIN_CHUNK_MS ---
    {
        std::vector<std::vector<float>> chunks;
        ChunkAssembler ca(vad, DEFAULT_CHUNK_S,
                          [&](std::vector<float> c) { chunks.push_back(std::move(c)); });

        // Feed only a tiny speech burst (<MIN_CHUNK_MS) then long silence
        feedValue(ca, 0.1f, 0.5f);   // 500ms speech < MIN_CHUNK_MS (2000ms)
        feedValue(ca, 0.0f, SILENCE_TIMEOUT_S + 0.1f);

        // Should not flush because chunk < MIN_CHUNK_MS even with enough silence
        assert(chunks.empty() && "should not flush below MIN_CHUNK_MS");
        printf("test2: no premature flush  OK\n");
    }

    // --- Test 3: hard flush at max_chunk_s ---
    {
        std::vector<std::vector<float>> chunks;
        float max_s = 2.0f;
        ChunkAssembler ca(vad, max_s,
                          [&](std::vector<float> c) { chunks.push_back(std::move(c)); });

        feedValue(ca, 0.1f, max_s + 0.2f); // speech longer than max

        assert(chunks.size() >= 1 && "hard flush must have fired");
        float dur_s = static_cast<float>(chunks[0].size()) / CAPTURE_SAMPLE_RATE;
        assert(dur_s <= max_s + 0.1f && "chunk exceeded max_chunk_s");
        printf("test3: hard flush at %.2fs  OK\n", dur_s);
    }

    puts("chunk_assembler_test: all assertions passed");
    return 0;
}

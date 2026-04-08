#include "wav_writer.h"
#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

static void write_le16(FILE* f, uint16_t v) {
    uint8_t b[2] = {static_cast<uint8_t>(v & 0xFF),
                    static_cast<uint8_t>((v >> 8) & 0xFF)};
    fwrite(b, 1, 2, f);
}

static void write_le32(FILE* f, uint32_t v) {
    uint8_t b[4] = {static_cast<uint8_t>(v & 0xFF),
                    static_cast<uint8_t>((v >> 8) & 0xFF),
                    static_cast<uint8_t>((v >> 16) & 0xFF),
                    static_cast<uint8_t>((v >> 24) & 0xFF)};
    fwrite(b, 1, 4, f);
}

void writeWav(const std::string& path,
              const float*       samples,
              size_t             n,
              int                sample_rate) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) {
        fprintf(stderr, "warn: writeWav: cannot open %s: %s\n",
                path.c_str(), strerror(errno));
        return;
    }

    const uint32_t num_channels  = 1;
    const uint32_t bits_per_sample = 16;
    const uint32_t byte_rate     = static_cast<uint32_t>(sample_rate) * num_channels * (bits_per_sample / 8);
    const uint32_t block_align   = num_channels * (bits_per_sample / 8);
    const uint32_t data_size     = static_cast<uint32_t>(n) * block_align;
    const uint32_t chunk_size    = 36 + data_size;

    // RIFF header
    fwrite("RIFF", 1, 4, f);
    write_le32(f, chunk_size);
    fwrite("WAVE", 1, 4, f);

    // fmt  sub-chunk
    fwrite("fmt ", 1, 4, f);
    write_le32(f, 16);                              // sub-chunk size
    write_le16(f, 1);                               // PCM
    write_le16(f, static_cast<uint16_t>(num_channels));
    write_le32(f, static_cast<uint32_t>(sample_rate));
    write_le32(f, byte_rate);
    write_le16(f, static_cast<uint16_t>(block_align));
    write_le16(f, static_cast<uint16_t>(bits_per_sample));

    // data sub-chunk
    fwrite("data", 1, 4, f);
    write_le32(f, data_size);

    // Samples: float32 → int16
    for (size_t i = 0; i < n; ++i) {
        float  s = std::max(-1.0f, std::min(1.0f, samples[i]));
        int16_t v = static_cast<int16_t>(s * 32767.0f);
        write_le16(f, static_cast<uint16_t>(v));
    }

    fclose(f);
}

#include "wav_writer.h"
#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>


static bool write_le16(FILE* f, uint16_t v) {
    uint8_t b[2] = {static_cast<uint8_t>(v & 0xFF),
                    static_cast<uint8_t>((v >> 8) & 0xFF)};
    return fwrite(b, 1, 2, f) == 2;
}

static bool write_le32(FILE* f, uint32_t v) {
    uint8_t b[4] = {static_cast<uint8_t>(v & 0xFF),
                    static_cast<uint8_t>((v >> 8) & 0xFF),
                    static_cast<uint8_t>((v >> 16) & 0xFF),
                    static_cast<uint8_t>((v >> 24) & 0xFF)};
    return fwrite(b, 1, 4, f) == 4;
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

    bool ok = true;

    // RIFF header
    ok = ok && fwrite("RIFF", 1, 4, f) == 4;
    ok = ok && write_le32(f, chunk_size);
    ok = ok && fwrite("WAVE", 1, 4, f) == 4;

    // fmt  sub-chunk
    ok = ok && fwrite("fmt ", 1, 4, f) == 4;
    ok = ok && write_le32(f, 16);                              // sub-chunk size
    ok = ok && write_le16(f, 1);                               // PCM
    ok = ok && write_le16(f, static_cast<uint16_t>(num_channels));
    ok = ok && write_le32(f, static_cast<uint32_t>(sample_rate));
    ok = ok && write_le32(f, byte_rate);
    ok = ok && write_le16(f, static_cast<uint16_t>(block_align));
    ok = ok && write_le16(f, static_cast<uint16_t>(bits_per_sample));

    // data sub-chunk
    ok = ok && fwrite("data", 1, 4, f) == 4;
    ok = ok && write_le32(f, data_size);

    // Samples: float32 → int16
    for (size_t i = 0; i < n && ok; ++i) {
        float  s = std::max(-1.0f, std::min(1.0f, samples[i]));
        int16_t v = static_cast<int16_t>(s * 32767.0f);
        ok = ok && write_le16(f, static_cast<uint16_t>(v));
    }

    if (!ok) {
        fprintf(stderr, "warn: writeWav: short write to %s: %s\n",
                path.c_str(), strerror(errno));
    }

    fclose(f);
}

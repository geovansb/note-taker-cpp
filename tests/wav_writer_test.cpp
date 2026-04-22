#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include <vector>

#include "wav_writer.h"

static std::string makeTmpPath() {
    char tpl[] = "/tmp/wav_writer_test_XXXXXX";
    int fd = mkstemp(tpl);
    assert(fd >= 0);
    close(fd);
    return std::string(tpl);
}

// Read a little-endian uint16 from a byte buffer.
static uint16_t readLE16(const uint8_t* p) {
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

// Read a little-endian uint32 from a byte buffer.
static uint32_t readLE32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0])
         | (static_cast<uint32_t>(p[1]) << 8)
         | (static_cast<uint32_t>(p[2]) << 16)
         | (static_cast<uint32_t>(p[3]) << 24);
}

// Read a little-endian int16 from a byte buffer.
static int16_t readLE16s(const uint8_t* p) {
    return static_cast<int16_t>(readLE16(p));
}

static std::vector<uint8_t> readFile(const std::string& path) {
    FILE* f = fopen(path.c_str(), "rb");
    assert(f && "file must exist");
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> buf(static_cast<size_t>(sz));
    size_t n = fread(buf.data(), 1, buf.size(), f);
    assert(n == buf.size());
    fclose(f);
    return buf;
}

// ── Test 1: RIFF header structure ────────────────────────────────────────────

static void test_header() {
    std::string path = makeTmpPath();
    float samples[] = {0.0f, 0.5f, -0.5f, 1.0f};
    writeWav(path, samples, 4, 16000);

    auto buf = readFile(path);
    const uint8_t* d = buf.data();

    // RIFF header
    assert(memcmp(d, "RIFF", 4) == 0);
    uint32_t chunk_size = readLE32(d + 4);
    assert(chunk_size == buf.size() - 8);  // file size - 8
    assert(memcmp(d + 8, "WAVE", 4) == 0);

    // fmt sub-chunk
    assert(memcmp(d + 12, "fmt ", 4) == 0);
    assert(readLE32(d + 16) == 16);        // sub-chunk size
    assert(readLE16(d + 20) == 1);         // PCM format
    assert(readLE16(d + 22) == 1);         // mono
    assert(readLE32(d + 24) == 16000);     // sample rate
    assert(readLE32(d + 28) == 32000);     // byte rate (16000 * 1 * 2)
    assert(readLE16(d + 32) == 2);         // block align
    assert(readLE16(d + 34) == 16);        // bits per sample

    // data sub-chunk
    assert(memcmp(d + 36, "data", 4) == 0);
    uint32_t data_size = readLE32(d + 40);
    assert(data_size == 4 * 2);  // 4 samples * 2 bytes

    // Total file size: 44 header + 8 data bytes
    assert(buf.size() == 44 + 8);

    unlink(path.c_str());
    printf("test_header: OK\n");
}

// ── Test 2: sample quantization ──────────────────────────────────────────────

static void test_samples() {
    std::string path = makeTmpPath();
    float samples[] = {0.0f, 1.0f, -1.0f, 0.5f, -0.5f};
    writeWav(path, samples, 5, 16000);

    auto buf = readFile(path);
    const uint8_t* pcm = buf.data() + 44;  // skip header

    int16_t s0 = readLE16s(pcm + 0);  // 0.0 → 0
    int16_t s1 = readLE16s(pcm + 2);  // 1.0 → 32767
    int16_t s2 = readLE16s(pcm + 4);  // -1.0 → -32767
    int16_t s3 = readLE16s(pcm + 6);  // 0.5 → ~16383
    int16_t s4 = readLE16s(pcm + 8);  // -0.5 → ~-16383

    assert(s0 == 0);
    assert(s1 == 32767);
    assert(s2 == -32767);
    assert(std::abs(s3 - 16383) <= 1);
    assert(std::abs(s4 - (-16383)) <= 1);

    unlink(path.c_str());
    printf("test_samples: OK\n");
}

// ── Test 3: clamping beyond [-1, 1] ─────────────────────────────────────────

static void test_clamping() {
    std::string path = makeTmpPath();
    float samples[] = {2.0f, -3.0f};
    writeWav(path, samples, 2, 16000);

    auto buf = readFile(path);
    const uint8_t* pcm = buf.data() + 44;

    int16_t s0 = readLE16s(pcm + 0);  // 2.0 clamped to 1.0 → 32767
    int16_t s1 = readLE16s(pcm + 2);  // -3.0 clamped to -1.0 → -32767

    assert(s0 == 32767);
    assert(s1 == -32767);

    unlink(path.c_str());
    printf("test_clamping: OK\n");
}

// ── Test 4: empty buffer ─────────────────────────────────────────────────────

static void test_empty() {
    std::string path = makeTmpPath();
    writeWav(path, nullptr, 0, 16000);

    auto buf = readFile(path);
    // Header only: 44 bytes, data_size = 0
    assert(buf.size() == 44);
    assert(readLE32(buf.data() + 40) == 0);  // data sub-chunk size

    unlink(path.c_str());
    printf("test_empty: OK\n");
}

// ── main ─────────────────────────────────────────────────────────────────────

int main() {
    test_header();
    test_samples();
    test_clamping();
    test_empty();

    puts("\nwav_writer_test: all assertions passed");
    return 0;
}

#include <CLI11.hpp>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <csignal>
#include <string>
#include "audio_capture.h"
#include "chunk_assembler.h"
#include "constants.h"
#include "output_writer.h"
#include "vad.h"
#include "whisper_worker.h"

static std::atomic<bool>       g_stop{false};
static std::mutex              g_stop_mutex;
static std::condition_variable g_stop_cv;

static void on_signal(int) {
    g_stop = true;
    g_stop_cv.notify_all();
}

// Generate session ID string: YYYYMMDD_HHMMSS
static std::string make_session_id() {
    auto now   = std::chrono::system_clock::now();
    auto now_t = std::chrono::system_clock::to_time_t(now);
    struct tm tm_info;
    localtime_r(&now_t, &tm_info);
    char buf[32];
    strftime(buf, sizeof(buf), "%Y%m%d_%H%M%S", &tm_info);
    return buf;
}

int main(int argc, char* argv[]) {
    CLI::App app{"note-taker — macOS microphone transcriber"};
    app.set_version_flag("--version", "4.0.0");

    std::string model_path   = "models/ggml-large-v3.bin";
    std::string output_dir   = "notes";
    std::string language     = "auto";
    float       chunk_seconds = DEFAULT_CHUNK_S;
    bool        use_metal    = false;
    bool        translate    = false;
    bool        list_devices = false;
    bool        save_wav     = false;

    app.add_option("--model",         model_path,    "Path to ggml model file");
    app.add_option("--output-dir",    output_dir,    "Directory for JSON/TXT output");
    app.add_option("--language",      language,      "Language code (auto, en, pt, ...)");
    app.add_option("--chunk-seconds", chunk_seconds, "Max chunk length in seconds");
    app.add_flag("--metal",           use_metal,     "Enable Metal GPU acceleration");
    app.add_flag("--translate",       translate,     "Translate output to English");
    app.add_flag("--save-wav",        save_wav,      "Save each chunk as WAV in output-dir");
    app.add_flag("--list-devices",    list_devices,  "List audio input devices and exit");

    CLI11_PARSE(app, argc, argv);

    if (list_devices) {
        auto devices = AudioCapture::listDevices();
        if (devices.empty()) {
            std::puts("no audio input devices found");
        } else {
            for (const auto& d : devices) std::puts(d.c_str());
        }
        return 0;
    }

    // Clamp chunk_seconds to sane range.
    const float min_chunk_s = static_cast<float>(MIN_CHUNK_MS) / 1000.0f;
    if (chunk_seconds < min_chunk_s) {
        fprintf(stderr, "warn: --chunk-seconds %.1f below minimum %.1f, clamped\n",
                chunk_seconds, min_chunk_s);
        chunk_seconds = min_chunk_s;
    }

    std::signal(SIGINT,  on_signal);
    std::signal(SIGTERM, on_signal);

    const std::string session_id = make_session_id();

    OutputWriter writer(output_dir, session_id, model_path, language);
    fprintf(stderr, "info: session %s\n", session_id.c_str());
    fprintf(stderr, "info: output  %s\n", writer.jsonPath().c_str());

    WhisperWorker whisper(model_path, use_metal, language, translate);
    whisper.setOutputWriter(&writer);
    if (save_wav) whisper.setSaveWav(true, output_dir);
    if (!whisper.start()) return 1;

    // Capture chunk_start_ms at enqueue time (on the audio tap thread).
    Vad vad;
    ChunkAssembler assembler(vad, chunk_seconds,
        [&whisper](std::vector<float> chunk) {
            int64_t now_ms =
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::system_clock::now().time_since_epoch()).count();
            whisper.enqueue(std::move(chunk), now_ms);
        });

    AudioCapture capture;
    if (!capture.start([&assembler](const float* samples, size_t n) {
            assembler.feed(samples, n);
        })) {
        whisper.stop();
        return 1;
    }

    fprintf(stderr, "info: hardware format ");
    std::puts("recording — press Ctrl-C to stop");
    std::fflush(stdout);

    {
        std::unique_lock<std::mutex> lock(g_stop_mutex);
        g_stop_cv.wait(lock, [] { return g_stop.load(); });
    }

    std::puts("\nstopping...");
    capture.stop();
    whisper.stop();

    // Final flush — ensures last chunk is written even if stop() drained the queue.
    writer.flush();
    std::puts("done");
    return 0;
}

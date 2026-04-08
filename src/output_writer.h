#pragma once
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

// Accumulates transcription segments and writes JSON + TXT after every chunk.
// Writes are atomic: .tmp file → rename(), so a crash mid-write never corrupts output.
//
// Thread-safe: addSegment() and flush() may be called from the WhisperWorker thread
// while the main thread is running.
class OutputWriter {
public:
    // output_dir is created if it doesn't exist.
    // session_id is used as the filename stem: note_<session_id>.{json,txt}
    OutputWriter(const std::string& output_dir,
                 const std::string& session_id,
                 const std::string& model,
                 const std::string& language);

    // start_ms and end_ms are milliseconds since session start.
    void addSegment(int64_t start_ms, int64_t end_ms, const std::string& text);

    // Atomically flush all segments to disk (JSON + TXT). Called after every chunk.
    void flush();

    const std::string& jsonPath() const { return json_path_; }
    const std::string& txtPath()  const { return txt_path_;  }

private:
    struct Segment {
        int64_t     start_ms;
        int64_t     end_ms;
        std::string text;
    };

    std::string session_id_;
    std::string model_;
    std::string language_;
    std::string json_path_;
    std::string txt_path_;

    std::vector<Segment> segments_;
    std::mutex           mutex_;
};
